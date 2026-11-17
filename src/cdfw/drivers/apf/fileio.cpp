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

 /*
 This is currently only doing reads, Need to look at writing cache issues.

 */

// #include <stdio.h>
// #include <stdlib.h>
// #include <string.h>
// #include <stdbool.h>
// #include <inttypes.h>
#include "fileio.h"
#include "osd_menu.h"
#include "../../app/state.h"
// #include "printf.h"
// Each of the two buffers in the scratch RAM. RISCFileCacheSize makes them smaller
// when a disc needs the rest of the scratch RAM for its subcode.
static uint32_t sector_cache_size = SECTOR_CACHE_SIZE;
#define MEM_BUFFER_SIZE_C sector_cache_size
// We are making two 16K cache buffers for these commands and they will cache them in the memory locations
// uint8_t sector_buffer1[MEM_BUFFER_SIZE_C]; // We have to set an attribute to help point the program in to the 32K buffer that the APF bus has access to after the MPU has been restarted
// uint8_t sector_buffer0[MEM_BUFFER_SIZE_C]; // We have to set an attribute to help point the program in to the 32K buffer that the APF bus has access to after the MPU has been restarted

uint32_t Sector_track_number  = 255;
bool change_of_file = 0;

uint32_t wait_timer = 0;
uint32_t sector_buffer_dataslot = 0; // Which data slot is active in cache

uint32_t sector_buffer0_address ;  // Buffer 0 address that is cached
bool     sector_buffer0_enabled;  // Buffer 0 address that is cached
uint32_t sector_buffer1_address;  // Buffer 1 address that is cached
bool     sector_buffer1_enabled ;  // Buffer 0 address that is cached
uint32_t sector_buffer_size;   // Buffer 0 size offset in the file 16K this is so we know how many sectors are being moved in the media
uint32_t sector_buffer_size_max;   // Buffer byte size maxuium
uint32_t sector_buffer_selector; // This tells the RISCFileReadAdv where we need to copy from the ram to its buffer internally after checking the seek
uint32_t sector_buffer_offset;
uint32_t sector_buffer_processing;
uint32_t sector_buffer_transfer_size_max;   // Buffer 0 size offset in the file 16K this is so we know how many sectors are being moved in the media


  bool cache_buffer_0_enabled = 0;
  bool cache_buffer_1_enabled = 0;
// A full load's read ahead of the second buffer, when the first buffer's read was started
// without a wait (RISCFileSeekReady): started once that has landed, as a full load starts it
static struct { bool on; uint16_t slot; uint32_t at, offset, length; } ahead;
static bool open_pending;		// RISCFileSeekReady's open of a track's file, under way

void clearscrachram(uint32_t offset, uint32_t size){
  int i = offset;
  do {
  SCRACH_RAMBUFFER(i) = 0;
  i=i+4;
  } while (i < (offset + size));
}

uint32_t sector_buffer_transfer_size_max_process(int dataslot, uint32_t offset){
  uint32_t file_size = 0;   // Buffer 0 size offset in the file 16K this is so we know how many sectors are being moved in the media
  file_size = dataslot_size(dataslot);
  int32_t file_left_over = (int32_t)(file_size - offset);
  mainprintf("\033[38;1;5mData Size %0.4X %0.4X %0.4X\033[0m\r\n", file_left_over, file_size, offset);
  if (file_left_over > (MEM_BUFFER_SIZE_C)){
    return(MEM_BUFFER_SIZE_C);
  } else if (offset >= file_size){
    return(0);
  } else {
    return(file_left_over);
  }
}

// Sets how big the two buffers are and forgets what they hold. For a disc's load,
// before its first read.
void RISCFileCacheSize(uint32_t size) {
  sector_cache_size = size;
  ahead.on = false;
  open_pending = false;
  cache_buffer_0_enabled = 0;
  cache_buffer_1_enabled = 0;
  sector_buffer0_address = 0;
  sector_buffer1_address = 0;
  sector_buffer_selector = 0;
  sector_buffer_offset = 0;
  sector_buffer_processing = 0;
}

void timer_disply_for_wait() {
  uint32_t timer_wait = 0;
  char s[256];
  while (!dataslot_ready()){
    timer_wait++;
  };
  osd_display_info_update(timer_wait);
}

