
/*
	PCECD Controller code

	We have seperated the CUE controller and the PCECD interface files so then the CUE controller can be used on other devices



*/
#include "fileio.h"
#include "cue.h"
#include "state.h"

static int need_reset=0;
static uint8_t has_command = 0;
bool bios_us = false;

uint32_t poll_timer = 0;
static uint8_t last_req = 0;	// the chips' count of events, as last seen (hps_ext.v's cd_req)
static uint8_t adj = 0;
	
// A US system card has the words its Japanese one has in Japanese, and the drive
// answers a US console's signature for it (cd.vhd's registers C5 to C7): MiSTer's
// test, its whole file for "ALL DATA". The file is read with the scratch RAM the
// CUE is about to be read into. An error here is not one the player needs to see.
static bool bios_is_us()
{
	const char *chunk = (const char *)(MAIN_SCRACH_ADDRESS_OFFSET + 0x200);
	uint32_t size = dataslot_size(1);
	bool error_enabled = file_error_enabled;
	int error_code = file_error_code;
	bool found = false;
	for (uint32_t at = 0; (at < size) && !found; at += 0x3C00)
	{
		uint32_t len = (size - at < 0x3E00) ? size - at : 0x3E00;
		drive_trace.bios_error = dataslot_read(1, APF_SCRACH_ADDRESS_OFFSET + 0x200, at, len);
		if (drive_trace.bios_error) break;
		for (uint32_t i = 0; (i + 8 <= len) && !found; i++)
		{
			found = !memcmp(chunk + i, "ALL DATA", 8);
		}
	}
	file_error_enabled = error_enabled;
	file_error_code = error_code;
	return found;
}

// The player chose another disc in Core Settings. The tray opens once the console has
// emptied the sector it's being sent: the chips send a status before what's waiting in
// their FIFO, so a game that has stopped reading is not waited for long. It stays open
// for a game to see, counted from the end of the load, since a game polling the drive
// can't have seen it open while the firmware was opening files and not answering.
#define TRAY_DRAIN_MS 500
#define TRAY_OPEN_MS 2000
static enum { TRAY_SHUT, TRAY_OPENING, TRAY_OPEN } tray = TRAY_SHUT;
static uint32_t tray_timer;

void pcecd_change_disc()
{
	tray = TRAY_OPENING;
	tray_timer = RISCGetTimer2(TRAY_DRAIN_MS);
}

static void tray_poll()
{
	if ((tray == TRAY_OPENING) && ((cue.state != CD_STATE_READ) || cue.can_read_next || RISCCheckTimer2(tray_timer))) {
		while (!dataslot_ready());	// the read ahead lands in the scratch RAM the CUE is read into
		cue.OpenTray();
		cue.Unload();
		cue.SetCueSlot(CUE_SLOT_OTHER);
		pcecd_set_image(DATASLOT_BRAM(0), DATASLOT_BRAM(1));
		tray_timer = RISCGetTimer2(TRAY_OPEN_MS);
		tray = TRAY_OPEN;
		poll_timer = 0;
	}
	else if ((tray == TRAY_OPEN) && RISCCheckTimer2(tray_timer)) {
		cue.CloseTray();
		tray = TRAY_SHUT;
	}
}

// The first reset of the drive loads the disc, as nothing else does
static void first_load()
{
	drive_trace.bios_size = dataslot_size(1);
	osd_trace_stage('s');
	bios_us = bios_is_us();
	drive_trace.bios_us = bios_us;
	osd_trace_stage('c');
	cue.Reset();
	pcecd_set_image(DATASLOT_BRAM(0), DATASLOT_BRAM(1));
	osd_trace_stage(cue.loaded ? 'r' : 'f');
}

// ---- Save states (docs/SAVESTATES.md, The drive; app/state.h) ----
//
// The drive's block: 2K at 0xF000 in the MPU's RAM, above _end, where neither the image
// nor its stack reaches. The bridge reads and writes it as the state file's 0x800 to 0xFFF.
#ifndef DRIVE_BLOCK
#define DRIVE_BLOCK ((uint8_t *)0xF000)
#endif
#define BLOCK_MAGIC 0x42444350	// PCDB
#define BLOCK_VERSION 2

typedef struct {
	uint32_t magic, version;
	uint32_t clock_hi, clock_lo;	// the drive's clock when it parked
	uint32_t disc_id;				// which disc (cue_t::DiscId)
	int32_t need_reset;
	uint32_t poll_timer, tray_timer;
	uint8_t has_command, bios_us, tray, last_req, adj, pad[3];
	dataslot_type aft;				// the track file the read cache reads from
	cue_state_t cue;
	cache_state_t cache;
	char cue_path[256];				// the disc's CUE, folder and name, to open it again by
} drive_block_t;
static_assert(sizeof(drive_block_t) <= 2048, "the drive's block is 2K");

