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

#include "osd_menu.h"

static uint32_t timer_wait_hold;
static uint32_t timer_wait_value;
char s[64];

uint8_t nstore1;
uint8_t nstore2;
uint8_t nstore3;
uint8_t frame_counter = 0;

// The trace is the CD Debug setting's. Forced on while every disc stopped at the
// Run screen (2 Nov 2026); docs/PLAN.md says how to read it.
#define DEBUG_OVERLAY_ON (AFP_REGISTOR(2) == 1)

drive_trace_t drive_trace = { 'w' };
static uint32_t beat = 0;   // keeps counting while the firmware is alive

void osd_display_error_apf(){
  
};

void osd_display_info(){
  if ((error_system == 0) && DEBUG_OVERLAY_ON){
    sprintf (s, "Delay: %d E:%d", timer_wait_value, drive_trace.bios_error);
    OsdWrite(s);
    OsdUpdate(1);
    OsdClear();
    sprintf (s, "T M:S : %d %d %d", nstore1,  nstore2 , nstore3);
    OsdWrite(s);
    OsdUpdate(0);
    OsdClear();
    beat++;
    sprintf (s, "S:%c R:%d T:%d K:%d %c B:%d", drive_trace.stage, drive_trace.resets, cue.TrackCount(), drive_trace.bios_size / 1024, drive_trace.bios_us ? 'U' : 'J', beat);
    OsdWrite(s);
    OsdUpdate(2);
    OsdClear();
    sprintf (s, "C:%d %02X %02X %02X %02X %02X %02X", drive_trace.commands, drive_trace.last[0], drive_trace.last[1], drive_trace.last[2], drive_trace.last[3], drive_trace.last[4], drive_trace.last[5]);
    OsdWrite(s);
    OsdUpdate(3);
    OsdClear();
    sprintf (s, "L:%d M:%d A:%d D:%d", cue.CurrentLBA(), (int)cue.state, (int)cue.latency, drive_trace.data_ends);
    OsdWrite(s);
    OsdUpdate(4);
    OsdClear();
    if (frame_counter != 0) {
      InfoEnable(10, 10, 30, 5, 291, 31744); // Had to use the info as some of the PCE outputs are smaller
      timer_wait_hold  = RISCGetTimer2(200);
      frame_counter = frame_counter - 1;
    }
    else {
      InfoEnable(10, 10, 30, 5, 291, 65535); // Had to use the info as some of the PCE outputs are smaller
      timer_wait_value = 0;
    }
  }
  else {
    OsdDisable();
  }
}

// Drawn at once: if the next step hangs, the screen still says which step it was.
void osd_trace_stage(char stage){
  drive_trace.stage = stage;
  osd_display_info();
}

void osd_display_info_update(int timer_wait){
  if ((error_system == 0) && DEBUG_OVERLAY_ON){
      timer_wait_value = timer_wait_value + timer_wait;
      if (timer_wait > 0) frame_counter = 2;
  }
}

void osd_display_timing (uint8_t n1, uint8_t n2, uint8_t n3){
  if ((error_system == 0) && DEBUG_OVERLAY_ON){
    nstore1 = n1;
    nstore2 = n2;
    nstore3 = n3;
  }
}

void osd_display_error_dataslot (int data_error){
  switch(data_error)
  {
  case 6:
    OsdWrite("-----------Core Error----------");
    OsdUpdate(0);
    OsdClear();
    OsdWrite("This function is not added yet");
    OsdUpdate(1);
    OsdClear();
    OsdWrite("Please quit the core and reload");
    OsdUpdate(2);
    OsdClear();
    OsdWrite("the game that you want to play");
    OsdUpdate(3);
    OsdClear();
    OsdWrite("      upcoming function");
    OsdUpdate(4);
    OsdClear();
    OsdWrite("Now Im just wasting codespace" );
    OsdUpdate(5);
    OsdClear();
    OsdWrite("ULTRAFP64 is a pain in the ass");
    OsdUpdate(6);
    OsdClear();
    OsdWrite("Im also one too, but I drink");
    OsdUpdate(7);
    OsdClear();
    OsdWrite("more. Will Fix later YAY - MAZA  ");
    OsdUpdate(8);
    OsdClear();
    OsdWrite("ULTRAFP64 COMING SOON");
    OsdUpdate(9);
    OsdClear();
    OsdWrite("------------------------------");
    OsdUpdate(10);
    OsdClear();
    OsdWrite("I hate that guy Maza - UFP64");
    OsdUpdate(11);
    OsdClear();
    InfoEnable(5, 80, 31, 12, 192, 65535); // Had to use the info as some of the PCE outputs are smaller
    break;

  default:
    sprintf (s, "-------DataFile Error---- %d", data_error);
    OsdWrite(s);
    OsdUpdate(0);
    OsdClear();
    OsdWrite("     Please check the files  ");
    OsdUpdate(1);
    OsdClear();
    OsdWrite(" are in the correct location");
    OsdUpdate(2);
    OsdClear();
    OsdWrite(" or both the File and folder ");
    OsdUpdate(3);
    OsdClear();
    OsdWrite(" name is below 255 Charrators");
    OsdUpdate(4);

    OsdClear();
    OsdWrite("         Directory");
    OsdUpdate(5);

    // Each line is a space and 28 characters, so the next starts at 28. It started at
    // 29 and lost a letter a line: R-Type's "(Track 02)" read "(rack 02)".
    OsdClear();
    snprintf (s, 30," %s", aft.aft_filepath);
    OsdWrite(s);
    OsdUpdate(6);
    
    OsdClear();
    snprintf (s, 30," %s", aft.aft_filepath + 28);
    OsdWrite(s);
    OsdUpdate(8);

    OsdClear();
    snprintf (s, 30," %s", aft.aft_filepath + 56);
    OsdWrite(s);
    OsdUpdate(9);

    OsdClear();
    OsdWrite("Trying to find the File Name  ");
    OsdUpdate(10);
    
    OsdClear();
    snprintf (s, 30," %s", aft.aft_filename);
    OsdWrite(s);
    OsdUpdate(11);
    
    OsdClear();
    snprintf (s, 30," %s", aft.aft_filename + 28);
    OsdWrite(s);
    OsdUpdate(12);

    OsdClear();
    snprintf (s, 30," %s", aft.aft_filename + 56);
    OsdWrite(s);
    OsdUpdate(13);

    // Error 2 has three causes: the Pocket refused the file (its answer is not 0), or
    // the CUE's files are in two folders, or a name is too long (answer 0). The tracks
    // say when: all of them, it failed in play; fewer, it failed loading the CUE.
    OsdClear();
    snprintf (s, 30,"Tracks %d, Pocket's answer %d", cue.TrackCount(), dataslot_open_error);
    OsdWrite(s);
    OsdUpdate(14);
    OsdClear();
    InfoEnable(10, 80, 30, 15, 192, 65535); // Had to use the info as some of the PCE outputs are smaller
    break;
  }



}
