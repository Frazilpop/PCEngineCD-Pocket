// The CD drive in the simulation is the firmware itself: cue.cpp, seektime.cpp,
// fileio.cpp and pcecd.cpp, the sources that go on the card, compiled for the Mac and
// compiled into this file. What stands in is what lies under them on the Pocket:
//
//   the bus to the chips (spi_w and friends): each word through main.cpp's real
//     hps_ext, so the console sees the drive as it does on the Pocket
//   Analogue's data slots: a file for each slot, on this Mac's disk. A read takes
//     SIM_CARD_SEEK_US plus SIM_CARD_KB_US a KB of simulated time, and a background
//     read's bytes reach the scratch RAM only when it is done, so firmware that uses
//     them early sends old data here as it would there. SIM_READ_EARLY=1 adds the
//     fault firmware before 5 Nov 2026 had: after an open that failed, dataslot_read_lba
//     took the error bits still up for its own and went on with the read running
//   the millisecond timer: from the console's own clock
//
// The firmware's other work takes no time here, only its bus words and its reads.
// That is the one thing about the drive this harness can't be said to model exactly.
#include <map>
#include <string>
#include <vector>
#include <stdarg.h>
#include <stdlib.h>
#include <sys/stat.h>
#include "drive.h"

#define FILEIO_H	// host_stubs.h declares what it would
#include "cdfw/drivers/cue/cue.cpp"
#include "cdfw/drivers/cue/seektime.cpp"
#include "cdfw/drivers/apf/fileio.cpp"
#include "cdfw/app/pcecd.cpp"

/* ------------------------------------------------------- what the firmware has */

alignas(16384) unsigned char fake_scratch[16384];
uint32_t fake_dataslot_bram[2];
dataslot_type aft;
bool file_error_enabled;
int file_error_code;
uint32_t dataslot_open_error;
drive_trace_t drive_trace = { 'w' };

static const uint32_t CLOCKS_PER_MS = 42955;
static const uint32_t CLOCKS_PER_US = 43;
static uint32_t seek_us = 500, kb_us = 100, open_us = 2000;
static std::string cue_path;
static FILE *log_file;
static bool fw_print;

struct Slot { std::string path; FILE *f = nullptr; uint32_t size = 0; };
static std::map<int, Slot> slots;

static uint32_t read_clocks(uint32_t length)
{
	return (seek_us + (uint64_t)kb_us * length / 1024) * CLOCKS_PER_US;
}

static bool open_slot(int id, const std::string &path)
{
	Slot &s = slots[id];
	if (s.f) fclose(s.f);
	s.f = nullptr;
	s.size = 0;
	struct stat st;
	if (stat(path.c_str(), &st) || !(s.f = fopen(path.c_str(), "rb"))) return false;
	s.path = path;
	s.size = st.st_size;
	return true;
}

static void read_file(int id, uint32_t offset, uint8_t *to, uint32_t length)
{
	Slot &s = slots[id];
	memset(to, 0, length);
	if (!s.f) return;
	fseek(s.f, offset, SEEK_SET);
	size_t got = fread(to, 1, length, s.f);
	(void)got;
}

// the Pocket's split of a path (dataslot_pathname_file_decode in apf.cpp)
static void split_path(dataslot_type *a, const char *p)
{
	const char *name = strrchr(p, '/');
	name = name ? name + 1 : p;
	memset(a->aft_filepath, 0, sizeof(a->aft_filepath));
	memset(a->aft_filename, 0, sizeof(a->aft_filename));
	memcpy(a->aft_filepath, p, name - p);
	strcpy(a->aft_filename, name);
}

/* --------------------------------------------------------- Analogue's data slots */

// one read at a time, as the bridge does; the scratch RAM takes it when it is done
static struct { bool busy = false; uint64_t done = 0; uint32_t at = 0; std::vector<uint8_t> bytes; } bridge;
static struct { int slot = 0; uint32_t at = 0, offset = 0; } lba_set;
static bool read_early, stale_error;	// SIM_READ_EARLY; a failed open's error bits, still up
static struct { bool on = false; int slot = 0; uint32_t at = 0, offset = 0, length = 0; } queued;	// the bridge's read queue, one deep

static void bridge_start(int slot, uint32_t at, uint32_t offset, uint32_t length);

static void bridge_update()
{
	if (bridge.busy && sim_clocks() >= bridge.done && !sim_pocket_hold()) {
		memcpy(fake_scratch + bridge.at, bridge.bytes.data(), bridge.bytes.size());
		bridge.busy = false;
		if (queued.on) {
			queued.on = false;
			bridge_start(queued.slot, queued.at, queued.offset, queued.length);
		}
	}
}

static void bridge_wait()
{
	while (bridge.busy) {
		sim_tick(16);
		bridge_update();
	}
}

