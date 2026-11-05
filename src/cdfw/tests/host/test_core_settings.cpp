// The Core Settings word and what reaches the chips: ../../app/core_settings.h, with each
// setting's bit read from the interact.json that goes on the card.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fstream>
#include <sstream>
#include <string>
#include "../../app/core_settings.h"

static int bad;
static void is(uint32_t got, uint32_t want, const char *what)
{
	if (got != want) { printf("WRONG %s: 0x%x, wanted 0x%x\n", what, got, want); bad = 1; }
}

// The "value" of the line called name
static uint32_t menu_value(const std::string &json, const char *name)
{
	size_t at = json.find(std::string("\"") + name + "\"");
	if (at == std::string::npos) { printf("WRONG no line called %s\n", name); bad = 1; return 0; }
	at = json.find("\"value\"", at);
	return at == std::string::npos ? 0 : strtoul(json.c_str() + json.find(':', at) + 1, 0, 0);
}

int main()
{
	std::ifstream f("../../../../dist/Cores/frazilpop.PCEngineCD/interact.json");
	std::stringstream s;
	s << f.rdbuf();
	std::string json = s.str();
	if (json.empty()) { puts("WRONG interact.json not read"); return 1; }

	is(menu_value(json, "US Console"), SETTING_US_CONSOLE, "US Console's bit");
	is(menu_value(json, "Arcade System"), SETTING_ARCADE, "Arcade System's bit");
	is(menu_value(json, "Fast CD Seek"), SETTING_FAST_SEEK, "Fast CD Seek's bit");
	is(menu_value(json, "Memory Base 128"), SETTING_MB128, "Memory Base 128's bit");

	is(core_output_bits(0), 0, "nothing set");
	is(core_output_bits(SETTING_MB128), OUTPUT_MB128, "Memory Base 128 alone reaches the chip");
	is(core_output_bits(SETTING_ARCADE), OUTPUT_ARCADE, "Arcade System alone reaches the chip");
	is(core_output_bits(SETTING_FAST_SEEK), 0, "Fast CD Seek isn't the MB128");
	is(core_output_bits(SETTING_US_CONSOLE), 0, "US Console isn't the chips'");
	is(core_output_bits(SETTING_ARCADE | SETTING_MB128), OUTPUT_ARCADE | OUTPUT_MB128, "both");
	is(core_output_bits(0xFFFFFFFF), OUTPUT_ARCADE | OUTPUT_MB128, "nothing else gets through");
	puts(bad ? "core_settings: FAILED" : "core_settings: all good");
	return bad;
}
