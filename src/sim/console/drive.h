// Between main.cpp, which holds the console, and drive.cpp, the firmware's drive.
#ifndef SIM_DRIVE_H
#define SIM_DRIVE_H
#include <stdint.h>

// main.cpp's: time passes only here, so the drive's time is the console's.
void sim_tick(uint32_t clocks);			// that many clocks of clk_sys, 42.95 MHz
bool sim_pocket_hold();				// SIM_POCKET_HOLD: the Pocket answering no read now
uint64_t sim_clocks();					// clocks since power-on
long sim_frame();						// frames so far
void sim_io_enable(bool on);			// the MPU's IO_UIO
uint16_t sim_spi_word(uint16_t word);	// one word on the bus, waiting on IO_WAIT as the MPU does
bool sim_drv_park();					// a save state: CORE_INPUT's park and state-in bits
bool sim_drv_state_in();
bool sim_drv_load();
void sim_drv_parked(bool parked, bool restored);	// and CORE_OUTPUT's

// drive.cpp's: the firmware's own drive on the Mac.
void drive_open(const char *card, const char *cue, const char *out_dir);
void drive_poll();						// one pass of the firmware's main loop
void drive_change_disc(const char *cue);	// the player chose another disc on the Pocket: a new line in the slot table, and the update
void drive_log(const char *what);		// a line in drive.log
void drive_close();
void drive_summary(char *json, int size);	// run.json's "drive" object
#endif
