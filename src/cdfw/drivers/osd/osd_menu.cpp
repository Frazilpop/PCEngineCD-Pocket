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
    // E the system card's read; SS parks asked/made/taken back, K the last one's lateness
    // and W the longest wait on the card (ms), L loaded blocks/refused
    sprintf (s, "E%d SS %d/%d/%d K%d W%d L%d/%d", drive_trace.bios_error, drive_trace.park_asks,
      drive_trace.parks, drive_trace.park_missed, drive_trace.park_late, drive_trace.wait_max,
      drive_trace.restores, drive_trace.restore_refused);
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
    sprintf (s, "L:%d M:%d A:%d D:%d P:%X", cue.CurrentLBA(), (int)cue.state, (int)cue.latency, drive_trace.data_ends, (int)(CORE_INPUT_REGISTOR() & 15));
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

// Every look at a command to the Pocket that isn't done yet: how long it has waited, and
// whether a save state has asked the drive to park meanwhile. Shows whether the Pocket
// answers the core's reads while it makes or loads a Memory, or while its menu is up.
bool core_park_asked();
static bool card_waiting = false, ask_seen = false;
static uint32_t card_wait_since, ask_at;
void drive_trace_card_wait(bool done){
  uint32_t now = GetTimer();
  if (ask_seen && !core_park_asked()) {
    ask_seen = false;
    drive_trace.park_missed++;
    drive_trace.park_late = now - ask_at;
  }
  if (done) {
    card_waiting = false;
    return;
  }
  if (!card_waiting) {
    card_waiting = true;
    card_wait_since = now;
  }
  else if (now - card_wait_since > drive_trace.wait_max) drive_trace.wait_max = now - card_wait_since;
  if (!ask_seen && core_park_asked()) {
    ask_seen = true;
    ask_at = now;
    drive_trace.park_asks++;
  }
}

void drive_trace_parked(){
  if (ask_seen) drive_trace.park_late = GetTimer() - ask_at;
  else {
    drive_trace.park_asks++;
    drive_trace.park_late = 0;
  }
  ask_seen = false;
  drive_trace.parks++;
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



}
