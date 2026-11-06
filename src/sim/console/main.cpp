// The whole console in Verilator: MiSTer's chips and main.sv with a system card where
// the Pocket's SDRAM is, the firmware's own drive and a disc (drive.cpp), and out come
// the frames as PNGs and the sound as a WAV. tools/sim.sh builds and runs it; see
// README.md beside this file.
//
//   Vsim_top --card FILE [--disc CUE] [--out DIR] [--frames N] [--every K] [--save 100,200]
//            [--press F:buttons[:N] ...] [--arcade] [--change F:CUE ...] [--reset F ...]
//            [--mb128] [--save-in FILE] [--save-out FILE] [--press-file FILE]
//            [--state-save F FILE] [--state-load FILE [--load-at F] [--resave FILE]]
//
// Save states (docs/SAVESTATES.md, The proofs), through main.sv's window to
// state_engine.sv, as state_bridge.sv drives it:
//   --state-save F FILE   at frame F find the clean point, read the state out into
//                         FILE, and let the console go on
//   --state-load FILE     at frame --load-at (30) write FILE in and let it go
//   --resave FILE         with --state-load: before the load lets go, read the state
//                         straight back out into FILE
//   --after N             end the run N whole frames after the let-go (or at --frames)
//   --pocket              all of these through the Pocket's side instead (pocket_sim.sv:
//                         state_bridge.sv, and the drive's block in the MPU's RAM through
//                         controller_rom.v, as core_top.v joins them), on clk_74a with the
//                         bridge's commands, reads and writes as the Pocket gives them: a
//                         32-bit word every SIM_POCKET_PERIOD clocks (88), SIM_POCKET_CHUNK
//                         bytes (4096) then a wait of SIM_POCKET_STALL clocks (40000), each
//                         chunk's first word read again. SIM_POCKET_RESET=1: the load is the
//                         launch's, the file written with the Pocket's reset on before the
//                         firmware has run (a wake), --load-at not used. SIM_POCKET_BADSUM=1:
//                         the file's system card sum changed; SIM_POCKET_ACFLAG=1: its Arcade
//                         Card flag set (both to be refused, the game going on)
// From the clock the console is let go, after.txt has each whole frame: its number
// from the let-go, its picture's CRC and a CRC of the chips' own sound (the PSG's,
// CD audio's and ADPCM's outputs before the filters) on every clock of it.
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
#include "Vpocket.h"
#include "Vpocket___024root.h"
#include "verilated.h"
#include "drive.h"
extern uint8_t *sim_drive_block;		// drive.cpp's: the firmware's block for a save state
#include "save_size.h"
#include "core_settings.h"

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
static bool set_ac, set_mb128;		// the Arcade System and MB128 settings, as CORE_OUTPUT has them once the firmware runs
static int mb128_state;