static void block_out(drive_block_t *b, uint32_t hi, uint32_t lo)
{
	memset(b, 0, sizeof(*b));
	b->magic = BLOCK_MAGIC;
	b->version = BLOCK_VERSION;
	b->clock_hi = hi;
	b->clock_lo = lo;
	b->disc_id = cue.loaded ? cue.DiscId() : 0;
	b->need_reset = need_reset;
	b->poll_timer = poll_timer;
	b->tray_timer = tray_timer;
	b->has_command = has_command;
	b->bios_us = bios_us;
	b->tray = tray;
	b->last_req = last_req;
	b->adj = adj;
	b->aft = aft;
	cue.SaveState(&b->cue);
	RISCFileCacheSave(&b->cache);
	if (cue.loaded) cue.CuePath(b->cue_path, sizeof(b->cue_path));
}

// The state's disc, when it isn't the one in: opened by its path through Another disc's
// slot, as a disc chosen in Core Settings is, so the first slot, which names the save,
// keeps its file. Its own error box if it can't be.
static bool reopen(const char *path)
{
	static dataslot_type a;
	while (!dataslot_ready());
	a.aft_dataslot = CUE_SLOT_OTHER;
	if (OpenFileNameDataSlot(&a, path)) return false;
	cue.Unload();
	cue.SetCueSlot(CUE_SLOT_OTHER);
	cue.SetCuePath(path);
	pcecd_set_image(DATASLOT_BRAM(0), DATASLOT_BRAM(1));
	return cue.loaded;
}

// A loaded state's block back in: false if it isn't one, or is another disc's
static bool block_in(const drive_block_t *b)
{
	if ((b->magic != BLOCK_MAGIC) || (b->version != BLOCK_VERSION)) return false;
	while (!dataslot_ready());			// a read the drive had under way when it parked
	if (!cue.loaded) first_load();		// a wake's state can come before the console's first reset
	bool other = b->disc_id && (!cue.loaded || (cue.DiscId() != b->disc_id));
	if (other && (!b->cue_path[0] || !reopen(b->cue_path) || (cue.DiscId() != b->disc_id))) return false;
	// the track file the cache was reading, open again in its slot if another is
	if (strcmp(aft.aft_filename, b->aft.aft_filename) || strcmp(aft.aft_filepath, b->aft.aft_filepath)) {
		static char path[sizeof(b->aft.aft_filepath) + sizeof(b->aft.aft_filename)];
		dataslot_type a = b->aft;
		snprintf(path, sizeof(path), "%s%s", b->aft.aft_filepath, b->aft.aft_filename);
		if (OpenFileNameDataSlot(&a, path)) return false;
	}
	aft = b->aft;
	need_reset = b->need_reset;
	poll_timer = b->poll_timer;
	tray_timer = b->tray_timer;
	has_command = b->has_command;
	bios_us = b->bios_us;
	tray = (decltype(tray))b->tray;
	last_req = b->last_req;
	adj = b->adj;
	cue.LoadState(&b->cue);
	if (other) cue.SetCueSlot(CUE_SLOT_OTHER);	// the disc is in Another disc's slot now, whichever it was in
	RISCFileCacheLoad(&b->cache);
	return true;
}

// Asked to park: at the top of a pass the drive writes its block and waits, its clock
// standing still. A load's words all in, it reads the block back. A block it can't take
// (another disc, or none) leaves the tray open, so the game sees no disc rather than the
// wrong one. A load's park writes no block: the file's may be in already (always, on a
// wake, where the file comes before the firmware starts).
//
// A read ahead still under way is not waited for. On the Pocket a Memory made in play
// failed every time and one made with the drive quiet was made (6 Nov 2026): the Pocket
// is taken to answer none of the core's reads while it makes or loads a Memory, so a
// park that waited for one never came. The block's cache tags already say what that read
// brings; the saving run has it land after the let-go, and a load reads both buffers
// again anyway, once the Pocket has answered the load.
static void park()
{
	drive_block_t *b = (drive_block_t *)DRIVE_BLOCK;
	uint32_t hi, lo;
	bool load = core_park_load();
	drive_clock_get(&hi, &lo);
	if (!load) block_out(b, hi, lo);
	core_set_parked(true, false);
	bool restored = false;
	while (core_park_asked()) {
		if (!restored && core_state_in()) {
			drive_trace.restores++;
			if (block_in(b)) {
				hi = b->clock_hi;
				lo = b->clock_lo;
			}
			else {
				drive_trace.restore_refused++;
				cue.OpenTray();
			}
			restored = true;
			core_set_parked(true, true);
		}
		core_park_wait();
	}
	drive_clock_set(hi, lo);
	core_set_parked(false, false);
}