// RISCFileSeek's test of where a seek falls: in a buffer, or running from one into the next
typedef struct { bool b0, b1, swap0, swap1; } seek_where_t;
static seek_where_t seek_where(uint32_t offset, uint32_t size) {
  bool cache_buffer_0_max_size = ((offset + size) < (sector_buffer0_address + (MEM_BUFFER_SIZE_C)));
  bool cache_buffer_0_min = (offset >= sector_buffer0_address);
  bool cache_buffer_1_max_size = ((offset + size) < (sector_buffer1_address + (MEM_BUFFER_SIZE_C)));
  bool cache_buffer_1_min = (offset >= sector_buffer1_address);
  bool cache_buffer_steps_0_1 = ((sector_buffer0_address + MEM_BUFFER_SIZE_C) == sector_buffer1_address);
  bool cache_buffer_steps_1_0 = ((sector_buffer1_address + MEM_BUFFER_SIZE_C) == sector_buffer0_address);
  seek_where_t w;
  w.b0 = (cache_buffer_0_max_size & cache_buffer_0_min) && cache_buffer_0_enabled;
  w.b1 = (cache_buffer_1_max_size & cache_buffer_1_min) && cache_buffer_1_enabled;
  w.swap0 = (cache_buffer_0_min & cache_buffer_1_max_size & ~cache_buffer_1_min & cache_buffer_steps_0_1);
  w.swap1 = (cache_buffer_1_min & cache_buffer_0_max_size & ~cache_buffer_0_min & cache_buffer_steps_1_0);
  return w;
}


// The first buffer read from the seek's address and the second after it. With wait, as
// RISCFileSeek has always done it: the first read waited for and the second started. Without,
// the first is started and the second kept for RISCFileAheadStart.
static void full_load(uint32_t offset, uint32_t size, dataslot_type *aft, bool wait) {
  uint32_t foo0 = MAIN_SCRACH_ADDRESS_OFFSET;
  uint32_t foo1 = MAIN_SCRACH_ADDRESS_OFFSET + MEM_BUFFER_SIZE_C;
  ahead.on = false;
  sector_buffer_size = size;   // Buffer 0 size offset in the file 16K this is so we know how many sectors are being moved in the media
  sector_buffer_dataslot = aft->aft_dataslot;                              // We make sure we store the current data slot being asked so the next request is ok
  sector_buffer0_address = offset;                                // get the first buffer offset
  sector_buffer1_address = 0;
  sector_buffer_selector = 0;                                     // made the read advance know that the first buffer is used.
  sector_buffer_offset = 0;                                       // this is the pointer start in the buffer.
  change_of_file = 0;
  timer_disply_for_wait();

  mainprintf ("we did the a full Load \r\n");

  dataslot_read_lba_set(aft->aft_dataslot, APF_SCRACH_ADDRESS_OFFSET | foo0 , sector_buffer0_address); // Setup the lba for the first buffer

  uint32_t temp_size = sector_buffer_transfer_size_max_process(aft->aft_dataslot, sector_buffer0_address);
  if (temp_size > 0){
    if (wait) dataslot_read_lba(temp_size);                      // start the seek
    else dataslot_read_lba_fast(temp_size, 0);
  }
  // I need to do a check here too
  if (dataslot_size(101) > MEM_BUFFER_SIZE_C){ // if the data is larger then the first buffer. Then we will get the second buffer running
    sector_buffer1_address = offset + MEM_BUFFER_SIZE_C;       // get the secon buffer offset
    uint32_t length = sector_buffer_transfer_size_max_process(aft->aft_dataslot, sector_buffer1_address);
    if (wait) {
      dataslot_read_lba_set(aft->aft_dataslot, APF_SCRACH_ADDRESS_OFFSET | foo1 , sector_buffer1_address);
      dataslot_read_lba_fast(length, 0);               // get the second buffer but run this in the background
    } else {
      ahead.on = true;
      ahead.slot = aft->aft_dataslot;
      ahead.at = APF_SCRACH_ADDRESS_OFFSET | foo1;
      ahead.offset = sector_buffer1_address;
      ahead.length = length;
    }
  };
  cache_buffer_1_enabled = 1;
  cache_buffer_0_enabled = 1;
  sector_buffer_processing = 1;
}