// ---- save states: the harness's side of the state window ----
static const int SS_CLOCKS = 24;		// the Pocket's bridge's pace (state_engine.sv)
static uint32_t SS_WORDS = 0x38000;		// 448 KB at the least; the header says (state_engine.sv)
static long st_save_at = -1, st_load_at = 30;
static std::string st_save, st_load, st_resave, st_out;
static enum { H_IDLE, H_SEEK, H_READ, H_WAITGO, H_LWRITE, H_LGO, H_DONE } hs = H_IDLE;
static std::vector<uint16_t> st_words;
static std::vector<uint8_t> st_loaded;
static uint32_t hw;
static int hwait;
static bool resaving, released;
static uint64_t t_cmd;
static FILE *fa;				// after.txt
static long rel_frame;
static long after_n;				// --after: the run ends that many whole frames after the let-go
static uint32_t snd_crc;
static uint32_t snd_adpcm, snd_cdda;		// clocks of the frame with ADPCM, and CD audio, not silent
static std::vector<uint8_t> card_bytes;

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
    fprintf(fj, "{\"rom\":\"%s\",\"region\":\"%s\",\"card\":\"%s\",\"disc\":\"%s\",\"frames\":%ld,\"saved\":%d,\"seconds\":%.1f,\"mhz\":%.2f,\"mb128\":%s,\"psram_ok\":%s,\"psram_violations\":%u,\"adpcm_reads\":%u,\"adpcm_writes\":%u,\"drive\":%s}\n",
            json_escape(disc_path.empty() ? card_path : disc_path).c_str(), strstr(drive, "\"region_us\":true") ? "USA" : "Japan",
            json_escape(card_path).c_str(), json_escape(disc_path).c_str(), nframe, saved, s, clocks / s / 1e6, mb128_on ? "true" : "false",
            top->psram_mem_ok ? "true" : "false", top->psram_violations, top->adpcm_reads, top->adpcm_writes, drive);
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
  if (getenv("SIM_SSDBG")) {
    auto reg = [&](int i) { int b = (31 - i) * 16; return (top->dbg_vdc_regs[b / 32] >> (b % 32)) & 0xFFFF; };
    printf("vdc: VPR %04x VDR %04x VCR %04x DVSSR %04x CR %04x\n", reg(12), reg(13), reg(14), reg(19), reg(5));
  }
  // after a let-go, the frames from the first whole one: the one it fell in is part before
  if (fa) {
    if (rel_frame >= 0) { fprintf(fa, "%ld %dx%d %08x %08x %u %u\n", rel_frame, w, h, hash, snd_crc, snd_adpcm, snd_cdda); fflush(fa); }
    rel_frame++;
    snd_crc = 0; snd_adpcm = 0; snd_cdda = 0;
  }
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

  if (nframe >= frames || (after_n > 0 && fa && rel_frame >= after_n)) finish();
}

static void ss_report(const char *what) {
  printf("state: %s at clock %llu, frame %ld (status %d)\n", what, (unsigned long long)clocks, nframe, top->ss_status);
  fflush(stdout);
}
static void ss_let_go() {
  ss_report("let go");
  released = true;
  if (fa) fclose(fa);
  fa = fopen((out_dir + "/after.txt").c_str(), "w");
  rel_frame = -1;
  snd_crc = 0;
}
static bool ss_write_file() {
  FILE *f = fopen(st_out.c_str(), "wb");
  if (!f) { fprintf(stderr, "cannot write %s\n", st_out.c_str()); return false; }
  for (uint16_t w : st_words) { fputc(w >> 8, f); fputc(w & 0xFF, f); }
  fclose(f);
  return true;
}

