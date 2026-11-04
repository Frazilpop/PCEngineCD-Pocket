
/*
	PCECD Controller code

	We have seperated the CUE controller and the PCECD interface files so then the CUE controller can be used on other devices



*/
#include "fileio.h"
#include "cue.h"

static int need_reset=0;
static uint8_t has_command = 0;
bool bios_us = false;

uint32_t poll_timer = 0;
	
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

void pcecd_poll()
{
	static uint8_t last_req = 0;
	static uint8_t adj = 0;

	if (need_reset) {
		need_reset = 0;
		// The console's reset, and the game's resets of the drive, come here. The
		// first one loads the disc, as nothing else does; after that the disc stays,
		// as on MiSTer. A game resetting the drive used to throw the TOC away and read
		// the whole CUE again, every file of it, with the game waiting on the drive.
		if (!cue.loaded) {
			drive_trace.bios_size = dataslot_size(1);
			osd_trace_stage('s');
			bios_us = bios_is_us();
			drive_trace.bios_us = bios_us;
			osd_trace_stage('c');
			cue.Reset();
			pcecd_set_image(DATASLOT_BRAM(0), DATASLOT_BRAM(1));
			osd_trace_stage(cue.loaded ? 'r' : 'f');
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

	// mainprintf("milli seconds %0.8x \r\n", poll_timer);
	if (RISCCheckTimer2(poll_timer))
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
