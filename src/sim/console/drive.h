// Between main.cpp, which holds the console, and drive.cpp, the firmware's drive.
#ifndef SIM_DRIVE_H
#define SIM_DRIVE_H
#include <stdint.h>

// main.cpp's: time passes only here, so the drive's time is the console's.
void sim_tick(uint32_t clocks);			// that many clocks of clk_sys, 42.95 MHz
uint64_t sim_clocks();					// clocks since power-on
long sim_frame();						// frames so far
void sim_io_enable(bool on);			// the MPU's IO_UIO
uint16_t sim_spi_word(uint16_t word);	// one word on the bus, waiting on IO_WAIT as the MPU does

// drive.cpp's: the firmware's own drive on the Mac.
void drive_open(const char *card, const char *cue, const char *out_dir);
void drive_poll();						// one pass of the firmware's main loop
void drive_close();
void drive_summary(char *json, int size);	// run.json's "drive" object
#endif