// The state window, a clock at a time, as state_bridge.sv drives it: called after each
// rising edge, what it sets is taken at the next.
static void ss_step() {
  top->ss_save = 0; top->ss_load = 0; top->ss_go = 0; top->ss_rd = 0; top->ss_wr = 0;
  if (top->ss_status == 3 && hs != H_DONE && hs != H_IDLE) { ss_report("an error"); hs = H_DONE; }
  switch (hs) {
  case H_IDLE:
    if (st_save_at >= 0 && nframe == st_save_at && st_out.empty()) {
      top->ss_save = 1; st_out = st_save; hs = H_SEEK; hwait = 4; t_cmd = clocks; ss_report("save asked");
    } else if (!st_loaded.empty() && nframe == st_load_at) {
      top->ss_load = 1; hs = H_LWRITE; hw = 0; hwait = 40; ss_report("load begun");
    }
    break;
  case H_SEEK:
    if (hwait) { hwait--; break; }
    if (top->ss_status == 2) {
      ss_report(resaving ? "restored state readable" : "frozen at its point");
      printf("state: %.2f ms to the point\n", (clocks - t_cmd) / (double)CLK_HZ * 1000);
      st_words.assign(0x48000, 0);
      hs = H_READ; hw = 0; hwait = 0;
    }
    break;
  case H_READ:
    if (hwait == 0) { top->ss_addr = hw; top->ss_rd = 1; hwait = SS_CLOCKS + 1; break; }
    if (--hwait == 1) {
      // the drive's block is the bridge's to serve, from the MPU's RAM
      if (hw >= 0x400 && hw < 0x800) st_words[hw] = sim_drive_block[2 * (hw - 0x400)] << 8 | sim_drive_block[2 * (hw - 0x400) + 1];
      else st_words[hw] = top->ss_do;
      if (hw == 5) {
        // the header's size, in bytes: the MB128's and the Arcade Card's room as the file has them
        SS_WORDS = (st_words[4] << 16 | st_words[5]) / 2;
        st_words.resize(SS_WORDS, 0);
      }
      if (++hw == SS_WORDS) {
        if (!ss_write_file()) exit(1);
        ss_report("read out");
        printf("state: written %s\n", st_out.c_str());
        hs = H_WAITGO; hwait = 2;
      }
    }
    break;
  case H_WAITGO:
    if (hwait == 2) { top->ss_go = 1; hwait = 1; break; }
    if (top->ss_status == 0) { ss_let_go(); hs = H_DONE; }
    break;
  case H_LWRITE:
    if (hwait) { hwait--; break; }
    if (hw == SS_WORDS) { top->ss_go = 1; ss_report("written in"); hs = H_LGO; hwait = 16; break; }
    top->ss_addr = hw; top->ss_di = st_loaded[2 * hw] << 8 | st_loaded[2 * hw + 1]; top->ss_wr = 1;
    if (hw >= 0x400 && hw < 0x800) { sim_drive_block[2 * (hw - 0x400)] = st_loaded[2 * hw]; sim_drive_block[2 * (hw - 0x400) + 1] = st_loaded[2 * hw + 1]; }
    hw++; hwait = SS_CLOCKS;
    break;
  case H_LGO:
    if (hwait) { hwait--; break; }
    if (!st_resave.empty() && !resaving && top->ss_status == 2) {
      ss_report("restored"); resaving = true; top->ss_save = 1; st_out = st_resave; hs = H_SEEK; hwait = 8; t_cmd = clocks;
      break;
    }
    if (top->ss_status == 0) { ss_let_go(); hs = H_DONE; }
    break;
  default: break;
  }
  // after a resave's read-out, H_WAITGO's go ends the load as well
}

// ---- --pocket: the Pocket's side (pocket_sim.sv), on clk_74a, Genesis-Pocket's harness ----
static Vpocket *pb;
static int P_PERIOD = 88, P_CHUNK = 4096, P_STALL = 40000;
static bool p_wake;					// SIM_POCKET_RESET: the file with the reset on, before the firmware
static enum { P_IDLE, P_ACK, P_POLL, P_DELAY, P_READ, P_STALLING, P_WRITE, P_LRESET, P_LACK, P_LPOLL, P_DONE } ps = P_IDLE;
static std::vector<uint8_t> pfile;
static long pa, pchunk_end, pt, pfile_bytes;
static bool pfirst, p_loaded, p_resaving;
static double pphase;
static int pre_status, pre_do, p_status_old;

static void p_start_save(const std::string &file) {
  st_out = file; pb->savestate_start = 1; ps = P_ACK; t_cmd = clocks;
}

// a clock of clk_sys for the bridge: what the console showed before this edge in, its new
// outputs out for the console's next
static void pocket_sys_edge() {
  pb->ss_status = pre_status; pb->ss_do = pre_do;
  pb->card_size = top->ss_card_size; pb->card_sum = top->ss_card_sum; pb->ss_words = top->ss_words;
  pb->mb128_on = set_mb128; pb->ac_on = set_ac;		// core_top.v's ss_setting
  pb->clk_sys = 1; pb->eval();
  top->ss_save = pb->ss_save; top->ss_load = pb->ss_load; top->ss_go = pb->ss_go;
  top->ss_rd = pb->ss_rd; top->ss_wr = pb->ss_wr; top->ss_addr = pb->ss_addr; top->ss_di = pb->ss_di;
  pb->clk_sys = 0; pb->eval();
  // the console let go: its window from ok to idle
  if (p_status_old == 2 && top->ss_status == 0) ss_let_go();
  p_status_old = top->ss_status;
}

