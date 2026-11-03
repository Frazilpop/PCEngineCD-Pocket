// The whole console in Verilator: MiSTer's chips and main.sv with a system card where
// the Pocket's SDRAM is, the firmware's own drive and a disc (drive.cpp), and out come
// the frames as PNGs and the sound as a WAV. tools/sim.sh builds and runs it; see
// README.md beside this file.
//
//   Vsim_top --card FILE [--disc CUE] [--out DIR] [--frames N] [--every K] [--save 100,200]
//            [--press F:buttons[:N] ...] [--arcade]
//
// Out, in DIR: f_NNNNN.png for each frame saved (the picture as core_top.v gives it to
// the Pocket, through the real line buffer), frames.txt (each frame's number, size, a
// CRC of its pixels and its top-left pixel), audio.wav (main.sv's audio_l and audio_r,
// 48 kHz), drive.log (the drive's commands with their frame and millisecond) and run.json.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <zlib.h>
#include "Vsim_top.h"
#include "verilated.h"
#include "drive.h"

static Vsim_top *top;
static uint64_t clocks;
static std::string out_dir = ".", card_path, disc_path;
static long nframe, frames = 600, every = 60;
static std::string saves;
static int saved;
static std::chrono::steady_clock::time_point t0;
static uint64_t run_from;		// the clock the console left reset

struct Press { long from, to; int bits; };
static std::vector<Press> presses;

static const uint32_t AUDIO_HZ = 48000, CLK_HZ = 42954545;
static uint32_t audio_acc;
static std::vector<int16_t> audio;

static std::vector<uint32_t> line, frame;
static std::vector<std::vector<uint32_t>> lines;
static bool old_vs, running;
static FILE *frames_txt;

// ---- PNG and WAV (Genesis-Pocket's sim/genesis/main.cpp) ----
static void put32(std::vector<uint8_t> &v, uint32_t x) { for (int i = 3; i >= 0; i--) v.push_back(x >> (i * 8)); }
static void chunk(FILE *f, const char *type, const std::vector<uint8_t> &data) {
  std::vector<uint8_t> c; put32(c, data.size());
  c.insert(c.end(), type, type + 4); c.insert(c.end(), data.begin(), data.end());
  put32(c, crc32(0, c.data() + 4, c.size() - 4));
  fwrite(c.data(), 1, c.size(), f);
}
static bool write_png(const std::string &path, int w, int h, const std::vector<uint32_t> &px) {
  FILE *f = fopen(path.c_str(), "wb");
  if (!f) return false;
  static const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
  fwrite(sig, 1, 8, f);
  std::vector<uint8_t> ihdr; put32(ihdr, w); put32(ihdr, h);
  ihdr.insert(ihdr.end(), {8, 2, 0, 0, 0});
  chunk(f, "IHDR", ihdr);
  std::vector<uint8_t> raw;
  for (int y = 0; y < h; y++) {
    raw.push_back(0);
    for (int x = 0; x < w; x++) { uint32_t p = px[y * w + x]; raw.push_back(p >> 16); raw.push_back(p >> 8); raw.push_back(p); }
  }
  uLongf n = compressBound(raw.size());
  std::vector<uint8_t> z(n);
  compress2(z.data(), &n, raw.data(), raw.size(), 6);
  z.resize(n);
  chunk(f, "IDAT", z);
  chunk(f, "IEND", {});
  fclose(f);
  return true;
}
static void write_wav(const std::string &path, const std::vector<int16_t> &s) {
  FILE *f = fopen(path.c_str(), "wb");
  if (!f) return;
  auto u32 = [&](uint32_t x) { fwrite(&x, 4, 1, f); };
  auto u16 = [&](uint16_t x) { fwrite(&x, 2, 1, f); };
  uint32_t bytes = s.size() * 2;
  fwrite("RIFF", 1, 4, f); u32(36 + bytes); fwrite("WAVEfmt ", 1, 8, f);
  u32(16); u16(1); u16(2); u32(AUDIO_HZ); u32(AUDIO_HZ * 4); u16(4); u16(16);
  fwrite("data", 1, 4, f); u32(bytes);
  fwrite(s.data(), 2, s.size(), f);
  fclose(f);
}