void pcecd_poll()
{
	if (core_park_asked()) park();

	if (need_reset) {
		need_reset = 0;
		// The console's reset, and the game's resets of the drive, come here. The
		// first one loads the disc, as nothing else does; after that the disc stays,
		// as on MiSTer. A game resetting the drive used to throw the TOC away and read
		// the whole CUE again, every file of it, with the game waiting on the drive.
		if (!cue.loaded) {
			first_load();
		}
		else {
			cue.Reset();
		}
		poll_timer = 0;
	}

	tray_poll();

	// After the reset and the load, as MiSTer's next pass does. Before them, the 0 they
	// set counted from power-on, and the drive ran a tick a pass until it had caught up.
	if (!poll_timer) poll_timer = RISCGetTimer2(13);

	// A tick waits for no read still under way: it is put off to a later pass, which gets
	// to the top, where a save state's park is looked for. A tick's wait on the card comes
	// before it has changed anything, so this is the wait it would have had, moved out to
	// here. On the Pocket the card may not be answered while a Memory is made, and maybe
	// while the menu is up: a tick waiting inside then never let the drive park.
	// mainprintf("milli seconds %0.8x \r\n", poll_timer);
	if (RISCCheckTimer2(poll_timer) && dataslot_ready())
	{
		// mainprintf("milli seconds done %0.8x \r\n", poll_timer);
	    // ResetTimer2();
		if ((!cue.latency) && (cue.state == CD_STATE_READ)) {
			poll_timer += 16;				// 16.0ms between frames if reading data */
		} else {
			poll_timer += (13 + ((adj == 3) ? 1 : 0));	// 13.33ms otherwise (including latency counts) */
			if (adj > 3) adj = 3;
			if (--adj <= 0) adj = 3;
		}
		if (cue.has_status && !cue.latency) {
			cue.SendStatus(cue.GetStatus());
			cue.has_status = 0;
		}
		else if (cue.data_req && !cue.latency) {
			cue.SendDataRequest();
			cue.data_req = false;
		}

		cue.Update();
		
	}

	uint8_t req = HPS_spi_uio_cmd_cont(UIO_CD_GET);

	if (req != last_req)
	{
		last_req = req;
		uint16_t data_in[7];
		data_in[0] = spi_w(0);
		data_in[1] = spi_w(0);
		data_in[2] = spi_w(0);
		data_in[3] = spi_w(0);
		data_in[4] = spi_w(0);
		data_in[5] = spi_w(0);
		data_in[6] = spi_w(0);
		HPS_DisableIO();

		switch (data_in[6] & 0xFF)
		{
		case 0:
			drive_trace.commands++;
			memcpy(drive_trace.last, data_in, sizeof(drive_trace.last));
			cue.SetCommand((uint8_t*)data_in);
			cue.CommandExec();
			has_command = 1;
			break;

		case 1:
			//TODO: process data
			cue.SendStatus(0);
			break;

		case 2:
			drive_trace.data_ends++;
			cue.can_read_next = true;
			break;

		default:
			drive_trace.resets++;
			need_reset = 1;
			break;
		}
	}
	else {
		HPS_DisableIO();
	}



}

void pcecd_reset() {
	need_reset = 1;
	poll_timer = 0;
}

static void notify_mount(int load)
{
	// HPS_spi_uio_cmd16(UIO_SET_SDINFO, load);
	HPS_spi_uio_cmd8(UIO_SET_SDSTAT, load);
}

int pcecd_using_cd()
{
	return cue.loaded;
}

void pcecd_set_image(int dataslot, int size)
{

	// cue.Unload();
	// cue.Reset();
	cue.state = CD_STATE_NODISC;
	uint16_t temp = cue.Load(101);
	if (temp == 1)
	{
		cue.state = cue.loaded ? CD_STATE_IDLE : CD_STATE_NODISC;
		cue.latency = 10;
		cue.SendData = pcecd_send_data;
		notify_mount(1);
	}
	else
	{
		cue.Unload();
		notify_mount(0);
		// main.cpp draws it, once, and leaves it up. Drawn here, the trace's next
		// stage and the main loop's osd_display_info took it straight down again.
		file_error_enabled = 1;
		file_error_code = temp;
		cue.state = CD_STATE_NODISC;
	}
	need_reset = 0;
}

int pcecd_send_data(uint8_t* buf, int len, uint8_t index) {
	HPS_io_file_tx_data(buf, len, UIO_CD_DATA);
	return 1;
}