// the Pocket, a clock of clk_74a
static void pocket_74a() {
  pb->bridge_rd = 0; pb->bridge_wr = 0;
  switch (ps) {
  case P_IDLE:
    if (running && st_save_at >= 0 && nframe == st_save_at && st_out.empty()) { p_start_save(st_save); ss_report("save asked"); }
    else if (running && !p_wake && !p_loaded && !st_loaded.empty() && nframe == st_load_at) {
      ss_report("load begun");
      p_loaded = true; pa = 0; pt = 0; pchunk_end = P_CHUNK; ps = P_WRITE;
    }
    break;
  case P_ACK:
    if (pb->savestate_start_ack) { pb->savestate_start = 0; ps = P_POLL; }
    break;
  case P_POLL:
    if (pb->savestate_start_err) { ss_report("an error (Savestate Start)"); ps = P_DONE; }
    else if (pb->savestate_start_ok) {
      ss_report(p_resaving ? "restored state readable" : "frozen at its point");
      printf("state: %.2f ms to the point\n", (clocks - t_cmd) / (double)CLK_HZ * 1000);
      pfile_bytes = top->ss_words * 2;		// savestate_size, as core_top.v gives it
      pfile.assign(pfile_bytes, 0); pa = 0; pt = 0; pfirst = true; pchunk_end = P_CHUNK;
      ps = P_DELAY;
    }
    break;
  case P_DELAY:
    if (++pt == 20000) { pt = 0; ps = P_READ; }
    break;
  case P_READ:
    // a word: its address, the bus's value a few clocks on (what the read before fetched),
    // then this read starts
    if (pt == 0) pb->bridge_addr = 0x40000000 + pa;
    if (pt == 4 && !pfirst) {
      uint32_t d = pb->bridge_rd_data; long o = pa - 4;
      pfile[o] = d >> 24; pfile[o + 1] = d >> 16; pfile[o + 2] = d >> 8; pfile[o + 3] = d;
    }
    if (pt == 5) pb->bridge_rd = 1;
    if (++pt == P_PERIOD) {
      pt = 0; pfirst = false;
      if (pa >= pfile_bytes) {
        st_words.resize(pfile_bytes / 2);
        for (long i = 0; i < pfile_bytes / 2; i++) st_words[i] = pfile[2 * i] << 8 | pfile[2 * i + 1];
        if (!ss_write_file()) exit(1);
        ss_report("read out");
        printf("state: written %s\n", st_out.c_str());
        ps = P_DONE;
      }
      else if (pa == pchunk_end) { ps = P_STALLING; pt = 0; }
      else pa += 4;
    }
    break;
  case P_STALLING:
    // a chunk gone to the card: the next starts with the word just read again
    if (++pt >= P_STALL) { pt = 0; pfirst = true; pchunk_end += P_CHUNK; ps = P_READ; }
    break;
  case P_WRITE:
    if (pt == 0) {
      pb->bridge_addr = 0x40000000 + pa;
      pb->bridge_wr_data = (uint32_t)st_loaded[pa] << 24 | st_loaded[pa + 1] << 16 | st_loaded[pa + 2] << 8 | st_loaded[pa + 3];
    }
    if (pt == 5) pb->bridge_wr = 1;
    if (++pt == P_PERIOD) {
      pt = 0; pa += 4;
      if (pa == (long)st_loaded.size()) {
        ss_report("written in");
        if (p_wake) ps = P_LRESET;
        else { pb->savestate_load = 1; ps = P_LACK; }
      }
      else if (pa == pchunk_end) { pchunk_end += P_CHUNK; pt = -P_STALL; }
    }
    break;
  case P_LRESET:
    // the Pocket's reset let go, then Savestate Load
    if (++pt == 2000) { pb->mpu_reset_n = 1; ss_report("the Pocket's reset let go"); }
    if (pt == 4000) { pt = 0; pb->savestate_load = 1; ps = P_LACK; }
    break;
  case P_LACK:
    if (pb->savestate_load_ack) { pb->savestate_load = 0; ps = P_LPOLL; }
    break;
  case P_LPOLL:
    if (pb->savestate_load_err) { ss_report("an error (Savestate Load)"); ps = P_DONE; }
    else if (pb->savestate_load_ok) {
      ss_report("restored");
      if (!st_resave.empty()) { p_resaving = true; p_start_save(st_resave); }
      else ps = P_DONE;
    }
    break;
  default: break;
  }
  pb->clk_74a = 1; pb->eval();
  pb->clk_74a = 0; pb->eval();
}