uint32_t RISCFileSeek(const char *s, uint32_t offset, uint32_t size, uint32_t track_number, dataslot_type *aft) { // we need to setup the cache so we know how many sizes are transfered at a time

  seek_where_t w = seek_where(offset, size);
  bool cache_buffer_0 = w.b0;
  bool cache_buffer_1 = w.b1;
  bool cache_buffer_0_swap = w.swap0;
  bool cache_buffer_1_swap = w.swap1;
  uint32_t foo0 = MAIN_SCRACH_ADDRESS_OFFSET;
  uint32_t foo1 = MAIN_SCRACH_ADDRESS_OFFSET + MEM_BUFFER_SIZE_C;
  // This code allows the change between the two caches and then update the pointers.
  
  if ((strcmp(s, aft->aft_filename))){
	  char strings[255];
    change_of_file = 1;
    mainprintf ("Change file\r\n");
    sprintf(strings,"%s%s", aft->aft_filepath, s);
		if (OpenFileNameDataSlot(aft, strings) > 0) {
      return 0;
    }
    cache_buffer_1_enabled = 0;
    cache_buffer_0_enabled = 0;
  } else {
    change_of_file = 0;
    if ((cache_buffer_0) & (sector_buffer_selector == 1)) {
      sector_buffer_processing = 0;
      mainprintf ("sector buffer Processing up\r\n");
    } else if ((cache_buffer_1) & (sector_buffer_selector == 0)) {
      sector_buffer_processing = 0;
      mainprintf ("sector buffer Processing down\r\n");
    } else if ((cache_buffer_0_swap & !cache_buffer_1 & !cache_buffer_0)) {
      timer_disply_for_wait();
      mainprintf ("cache_buffer_0_swap & !cache_buffer_1 & !cache_buffer_0\r\n");
    } else if ((cache_buffer_1_swap & !cache_buffer_1 & !cache_buffer_0)) {
      timer_disply_for_wait();
      mainprintf ("cache_buffer_1_swap & !cache_buffer_1 & !cache_buffer_0\r\n");
    }
  }

    mainprintf ("we did the a load request Load %d %d %d %d %d %d\r\n", change_of_file, cache_buffer_0, cache_buffer_1, cache_buffer_0_swap, cache_buffer_1_swap, sector_buffer_processing);
  // first we need to know if the data slot is the current one or not
  // with this we clear the setup and check what size the buffers need to be, how many sectors are to be in them and the presetup of the next buffer
  if (change_of_file | (!change_of_file & (!cache_buffer_0 & !cache_buffer_1 & !cache_buffer_0_swap & !cache_buffer_1_swap))){
    full_load(offset, size, aft, true);
    return 1;

  } else if (cache_buffer_0 | cache_buffer_0_swap) { // we are using the first buffer
       sector_buffer_selector = 0;  // for the read to say which buffer to use
       sector_buffer_offset = (offset - sector_buffer0_address);  // for the read where in the buffer offset
       if (sector_buffer_processing == 0){
         sector_buffer_processing = 1;
         sector_buffer1_address =  sector_buffer0_address + MEM_BUFFER_SIZE_C;
         timer_disply_for_wait();
         
         mainprintf ("cache_buffer_0  cache_buffer_0_swap Load\r\n");
         dataslot_read_lba_set(aft->aft_dataslot, APF_SCRACH_ADDRESS_OFFSET | foo1 , sector_buffer1_address);
         dataslot_read_lba_fast(sector_buffer_transfer_size_max_process(aft->aft_dataslot, sector_buffer1_address),0);               // get the second buffer but run this in the background
       }
       
       cache_buffer_0_enabled = 1;
       return 1;
  } else  if (cache_buffer_1 | cache_buffer_1_swap) { // we are using the second buffer
       sector_buffer_selector = 1;
       sector_buffer_offset = (offset - sector_buffer1_address);
       if (sector_buffer_processing == 0) {
         sector_buffer_processing = 1;
         sector_buffer0_address =  sector_buffer1_address + MEM_BUFFER_SIZE_C;
         // wait_timer = 0;
         timer_disply_for_wait();
        mainprintf ("cache_buffer_1 | cache_buffer_1_swap Load\r\n");
           // if (wait_timer >= 1) mainprintf("\033[36;5;4m Waiting times sec 0 %d\033[0m\r\n", wait_timer);
         dataslot_read_lba_set(aft->aft_dataslot, APF_SCRACH_ADDRESS_OFFSET | foo0 , sector_buffer0_address);
         dataslot_read_lba_fast(sector_buffer_transfer_size_max_process(aft->aft_dataslot, sector_buffer0_address),0);               // get the second buffer but run this in the background
       }
       cache_buffer_1_enabled = 1;
       return 1;
  }

  return 0;
}

