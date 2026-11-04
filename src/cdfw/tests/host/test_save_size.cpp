// How big the Pocket is told to write the save: ../../app/save_size.h. The file the Pocket
// loaded is in the table on the first look, 0 if there was none.
#include <stdio.h>
#include "../../app/save_size.h"

static int bad;
static void is(uint32_t got, uint32_t want, const char *what)
{
	if (got != want) { printf("WRONG %s: 0x%x, wanted 0x%x\n", what, got, want); bad = 1; }
}

int main()
{
	is(save_size(0, 0, false), SAVE_2K, "no file, setting off");
	is(save_size(0, 0x800, false), SAVE_2K, "an old 2K save, setting off");
	is(save_size(0, 0x20800, false), SAVE_WITH_MB128, "a save with an MB128, setting off: not cut down");
	is(save_size(0, 0, true), SAVE_WITH_MB128, "no file, setting on");
	is(save_size(0, 0x800, true), SAVE_WITH_MB128, "an old 2K save, setting on");
	// later looks: the table holds what was last written there, or whatever the Pocket rewrote
	is(save_size(SAVE_2K, 0x20800, false), SAVE_2K, "a 2K save stays 2K on a later look");
	is(save_size(SAVE_2K, 0x800, true), SAVE_WITH_MB128, "the setting turned on mid-game");
	is(save_size(SAVE_WITH_MB128, 0x800, false), SAVE_WITH_MB128, "turned off mid-game: it only grows");
	puts(bad ? "save_size: FAILED" : "save_size: all good");
	return bad;
}