void sim_tick(uint32_t n) {
  for (uint32_t i = 0; i < n; i++) {
    if (pb) { pre_status = top->ss_status; pre_do = top->ss_do; }
    top->clk_sys = 1; top->clk_mem = 1; top->eval();
    clocks++;
    if (pb) pocket_sys_edge();
    else if (running) ss_step();
    if (fa) {
      uint8_t snd[10];
      uint64_t lo = top->chip_snd[0] | (uint64_t)top->chip_snd[1] << 32;
      for (int k = 0; k < 8; k++) snd[k] = lo >> (8 * k);
      snd[8] = top->chip_snd[2]; snd[9] = top->chip_snd[2] >> 8;
      snd_crc = crc32(snd_crc, snd, 10);
      if (top->chip_snd[0] & 0xFFFF) snd_adpcm++;
      if ((top->chip_snd[0] >> 16) || (top->chip_snd[1] & 0xFFFF)) snd_cdda++;
    }

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
    if (pb) for (pphase += 74.25e6 / CLK_HZ; pphase >= 1; pphase -= 1) pocket_74a();
  }
}

uint64_t sim_clocks() { return clocks; }

// a save state's drive: CORE_INPUT and CORE_OUTPUT's bits, as core_top.v joins them
bool sim_drv_park() { return top->drv_park; }
bool sim_drv_state_in() { return top->drv_in; }
bool sim_drv_load() { return top->drv_load; }
// (core_set_parked writes CORE_OUTPUT whole: the settings' bits with the drive's)
void sim_drv_parked(bool parked, bool restored) { top->drv_parked = parked; top->drv_restored = restored; top->ac_en = set_ac; top->mb128_en = set_mb128; }
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
    else if (a == "--state-save") { st_save_at = atol(next().c_str()); st_save = next(); }
    else if (a == "--state-load") st_load = next();
    else if (a == "--load-at") st_load_at = atol(next().c_str());
    else if (a == "--after") after_n = atol(next().c_str());
    else if (a == "--resave") st_resave = next();
    else if (a == "--pocket") { if (!pb) pb = new Vpocket; }
    else { fprintf(stderr, "what is %s?\n", a.c_str()); return 2; }
  }
  if (card_path.empty()) { fprintf(stderr, "--card FILE: a system card, or tools/testcard.py's\n"); return 2; }
  if (const char *v = getenv("SIM_SPI_SETUP")) spi_setup = atoi(v);
  if (const char *v = getenv("SIM_SPI_HOLD")) spi_hold = atoi(v);

  top = new Vsim_top;
  if (pb) {
    if (const char *v = getenv("SIM_POCKET_PERIOD")) P_PERIOD = atoi(v);
    if (const char *v = getenv("SIM_POCKET_CHUNK")) P_CHUNK = atoi(v);
    if (const char *v = getenv("SIM_POCKET_STALL")) P_STALL = atoi(v);
    p_wake = getenv("SIM_POCKET_RESET") != nullptr;
    pb->clk_74a = 0; pb->clk_sys = 0; pb->mpu_reset_n = 1; pb->eval();
    // the drive's block is the MPU's RAM from 0xF000 (64K: Main_Bram's 16K words)
    sim_drive_block = (uint8_t *)&pb->rootp->pocket_bridge__DOT__Main_Bram__DOT__dbram__DOT__altsyncram_component__DOT__mem[0xF000 / 4];
  }
  frames_txt = fopen((out_dir + "/frames.txt").c_str(), "w");
  if (!frames_txt) { fprintf(stderr, "can't write in %s\n", out_dir.c_str()); return 2; }
  t0 = std::chrono::steady_clock::now();
  // A port's default is run at time 0: evaluate once before setting the inputs (Genesis's README)
  top->eval();
  top->core_reset = 1;
  // as the firmware's core_reg_update passes them on
  uint32_t core_output = core_output_bits((arcade ? SETTING_ARCADE : 0) | (mb128_on ? SETTING_MB128 : 0));
  set_ac = (core_output & OUTPUT_ARCADE) != 0;
  set_mb128 = (core_output & OUTPUT_MB128) != 0;
  // CORE_OUTPUT is the firmware's: on a wake it is 0 until the firmware first writes it, at its park
  top->ac_en = p_wake ? 0 : set_ac;
  top->mb128_en = p_wake ? 0 : set_mb128;
  top->ss_ac_on = set_ac;		// the Pocket's own, from the start
  top->ss_mb128_on = set_mb128;
  drive_open(card_path.c_str(), disc_path.c_str(), out_dir.c_str());
  sim_tick(2000);

  // core_top.v holds the Pocket's boot status until this, and the slots load after it
  while (!top->psram_ready) sim_tick(1000);
  printf("PSRAM ready at %.1f ms, %s, %u timing faults\n", clocks * 1e3 / CLK_HZ, top->psram_mem_ok ? "its test words read back" : "ITS TEST WORDS DID NOT READ BACK", top->psram_violations);
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
  card_bytes = rom;
  if (!st_load.empty()) {
    // the header, as state_bridge.sv checks it: the magic, the version, this system card
    FILE *fs = fopen(st_load.c_str(), "rb");
    if (!fs) { fprintf(stderr, "cannot open %s\n", st_load.c_str()); return 1; }
    { int c; while ((c = fgetc(fs)) != EOF) st_loaded.push_back(c); }
    fclose(fs);
    if (st_loaded.size() < 0x70000 || st_loaded.size() != ((uint32_t)st_loaded[8] << 24 | st_loaded[9] << 16 | st_loaded[10] << 8 | st_loaded[11])) {
      fprintf(stderr, "%s is not a whole state\n", st_load.c_str()); return 1;
    }
    if (getenv("SIM_POCKET_BADSUM")) st_loaded[0x13] ^= 1;
    if (getenv("SIM_POCKET_ACFLAG")) st_loaded[7] |= 2;
    SS_WORDS = st_loaded.size() / 2;
    uint32_t size = 0, sum = 0;
    for (size_t i = 0; i + 1 < rom.size(); i += 2) { size += 2; sum += rom[i] << 8 | rom[i + 1]; }
    auto be32 = [&](int o) { return (uint32_t)st_loaded[o] << 24 | st_loaded[o + 1] << 16 | st_loaded[o + 2] << 8 | st_loaded[o + 3]; };
    if (!pb && (memcmp(st_loaded.data(), "PCSS", 4) || st_loaded[4] || st_loaded[5] != 1 || be32(0x0C) != size || be32(0x10) != sum)) {
      fprintf(stderr, "%s is not a state of this system card\n", st_load.c_str()); return 1;
    }
  }
  if (pb && p_wake && !st_loaded.empty()) {
    // the Pocket's launch of a Memory, or a wake: the file written with its reset on, the
    // console in reset and the firmware not started; then the reset let go, and the
    // firmware's start (main.cpp's init) holds the console's reset 0.53 s before its loop
    ss_report("load begun");
    pb->mpu_reset_n = 0;
    p_loaded = true; pa = 0; pt = 0; pchunk_end = P_CHUNK; ps = P_WRITE;
    while (!pb->mpu_reset_n) sim_tick(100);
    sim_tick(CLK_HZ / 100 * 53);
  }
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