bool dataslot_ready()
{
	bridge_update();
	if (bridge.busy) sim_tick(16);	// the firmware spins on this: time has to pass
	return !bridge.busy;
}

static void bridge_start(int slot, uint32_t at, uint32_t offset, uint32_t length)
{
	bridge_wait();
	at &= 0x3FFF;
	if (at + length > sizeof(fake_scratch)) length = sizeof(fake_scratch) - at;	// the Pocket would run on past it; here it's stopped
	bridge.bytes.resize(length);
	read_file(slot, offset, bridge.bytes.data(), length);
	bridge.at = at;
	bridge.done = sim_clocks() + read_clocks(length);
	bridge.busy = true;
}

uint32_t dataslot_size(uint16_t slot) { return slots[slot].size; }

uint32_t dataslot_read(uint16_t slot, uint32_t address, uint32_t offset, uint32_t length)
{
	if (!slots[slot].f) return 1;
	bridge_start(slot, address, offset, length);
	bridge_wait();
	return 0;
}

uint32_t dataslot_read_lba_set(uint16_t slot, uint32_t address, uint32_t offset)
{
	lba_set.slot = slot;
	lba_set.at = address;
	lba_set.offset = offset;
	return 0;
}

uint32_t dataslot_read_lba(uint32_t length)
{
	bridge_start(lba_set.slot, lba_set.at, lba_set.offset, length);
	if (read_early && stale_error) {
		stale_error = false;
		return 1;
	}
	stale_error = false;
	bridge_wait();
	return 0;
}

uint32_t dataslot_read_lba_fast(uint32_t length, bool wait_update)
{
	if (read_early && bridge.busy) {
		queued.on = true;
		queued.slot = lba_set.slot;
		queued.at = lba_set.at;
		queued.offset = lba_set.offset;
		queued.length = length;
		return 0;
	}
	bridge_start(lba_set.slot, lba_set.at, lba_set.offset, length);
	if (wait_update) bridge_wait();
	return 0;
}

int GetFileNameDataSlot(dataslot_type *a)
{
	split_path(a, cue_path.c_str());
	return 0;
}

int OpenFileNameDataSlot(dataslot_type *a, const char *s)
{
	bridge_wait();
	while (sim_pocket_hold()) sim_tick(16);
	split_path(a, s);
	// as the bridge does, the name goes through the bottom of the scratch RAM
	memset(fake_scratch, 0, 264);
	sim_tick(open_us * CLOCKS_PER_US);
	stale_error = false;
	if (!open_slot(a->aft_dataslot, s)) {
		stale_error = true;
		file_error_enabled = 1;
		file_error_code = 2;
		return 1;
	}
	a->aft_op_filesize = slots[a->aft_dataslot].size;
	return 0;
}

/* --------------------------------------------------------------- the bus, the timer */

void HPS_EnableIO() { sim_io_enable(true); }
void HPS_DisableIO() { sim_io_enable(false); }
uint16_t spi_w(uint16_t word) { bridge_update(); return sim_spi_word(word); }
uint8_t spi_b(uint8_t parm) { return (uint8_t)spi_w(parm); }

void HPS_spi_write(const uint8_t *addr, uint32_t len, int)
{
	// byte by byte: the words of a sector aren't aligned on the Mac as they are in the MPU's scratch RAM
	for (uint32_t i = 0; i + 1 < len; i += 2) spi_w(addr[i] | addr[i + 1] << 8);
	if (len & 1) spi_w(addr[len - 1]);
}

uint16_t HPS_spi_uio_cmd_cont(uint16_t cmd)
{
	HPS_EnableIO();
	return spi_w(cmd);
}

uint8_t HPS_spi_uio_cmd8(uint8_t cmd, uint8_t parm)
{
	HPS_EnableIO();
	spi_b(cmd);
	uint8_t res = spi_b(parm);
	HPS_DisableIO();
	return res;
}

void HPS_io_file_tx_data(const uint8_t *addr, uint32_t len, int cmd)
{
	HPS_EnableIO();
	spi_b(cmd);
	HPS_spi_write(addr, len, 1);
	HPS_DisableIO();
}

// The drive's clock, which a save state stops while the drive is parked: to the clock here,
// so a loaded run's drive goes on exactly as the saving run's
static uint64_t clock_offset;
uint32_t RISCGetTimer2(uint32_t fraction) { return (uint32_t)((sim_clocks() - clock_offset) / CLOCKS_PER_MS) + fraction; }
void drive_clock_get(uint32_t *hi, uint32_t *lo) { uint64_t c = sim_clocks() - clock_offset; *hi = c >> 32; *lo = (uint32_t)c; }
void drive_clock_set(uint32_t hi, uint32_t lo) { clock_offset = sim_clocks() - ((uint64_t)hi << 32 | lo); }