// Before a tick (pcecd.cpp): the seek it is about to make, if that would wait on the card,
// is started from the card here and not waited for, and false says so; the tick is put off
// until it has landed, when this is true and the seek finds it all in the buffers. On the
// Pocket the card may not be answered while a Memory is made, and a tick waiting inside
// itself never let the drive park; the loop's top, where it parks, now comes between
// (app/state.h). Only with nothing under way on the card (dataslot_ready).
// The open and the full load are RISCFileSeek's own, in its order; only the wait has moved.
bool RISCFileSeekReady(const char *s, uint32_t offset, uint32_t size, dataslot_type *aft) {
  if (open_pending) {
    open_pending = false;
    if (OpenFileNameDataSlotEnd(aft) > 0) return true;	// its error box; the tick goes on as RISCFileSeek's would
  }
  if (strcmp(s, aft->aft_filename)) {
    char strings[255];
    sprintf(strings,"%s%s", aft->aft_filepath, s);
    // before the open, which goes through the first buffer: a park meanwhile keeps no buffer
    // of the file being left
    cache_buffer_1_enabled = 0;
    cache_buffer_0_enabled = 0;
    ahead.on = false;
    OpenFileNameDataSlotStart(aft, strings);
    open_pending = true;
    return false;
  }
  seek_where_t w = seek_where(offset, size);
  if (!w.b0 && !w.b1 && !w.swap0 && !w.swap1) {
    full_load(offset, size, aft, false);
    return false;
  }
  return true;
}

// A full load's read ahead, kept by RISCFileSeekReady, started: with its first buffer in,
// just before the tick, as RISCFileSeek starts it
void RISCFileAheadStart() {
  if (!ahead.on) return;
  ahead.on = false;
  dataslot_read_lba_set(ahead.slot, ahead.at, ahead.offset);
  dataslot_read_lba_fast(ahead.length, 0);
}

// This is for just transfing the data over from the SRAM location to the buffer that the CDROM core needed.
uint32_t RISCFileReadAdv(int dataslot, uint8_t cmd0, uint8_t cmd1, uint8_t cmd_hps, uint32_t offset) {
  uint8_t *pointer_main;
  uint8_t *pointer_second;
  uint8_t *pointer0 = (uint8_t *)MAIN_SCRACH_ADDRESS_OFFSET;//sector_buffer0;
  uint8_t *pointer1 = (uint8_t *)MAIN_SCRACH_ADDRESS_OFFSET + MEM_BUFFER_SIZE_C;//sector_buffer1;
  bool overflow = ((sector_buffer_offset + offset) > MEM_BUFFER_SIZE_C);	// by what this read sends: a track need not have the sector size of the last full load
  uint32_t offset_main;
  uint32_t offset_second;
  uint32_t offset_diff = (MEM_BUFFER_SIZE_C - sector_buffer_offset);

  uint16_t command = (uint16_t){(cmd1 & 0xff)<<8 | (cmd0 & 0xff)};

  if (!overflow){
    offset_main = offset;
    if (sector_buffer_selector == 0) {
      pointer_main = (pointer0 + sector_buffer_offset);
    } else {
      pointer_main = (pointer1 + sector_buffer_offset);
    }

  } else {
    // wait_timer = 0;
    // timer_disply_for_wait();
    // if (wait_timer >= 1) mainprintf("\033[36;5;4m Waiting times transfer %d\033[0m\r\n", wait_timer);
    if (sector_buffer_selector == 0) {
      pointer_main    =(pointer0 + sector_buffer_offset);
      pointer_second  = pointer1;
      offset_main     = offset_diff;
      offset_second   = offset - offset_main;

    } else {
      pointer_main    =(pointer1 + sector_buffer_offset);
      pointer_second  = pointer0;
      offset_main     = offset_diff;
      offset_second   = offset - offset_main;
    }
    
  }

  HPS_EnableIO();
  spi_b(cmd_hps);
  spi_w(command);
  if (!overflow){
    // HPS_spi_write_fast(pointer_main, offset_main, 1, dataslot);
    HPS_spi_write(pointer_main, offset_main, 1);
  } else {
    // HPS_spi_write_fast(pointer_main, offset_main, 1, dataslot);
    // HPS_spi_write_fast(pointer_second, offset_second, 1, dataslot);
    HPS_spi_write(pointer_main, offset_main, 1);
    HPS_spi_write(pointer_second, offset_second, 1);
  }
  HPS_DisableIO();
  // mainprintf("\033[92;1;1m Done the change\033[0m\r\n");
  return 1;
}

