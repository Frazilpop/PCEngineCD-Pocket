// The Core Settings word, interact.json's address 0xF0000004 (AFP_REGISTOR(1)), and which
// of those the chips get through CORE_OUTPUT. Bits differ between the two, so it's all
// said here, and the simulation's switches go through the same function.
#ifndef CORE_SETTINGS_H
#define CORE_SETTINGS_H
#include <stdint.h>

// Each is the "value" of its line in interact.json
static const uint32_t SETTING_US_CONSOLE = 0x1, SETTING_ARCADE = 0x2, SETTING_FAST_SEEK = 0x4, SETTING_MB128 = 0x8;

// core_top.v: CORE_OUTPUT[1] is AC_EN, CORE_OUTPUT[2] is mb128_enable
static const uint32_t OUTPUT_ARCADE = 0x2, OUTPUT_MB128 = 0x4;

// Save states (app/state.h): CORE_OUTPUT[3] the drive is parked, [4] and has read a loaded
// state's block back; CORE_INPUT[4] park, [5] a loaded state's words are all in, [6] the
// park is a load's
static const uint32_t OUTPUT_PARKED = 0x8, OUTPUT_RESTORED = 0x10;
static const uint32_t INPUT_PARK = 0x10, INPUT_STATE_IN = 0x20, INPUT_LOAD = 0x40;

static inline uint32_t core_output_bits(uint32_t settings)
{
	return ((settings & SETTING_ARCADE) ? OUTPUT_ARCADE : 0) | ((settings & SETTING_MB128) ? OUTPUT_MB128 : 0);
}
#endif