// a save state's hooks (app/state.h): the park's loop looks at its bit a clock at a time, so
// the drive goes on at the same clock after a let-go in a saved run and a loaded one
static uint8_t drive_block[2048];
uint8_t *sim_drive_block = drive_block;
bool core_park_asked() { return sim_drv_park(); }
bool core_state_in() { return sim_drv_state_in(); }
// SIM_PARK_NO_LOAD: the firmware before 6 Nov 2026's load bit, which wrote its block at every park
bool core_park_load() { static bool old = getenv("SIM_PARK_NO_LOAD"); return sim_drv_load() && !old; }
void core_park_wait() { sim_tick(1); }
void core_set_parked(bool parked, bool restored) { sim_drv_parked(parked, restored); }
bool RISCCheckTimer2(uint32_t time) { return !time || RISCGetTimer2(0) >= time; }

/* ----------------------------------------------------------------------- the rest */

void osd_display_info_update(int) {}
void osd_display_timing(uint8_t, uint8_t, uint8_t) {}
void osd_trace_stage(char stage)
{
	drive_trace.stage = stage;
	if (log_file) { fprintf(log_file, "%ld %u stage %c\n", sim_frame(), RISCGetTimer2(0), stage); fflush(log_file); }
}

int mainprintf(const char *format, ...)
{
	if (fw_print) {
		va_list ap;
		va_start(ap, format);
		vfprintf(stderr, format, ap);
		va_end(ap);
	}
	return 0;
}

static uint32_t env_or(const char *name, uint32_t dflt)
{
	const char *v = getenv(name);
	return v ? (uint32_t)atoi(v) : dflt;
}

void drive_open(const char *card, const char *cue, const char *out_dir)
{
	seek_us = env_or("SIM_CARD_SEEK_US", seek_us);
	kb_us = env_or("SIM_CARD_KB_US", kb_us);
	open_us = env_or("SIM_CARD_OPEN_US", open_us);
	fw_print = getenv("SIM_FW_PRINT");
	read_early = getenv("SIM_READ_EARLY");
	log_file = fopen((std::string(out_dir) + "/drive.log").c_str(), "w");
	if (!open_slot(1, card)) {
		fprintf(stderr, "can't read the system card %s\n", card);
		exit(2);
	}
	if (cue && *cue) {
		cue_path = cue;
		if (!open_slot(100, cue)) {
			fprintf(stderr, "can't read the disc's CUE %s\n", cue);
			exit(2);
		}
		fake_dataslot_bram[1] = slots[100].size;
	}
	aft.aft_dataslot = 101;
}

void drive_log(const char *what)
{
	if (log_file) { fprintf(log_file, "%ld %u %s\n", sim_frame(), RISCGetTimer2(0), what); fflush(log_file); }
}

void drive_change_disc(const char *cue)
{
	cue_path = cue;
	if (!open_slot(CUE_SLOT_OTHER, cue)) {
		fprintf(stderr, "can't read the disc's CUE %s\n", cue);
		exit(2);
	}
	drive_log((std::string("disc chosen ") + cue).c_str());
	pcecd_change_disc();
}

// a pass of main.cpp's mainloop: core_poll_io, core_reg_update
void drive_poll()
{
	static uint32_t commands, resets;
	static bool tray_open, disc_changed;
	cue.SetRegion(bios_us ? 1 : 0);
	cue.SetFastSeek(false);
	pcecd_poll();
	if (log_file && (drive_trace.commands != commands || drive_trace.resets != resets)) {
		commands = drive_trace.commands;
		resets = drive_trace.resets;
		fprintf(log_file, "%ld %u command %u:", sim_frame(), RISCGetTimer2(0), commands);
		for (int i = 0; i < 6; i++) fprintf(log_file, " %02x", drive_trace.last[i]);
		fprintf(log_file, " resets %u state %d lba %d\n", resets, (int)cue.state, cue.CurrentLBA());
		fflush(log_file);
	}
	if (cue.tray_open != tray_open) drive_log(cue.tray_open ? "tray open" : "tray shut");
	if (disc_changed && !cue.disc_changed) drive_log("told the disc changed");
	tray_open = cue.tray_open;
	disc_changed = cue.disc_changed;
}

void drive_close()
{
	if (log_file) fclose(log_file);
	log_file = nullptr;
}

void drive_summary(char *json, int size)
{
	snprintf(json, size, "{\"stage\":\"%c\",\"resets\":%u,\"commands\":%u,\"sectors\":%u,\"tracks\":%d,\"region_us\":%s,\"loaded\":%s,\"error\":%d}",
		drive_trace.stage, drive_trace.resets, drive_trace.commands, drive_trace.data_ends, cue.TrackCount(),
		bios_us ? "true" : "false", cue.loaded ? "true" : "false", file_error_code);
}
