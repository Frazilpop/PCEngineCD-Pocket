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

#ifndef OSD_MENU_H
#define OSD_MENU_H

#include "osd.h"
#include "cue.h"
#include "hardware.h"
#include "apf.h"
#include "spi.h"
#include "riscprintf.h"
#include "timer.h"

static int error_system = 0;
static int error_dataslot = 0;
void osd_display_error_dataslot(int data_error);
void osd_display_info();
void osd_display_timing (uint8_t n1, uint8_t n2, uint8_t n3);
void osd_display_info_update(int timer_wait);
void osd_display_error_apf(uint32_t error_code);

// How far the drive has got, drawn over the picture (osd_menu.cpp).
typedef struct {
  char stage;           // w waiting for the first reset, s reading the system card, c asking the CUE's name, n reading the CUE, o opening its first file, p the rest of it, r ready, f failed
  uint32_t resets;      // resets of the drive asked for
  uint32_t commands;    // commands from the console
  uint32_t data_ends;   // sectors the console has taken
  uint8_t last[6];      // the last command's first bytes
  uint32_t bios_size;   // the system card's size in the slot table
  bool bios_us;
  bool hucard;          // slot 100's file is a HuCard: the drive has no disc (pcecd.cpp)
  uint32_t bios_error;  // what reading the system card from the slot answered
  // save states (pcecd.cpp's park): parks asked of the drive, made, and asked but taken
  // back unmade; the last park's lateness in ms, from its ask seen in a wait on the card
  // (0 if seen at the top of a pass); the longest wait on the card in ms; loaded blocks
  // read back, and of those refused (the tray left open)
  uint32_t park_asks, parks, park_missed, park_late, wait_max, restores, restore_refused;
} drive_trace_t;
extern drive_trace_t drive_trace;
void osd_trace_stage(char stage);
void drive_trace_card_wait(bool done);  // apf.cpp, each look at a command to the Pocket
void drive_trace_parked();              // core.cpp, as the drive parks
#endif
