// The whole console in Verilator: MiSTer's chips and main.sv with a system card where
// the Pocket's SDRAM is, the firmware's own drive and a disc (drive.cpp), and out come
// the frames as PNGs and the sound as a WAV. tools/sim.sh builds and runs it; see
// README.md beside this file.
//
//   Vsim_top --card FILE [--disc CUE] [--out DIR] [--frames N] [--every K] [--save 100,200]
//            [--press F:buttons[:N] ...] [--arcade] [--change F:CUE ...] [--reset F ...]
//            [--mb128] [--save-in FILE] [--save-out FILE] [--press-file FILE]
//
// Out, in DIR: f_NNNNN.png for each frame saved (the picture as core_top.v gives it to
// the Pocket, through the real line buffer), frames.txt (each frame's number, size, a
// CRC of its pixels and its top-left pixel), audio.wav (main.sv's audio_l and audio_r,
// 48 kHz), drive.log (the drive's commands with their frame and millisecond) and run.json.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <zlib.h>
#include "Vsim_top.h"
#include "verilated.h"
#include "drive.h"
#include "save_size.h"

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
struct Change { long at; std::string cue; };
static std::vector<Change> changes;		// another disc chosen on the Pocket
static std::vector<long> resets;		// the Reset core setting
static std::string press_file;			// lines of F:buttons[:N], read as the run goes, to steer it from outside
static long press_file_at;
static std::string save_in, save_out;		// the Save slot: loaded before the card, written at the end
static uint32_t save_loaded;
static bool mb128_on;
static int mb128_state;

void sim_tick(uint32_t n);

// The Save slot as the Pocket moves it, a word at a time with core_top.v's timing: the
// data_loader's 8 of 16 clocks up, and the data_unloader's 16 before the data is taken.
// The console is in reset meanwhile, by main.sv's save_download.
static void save_word_at(uint32_t byte) {
  top->sd_buff_addr = (byte >> 1) & 0xFF;
  top->sd_lba = byte >> 9;
}
static void save_load(const std::string &path) {
  FILE *f = fopen(path.c_str(), "rb");
  if (!f) { fprintf(stderr, "no save %s\n", path.c_str()); exit(2); }
  std::vector<uint8_t> d;
  int c;
  while ((c = fgetc(f)) != EOF) d.push_back(c);
  fclose(f);
  top->save_download = 1;
  sim_tick(16);
  for (size_t i = 0; i + 1 < d.size(); i += 2) {
    save_word_at(i);
    top->sd_buff_dout = d[i] | d[i + 1] << 8;
    top->sd_wr = 1;
    sim_tick(8);
    top->sd_wr = 0;
    sim_tick(8);
  }
  top->save_download = 0;
  sim_tick(16);
  save_loaded = d.size();
}
static void save_write(const std::string &path) {
  // the size the firmware would leave in the slot table
  uint32_t size = save_size(save_size(0, save_loaded, false), 0, mb128_on);
  std::vector<uint8_t> d;
  top->save_download = 1;
  sim_tick(16);
  for (uint32_t i = 0; i < size; i += 2) {
    save_word_at(i);
    top->sd_rd = 1;
    sim_tick(16);
    uint16_t w = top->sd_buff_din;
    top->sd_rd = 0;
    sim_tick(4);
    d.push_back(w & 0xFF);
    d.push_back(w >> 8);
  }
  top->save_download = 0;
  FILE *f = fopen(path.c_str(), "wb");
  if (f) { fwrite(d.data(), 1, d.size(), f); fclose(f); }
}

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
  running = false;
  if (!save_out.empty()) save_write(save_out);
  write_wav(out_dir + "/audio.wav", audio);
  char drive[512];
  drive_summary(drive, sizeof drive);
  drive_close();
  double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  FILE *fj = fopen((out_dir + "/run.json").c_str(), "w");
  if (fj) {
    // rom and region say which run this was
    fprintf(fj, "{\"rom\":\"%s\",\"region\":\"%s\",\"card\":\"%s\",\"disc\":\"%s\",\"frames\":%ld,\"saved\":%d,\"seconds\":%.1f,\"mhz\":%.2f,\"mb128\":%s,\"psram_ok\":%s,\"psram_violations\":%u,\"drive\":%s}\n",
            json_escape(disc_path.empty() ? card_path : disc_path).c_str(), strstr(drive, "\"region_us\":true") ? "USA" : "Japan",
            json_escape(card_path).c_str(), json_escape(disc_path).c_str(), nframe, saved, s, clocks / s / 1e6, mb128_on ? "true" : "false",
            top->mb128_mem_ok ? "true" : "false", top->psram_violations, drive);
    fclose(fj);
  }
  printf("Done: %ld frames in %.0f s, %.2f MHz of 42.95; drive %s\n", nframe, s, clocks / s / 1e6, drive);
  fflush(stdout);
  exit(0);
}