// Copies out what RISCFileSeek found, for the firmware's own use. It runs on into the
// other buffer as RISCFileReadAdv does.
void RISCFileCopy(uint8_t *dst, uint32_t len) {
  uint8_t *here = (uint8_t *)MAIN_SCRACH_ADDRESS_OFFSET + (sector_buffer_selector ? MEM_BUFFER_SIZE_C : 0);
  uint8_t *next = (uint8_t *)MAIN_SCRACH_ADDRESS_OFFSET + (sector_buffer_selector ? 0 : MEM_BUFFER_SIZE_C);
  uint32_t left = MEM_BUFFER_SIZE_C - sector_buffer_offset;
  if (len <= left) {
    memcpy(dst, here + sector_buffer_offset, len);
  } else {
    memcpy(dst, here + sector_buffer_offset, left);
    memcpy(dst + left, next, len - left);
  }
}

// A sector of nothing, for an address the file does not have (a PREGAP).
void RISCSendZeros(uint8_t cmd0, uint8_t cmd1, uint8_t cmd_hps, uint32_t size) {
  uint16_t command = (uint16_t){(cmd1 & 0xff)<<8 | (cmd0 & 0xff)};
  HPS_EnableIO();
  spi_b(cmd_hps);
  spi_w(command);
  for (uint32_t i = 0; i < size; i += 2) spi_w(0);
  HPS_DisableIO();
}

// A save state (app/state.h): the cache's tags out, and back in with what the two buffers
// held read again from the card, so the next sector after a load is no later than the
// saving run's. The track's file is already open in the slot (pcecd.cpp).
void RISCFileCacheSave(cache_state_t *s) {
  s->cache_size = sector_cache_size;
  s->track_number = Sector_track_number;
  s->change_of_file = change_of_file;
  s->buffer0_enabled = sector_buffer0_enabled;
  s->buffer1_enabled = sector_buffer1_enabled;
  s->cache0_enabled = cache_buffer_0_enabled;
  s->cache1_enabled = cache_buffer_1_enabled;
  s->wait_timer = wait_timer;
  s->dataslot = sector_buffer_dataslot;
  s->buffer0_address = sector_buffer0_address;
  s->buffer1_address = sector_buffer1_address;
  s->size = sector_buffer_size;
  s->size_max = sector_buffer_size_max;
  s->selector = sector_buffer_selector;
  s->offset = sector_buffer_offset;
  s->processing = sector_buffer_processing;
  s->transfer_size_max = sector_buffer_transfer_size_max;
}

void RISCFileCacheLoad(const cache_state_t *s) {
  sector_cache_size = s->cache_size;
  Sector_track_number = s->track_number;
  change_of_file = s->change_of_file;
  sector_buffer0_enabled = s->buffer0_enabled;
  sector_buffer1_enabled = s->buffer1_enabled;
  cache_buffer_0_enabled = s->cache0_enabled;
  cache_buffer_1_enabled = s->cache1_enabled;
  wait_timer = s->wait_timer;
  sector_buffer_dataslot = s->dataslot;
  sector_buffer0_address = s->buffer0_address;
  sector_buffer1_address = s->buffer1_address;
  sector_buffer_size = s->size;
  sector_buffer_size_max = s->size_max;
  sector_buffer_selector = s->selector;
  sector_buffer_offset = s->offset;
  sector_buffer_processing = s->processing;
  sector_buffer_transfer_size_max = s->transfer_size_max;
  // what this run had kept to start is another moment's: both buffers are read here
  ahead.on = false;
  open_pending = false;
  // each buffer as RISCFileSeek fills it: as much as the file has from its address
  if (cache_buffer_0_enabled) {
    uint32_t n = sector_buffer_transfer_size_max_process(sector_buffer_dataslot, sector_buffer0_address);
    if (n) dataslot_read(sector_buffer_dataslot, APF_SCRACH_ADDRESS_OFFSET | MAIN_SCRACH_ADDRESS_OFFSET, sector_buffer0_address, n);
  }
  if (cache_buffer_1_enabled) {
    uint32_t n = sector_buffer_transfer_size_max_process(sector_buffer_dataslot, sector_buffer1_address);
    if (n) dataslot_read(sector_buffer_dataslot, APF_SCRACH_ADDRESS_OFFSET | (MAIN_SCRACH_ADDRESS_OFFSET + MEM_BUFFER_SIZE_C), sector_buffer1_address, n);
  }
}