static std::string json_escape(const std::string &s) {
  std::string o;
  for (char c : s) { if (c == '"' || c == '\\') o += '\\'; o += c; }
  return o;
}

// ---- the end of a run, from wherever it comes: often inside the firmware ----
static void finish() {
  fclose(frames_txt);
  write_wav(out_dir + "/audio.wav", audio);
  char drive[512];
  drive_summary(drive, sizeof drive);
  drive_close();
  double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  FILE *fj = fopen((out_dir + "/run.json").c_str(), "w");
  if (fj) {
    fprintf(fj, "{\"card\":\"%s\",\"disc\":\"%s\",\"frames\":%ld,\"saved\":%d,\"seconds\":%.1f,\"mhz\":%.2f,\"drive\":%s}\n",
            json_escape(card_path).c_str(), json_escape(disc_path).c_str(), nframe, saved, s, clocks / s / 1e6, drive);
    fclose(fj);
  }
  printf("Done: %ld frames in %.0f s, %.2f MHz of 42.95; drive %s\n", nframe, s, clocks / s / 1e6, drive);
  fflush(stdout);
  exit(0);
}

static void frame_done() {
  if (!line.empty()) { lines.push_back(line); line.clear(); }
  if (!running) { lines.clear(); return; }
  nframe++;
  int w = 0, h = lines.size();
  for (auto &l : lines) if ((int)l.size() > w) w = l.size();
  frame.assign((size_t)w * h, 0);
  for (int y = 0; y < h; y++) std::copy(lines[y].begin(), lines[y].end(), frame.begin() + (size_t)y * w);
  uint32_t hash = crc32(0, (const Bytef *)frame.data(), frame.size() * 4);
  fprintf(frames_txt, "%ld %dx%d %08x %06x\n", nframe, w, h, hash, frame.empty() ? 0 : frame[0]);
  fflush(frames_txt);
  bool save = (every > 0 && nframe % every == 0) || nframe == frames
              || saves.find("," + std::to_string(nframe) + ",") != std::string::npos;
  if (save && w && h) {
    char name[32]; snprintf(name, sizeof name, "/f_%05ld.png", nframe);
    write_png(out_dir + name, w, h, frame);
    saved++;
  }
  lines.clear();
  double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  printf("%ld of %ld frames  (%dx%d, %.2f s a frame)\n", nframe, frames, w, h, s / nframe);
  fflush(stdout);

  int pad = 0;
  for (auto &p : presses) if (nframe >= p.from && nframe < p.to) pad |= p.bits;
  top->pad = pad;

  if (nframe >= frames) finish();
}

void sim_tick(uint32_t n) {
  for (uint32_t i = 0; i < n; i++) {
    top->clk_sys = 1; top->clk_mem = 1; top->eval();
    clocks++;

    if (top->video_de) line.push_back(top->video_rgb & 0xFFFFFF);
    else if (!line.empty()) { lines.push_back(line); line.clear(); }
    if (top->video_vs && !old_vs) frame_done();
    old_vs = top->video_vs;

    if (running && (audio_acc += AUDIO_HZ) >= CLK_HZ) {
      audio_acc -= CLK_HZ;
      audio.push_back((int16_t)top->audio_l);
      audio.push_back((int16_t)top->audio_r);
    }

    top->clk_mem = 0; top->eval();
    top->clk_sys = 0; top->clk_mem = 1; top->eval();
    top->clk_mem = 0; top->eval();
  }
}

uint64_t sim_clocks() { return clocks; }
long sim_frame() { return nframe; }

// About what a word costs the MPU on the Pocket: a gpo read and two writes at 74 MHz,
// then the two-stage crossing into clk_sys each way (MPU_AFP_CORE.v). Not measured.
static uint32_t spi_setup = 6, spi_hold = 6;

void sim_io_enable(bool on) {
  top->io_enable = on;
  sim_tick(4);
}

