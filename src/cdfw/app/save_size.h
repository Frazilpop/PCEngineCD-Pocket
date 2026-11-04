// How big the Pocket should write the save: MiSTer's layout, 2K of backup RAM, or that
// and the Memory Base 128's 128K. With the setting off a save stays 2K, but one already
// holding an MB128 keeps it, or turning the setting off would lose it at the next quit.
// Here, and not in main.cpp, so the simulation sizes its save the same way.
#ifndef SAVE_SIZE_H
#define SAVE_SIZE_H
#include <stdint.h>

static const uint32_t SAVE_2K = 0x00000800, SAVE_WITH_MB128 = 0x00020800;

// now: 0 for the first look, and from then on the last answer. table: the size in the
// slot table, the loaded file's on the first look.
static inline uint32_t save_size(uint32_t now, uint32_t table, bool mb128)
{
	if (mb128 || now == SAVE_WITH_MB128) return SAVE_WITH_MB128;
	if (now == 0) return table > SAVE_2K ? SAVE_WITH_MB128 : SAVE_2K;
	return now;
}
#endif