static int button_bits(const std::string &names);
static void add_press(const std::string &p) {
  size_t c1 = p.find(':'), c2 = p.find(':', c1 == std::string::npos ? 0 : c1 + 1);
  if (c1 == std::string::npos) { fprintf(stderr, "--press F:buttons[:N]\n"); exit(2); }
  long f = atol(p.c_str());
  long n = c2 == std::string::npos ? 4 : atol(p.c_str() + c2 + 1);
  presses.push_back({f, f + n, button_bits(p.substr(c1 + 1, c2 == std::string::npos ? std::string::npos : c2 - c1 - 1))});
}
static void read_press_file() {
  FILE *f = fopen(press_file.c_str(), "r");
  if (!f) return;
  fseek(f, press_file_at, SEEK_SET);
  char l[128];
  while (fgets(l, sizeof l, f)) {
    if (!strchr(l, '\n')) break;		// a line still being written
    press_file_at = ftell(f);
    std::string p(l);
    p.erase(p.find_last_not_of(" \r\n") + 1);
    if (!p.empty()) add_press(p);
  }
  fclose(f);
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

  if (!press_file.empty()) read_press_file();
  int pad = 0;
  for (auto &p : presses) if (nframe >= p.from && nframe < p.to) pad |= p.bits;
  top->pad = pad;

  if (nframe >= frames) finish();
}

void sim_tick(uint32_t n) {
  for (uint32_t i = 0; i < n; i++) {
    top->clk_sys = 1; top->clk_mem = 1; top->eval();
    clocks++;

    // what a game asks of the MB128: rtl/mb128.sv's states 1, the ident, and 6 and 8, a read and a write
    if (top->mb128_state != mb128_state) {
      int st = top->mb128_state;
      if (st == 1 || st == 6 || st == 8) {
        char m[96];
        if (st == 1) snprintf(m, sizeof m, "mb128 ident");
        else snprintf(m, sizeof m, "mb128 %s sector %u, %u bits", st == 6 ? "read" : "write", top->mb128_addr >> 10, top->mb128_bits);
        drive_log(m);
      }
      mb128_state = st;
    }

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
    else if (a == "--mb128") mb128_on = true;
    else if (a == "--press-file") press_file = next();
    else if (a == "--save-in") save_in = next();
    else if (a == "--save-out") save_out = next();
    else if (a == "--press") {
      add_press(next());
    }
    else if (a == "--change") {
      std::string p = next();
      size_t c = p.find(':');
      if (c == std::string::npos) { fprintf(stderr, "--change F:CUE\n"); return 2; }
      changes.push_back({atol(p.c_str()), p.substr(c + 1)});
    }
    else if (a == "--reset") resets.push_back(atol(next().c_str()));
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
  top->mb128_en = mb128_on;
  drive_open(card_path.c_str(), disc_path.c_str(), out_dir.c_str());
  sim_tick(2000);

  // core_top.v holds the Pocket's boot status until this, and the slots load after it
  while (!top->mb128_ready) sim_tick(1000);
  printf("PSRAM ready at %.1f ms, %s, %u timing faults\n", clocks * 1e3 / CLK_HZ, top->mb128_mem_ok ? "its test words read back" : "ITS TEST WORDS DID NOT READ BACK", top->psram_violations);
  fflush(stdout);
  if (!save_in.empty()) save_load(save_in);

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
    for (auto &c : changes) if (c.at == nframe) { drive_change_disc(c.cue.c_str()); c.at = -1; }
    for (auto &r : resets) if (r == nframe) {
      // firmware's full_core_reset: the reset held 50 ms, and 50 ms more before it goes on
      r = -1;
      drive_log("reset core");
      top->core_reset = 1;
      sim_tick(CLK_HZ / 20);
      top->core_reset = 0;
      sim_tick(CLK_HZ / 20);
    }
    drive_poll();
  }
}