uint16_t sim_spi_word(uint16_t word) {
  top->io_din = word;
  sim_tick(spi_setup);
  top->io_strobe = 1;
  sim_tick(1);
  top->io_strobe = 0;
  sim_tick(1);
  while (top->io_wait) sim_tick(1);	// the ack waits on IO_WAIT, a FIFO near full
  uint16_t r = top->io_dout;
  sim_tick(spi_hold);
  return r;
}

static int button_bits(const std::string &names) {
  static const char *NAMES[] = {"up", "down", "left", "right", "i", "ii", "select", "run"};
  int bits = 0;
  size_t at = 0;
  while (at <= names.size()) {
    size_t plus = names.find('+', at);
    std::string n = names.substr(at, plus == std::string::npos ? std::string::npos : plus - at);
    bool found = false;
    for (int i = 0; i < 8; i++) if (n == NAMES[i]) { bits |= 1 << i; found = true; }
    if (!found) { fprintf(stderr, "no button %s: up down left right i ii select run\n", n.c_str()); exit(2); }
    if (plus == std::string::npos) break;
    at = plus + 1;
  }
  return bits;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  bool arcade = false;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto next = [&]() { if (i + 1 >= argc) { fprintf(stderr, "%s wants a value\n", a.c_str()); exit(2); } return std::string(argv[++i]); };
    if (a == "--card") card_path = next();
    else if (a == "--disc") disc_path = next();
    else if (a == "--out") out_dir = next();
    else if (a == "--frames") frames = atol(next().c_str());
    else if (a == "--every") every = atol(next().c_str());
    else if (a == "--save") saves = "," + next() + ",";
    else if (a == "--arcade") arcade = true;
    else if (a == "--press") {
      std::string p = next();
      size_t c1 = p.find(':'), c2 = p.find(':', c1 == std::string::npos ? 0 : c1 + 1);
      if (c1 == std::string::npos) { fprintf(stderr, "--press F:buttons[:N]\n"); return 2; }
      long f = atol(p.c_str());
      long n = c2 == std::string::npos ? 4 : atol(p.c_str() + c2 + 1);
      presses.push_back({f, f + n, button_bits(p.substr(c1 + 1, c2 == std::string::npos ? std::string::npos : c2 - c1 - 1))});
    }
    else { fprintf(stderr, "what is %s?\n", a.c_str()); return 2; }
  }
  if (card_path.empty()) { fprintf(stderr, "--card FILE: a system card, or tools/testcard.py's\n"); return 2; }
  if (const char *v = getenv("SIM_SPI_SETUP")) spi_setup = atoi(v);
  if (const char *v = getenv("SIM_SPI_HOLD")) spi_hold = atoi(v);

  top = new Vsim_top;
  frames_txt = fopen((out_dir + "/frames.txt").c_str(), "w");
  if (!frames_txt) { fprintf(stderr, "can't write in %s\n", out_dir.c_str()); return 2; }
  t0 = std::chrono::steady_clock::now();
  // A port's default is run at time 0: evaluate once before setting the inputs (Genesis's README)
  top->eval();
  top->core_reset = 1;
  top->ac_en = arcade;
  drive_open(card_path.c_str(), disc_path.c_str(), out_dir.c_str());
  sim_tick(2000);

  // The system card through the real path: main.sv's ROM size and header come from
  // this, as they do from core_top.v's data loader.
  FILE *f = fopen(card_path.c_str(), "rb");
  std::vector<uint8_t> rom;
  if (f) { int c; while ((c = fgetc(f)) != EOF) rom.push_back(c); fclose(f); }
  top->cart_download = 1;
  sim_tick(16);
  for (size_t i = 0; i < rom.size(); i += 2) {
    top->ioctl_dout = rom[i] | (i + 1 < rom.size() ? rom[i + 1] << 8 : 0);
    top->ioctl_wr = 1;
    sim_tick(8);
    top->ioctl_wr = 0;
    sim_tick(8);
  }
  top->cart_download = 0;
  sim_tick(200);
  top->core_reset = 0;
  running = true;
  run_from = clocks;
  printf("Card in, %zu bytes, %.0f s to load; the console runs\n", rom.size(),
         std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
  fflush(stdout);

  // The firmware's main loop for ever; finish() ends it at the last frame.
  for (;;) {
    sim_tick(100);
    drive_poll();
  }
}
