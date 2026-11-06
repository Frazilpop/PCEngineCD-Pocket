// Save states (docs/SAVESTATES.md, The drive): what the drive keeps of itself through a
// state, and its hooks to the core. Asked to park, the drive stops at the top of a pass,
// writes its state into its block and waits; on a load it reads the block back first. Its
// clock stands still while it is parked, so every time it holds stays good.
#ifndef DRIVE_STATE_H
#define DRIVE_STATE_H
#include <stdint.h>

// the read cache's tags (fileio.cpp): what its two buffers hold, read again on a load
typedef struct {
	uint32_t cache_size;
	uint32_t track_number;
	uint8_t change_of_file, buffer0_enabled, buffer1_enabled, cache0_enabled, cache1_enabled, pad[3];
	uint32_t wait_timer, dataslot, buffer0_address, buffer1_address, size, size_max, selector, offset,
	         processing, transfer_size_max;
} cache_state_t;
void RISCFileCacheSave(cache_state_t *s);
void RISCFileCacheLoad(const cache_state_t *s);	// and the buffers read again from the card

// the core's side: core.cpp on the Pocket, the simulation's drive.cpp
bool core_park_asked();		// CORE_INPUT[4]: park
bool core_state_in();		// CORE_INPUT[5]: a loaded state's words are all in
void core_park_wait();		// a turn of the park's loop
void core_set_parked(bool parked, bool restored);	// CORE_OUTPUT[3] and [4]
// the drive's clock (timer.cpp; drive.cpp): the Pocket's counts milliseconds, the
// simulation's clocks
void drive_clock_get(uint32_t *hi, uint32_t *lo);
void drive_clock_set(uint32_t hi, uint32_t lo);
#endif
