/*
 * Copyright 2022 Murray Aickin
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 */
 // #include <stdint.h>
 // #include <unistd.h>
 // #include <stdio.h>
 // #include <stdlib.h>

#include "interrupts.h"
#include "hardware.h"
#include "timer.h"
#include "uart.h"
#include "apf.h"
#include "riscprintf.h"
#include "printf.h"
#include "spi.h"
#include "core.h"
#include "osd_menu.h"
#include "save_size.h"

void init()
{
  // this makes the core go in to the reset state and halts the bus so we can upload the bios if required
  core_reset(0);
	// This setups the timers and the CPU clock rate on the system.
  DisableInterrupts();
  // Setup the core to know what MHZ the CPU is running at.
  SetTimer();
  SetUART();
  ResetTimer();
  riscusleep(500000);
  mainprintf("\033[0m");
  // printf_register(riscputc);
  // This is where you setup the core startup dataslots that the APT loads up for your core.
  core_restart_first(); // we want to setup the core now :-) but with no startup yet
}

bool file_error_enabled = 0;
int file_error_code = 0;

// The Pocket writes the save back at the size the slot table says, and writes
// none at 0. Found by the slot's id: this was word 5, the third slot's size
// whatever was third, and 0.2.3's data.json put Save fourth.
static uint32_t save_bytes = 0;

static void save_slot_size()
{
	uint32_t save_slot = dataslot_search_id(2);
	uint32_t at = (save_slot ? save_slot : 4) + 1;	// 4: where data.json has it, if the table has no id yet
	save_bytes = save_size(save_bytes, DATASLOT_BRAM(at), AFP_REGISTOR(1) & 0x8);
	DATASLOT_BRAM(at) = save_bytes;
}

void mainloop()
{
  // We like to see over the UART that hey I did something :-)
	riscusleep(9000);
	mainprintf("RISC MPU Startup core 2.4\r\n");
	mainprintf("Created By Mazamars312\r\n");
	mainprintf("Make in 2022\r\n");
	mainprintf("I hate this debugger LOL\r\n");
	riscusleep(2000);
	core_reset(1); // Turns off all the resets via the HPS bus
  	// core_update_dataslots();
	core_input_setup();
	DisableInterrupts();
	mainprintf("about to go in baby\r\n");
	uint32_t display_cd = RISCGetTimer2(200);
	save_slot_size();
	int file_error_shown = 0;
	while(true){

		// A user reload of a deferload slot comes only as this and a new line in the slot
		// table (Analogue's docs, Host/Target Commands). Slot 100, the CUE, is the only
		// one so: the system card's is set to restart the core.
		if(DATASLOT_UPDATE_REG(0)){
			riscusleep(2000);	// the id comes through more stages of latch than the flag
			if (DATASLOT_UPDATE_REG(1) == 100) {
				file_error_code = 0;
				file_error_shown = 0;
				save_slot_size();	// if the Pocket wrote the whole table
				pcecd_change_disc();
			}
		}

		core_poll_io();
		core_reg_update();
		// The setting can arrive after the first look, or be turned on mid-game.
		if ((AFP_REGISTOR(1) & 0x8) && save_bytes != SAVE_WITH_MB128) save_slot_size();
		if (RISCCheckTimer2(display_cd) && (file_error_code == 0)) {
			osd_display_info();
			display_cd = RISCGetTimer2(200);
		}

		// drawn once: the same loop serves the disc, and this redrew every line every pass
		if (file_error_code != file_error_shown){
			file_error_shown = file_error_code;
			if (file_error_code != 0) osd_display_error_dataslot(file_error_code);
		}

		// This checks if we are wanting to do a reboot of the core from the interaction menu. We want to do this last so nothing is held in the buffers
		if (AFP_REGISTOR(0) & 0x1) { // This has 2 bits for reseting the core
			full_core_reset();
		}
	};
}

int main()
{

	init();
	riscusleep(20000); // I want the core to wait a bit.
	mainloop();

	return(0);
}

void irqCallback(){
}
