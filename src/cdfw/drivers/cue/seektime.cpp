/*
 ============================================================================
 Name        : seektime.c
 Author      : Dave Shadoff
 Version     :
 Copyright   : (C) 2018 Dave Shadoff
 Description : Program to determine seek time, based on start and end sector numbers
 ============================================================================
 */

// The RISC-V CPU has no floats, so this is MiSTer's sum in hundredths of a
// millisecond, which keeps its fractions. MiSTer's get_cd_seek_ms is the reference:
// test_seek in tests/host checks against values taken from it.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cue.h"

typedef struct sector_group {
		int		sec_per_revolution;
		int		sec_start;
		int		sec_end;
		int		rotation_cms;
} sector_group;

#define NUM_SECTOR_GROUPS	14

static const sector_group sector_list[NUM_SECTOR_GROUPS] = {
	{ 10,	0,		12572,	13347 },
	{ 11,	12573,	30244,	14682 },		// Except for the first and last groups,
	{ 12,	30245,	49523,	16017 },		// there are 1606.5 tracks in each range
	{ 13,	49524,	70408,	17351 },
	{ 14,	70409,	92900,	18686 },
	{ 15,	92901,	116998,	20021 },
	{ 16,	116999,	142703,	21356 },
	{ 17,	142704,	170014,	22690 },
	{ 18,	170015,	198932,	24025 },
	{ 19,	198933,	229456,	25360 },
	{ 20,	229457,	261587,	26695 },
	{ 21,	261588,	295324,	28029 },
	{ 22,	295325,	330668,	29364 },
	{ 23,	330669,	333012,	30699 }
};


static int find_group(int sector_num)
{
	int i;
	int group_index = 0;

	for (i = 0; i < NUM_SECTOR_GROUPS; i++)
	{
		if ((sector_num >= sector_list[i].sec_start) && (sector_num <= sector_list[i].sec_end))
		{
			group_index = i;
			break;
		}
	}
	return group_index;
}

// How long a seek takes, in hundredths of a millisecond
int get_cd_seek_cms(int start_sector, int target_sector)
{
	int start_index;
	int target_index;
	int rotation;
	int track_difference;	// in hundredths of a track, as a group is 1606.48 tracks
	int distance = abs(target_sector - start_sector);

	// 360000 = number of sectors in an 80-minute CD (which weren't available).
	// A game can ask for any address: READ6 takes 21 bits and an MSF can come out negative.
	if ((start_sector > 360000) || (start_sector < 0) || (target_sector > 360000) || (target_sector < 0))
	{
		return 0;
	}

	// First, we identify which group the start and end are in
	start_index = find_group(start_sector);
	target_index = find_group(target_sector);
	rotation = sector_list[target_index].rotation_cms;

	// Now we find the track difference
	//
	// Note: except for the first and last sector groups, all groups are 1606.48 tracks per group.
	//
	if (target_index == start_index)
	{
		track_difference = (distance / sector_list[target_index].sec_per_revolution) * 100;
	}
	else if (target_index > start_index)
	{
		track_difference = ((sector_list[start_index].sec_end - start_sector) / sector_list[start_index].sec_per_revolution) * 100;
		track_difference += ((target_sector - sector_list[target_index].sec_start) / sector_list[target_index].sec_per_revolution) * 100;
		track_difference += 160648 * (target_index - start_index - 1);
	}
	else // start_index > target_index
	{
		track_difference = ((start_sector - sector_list[start_index].sec_start) / sector_list[start_index].sec_per_revolution) * 100;
		track_difference += ((sector_list[target_index].sec_end - target_sector) / sector_list[target_index].sec_per_revolution) * 100;
		track_difference += 160648 * (start_index - target_index - 1);
	}

	// Now, we use the algorithm to determine how long to wait. The whole
	// milliseconds are MiSTer's, which come from integer sums: 2 * 1000 / 60 is 33.
	if (distance <= 3)
	{
		return 3300;
	}
	else if (distance < 7)
	{
		return 15000 + rotation * 3 / 4;
	}
	else if (track_difference <= 8000)
	{
		return 28300 + rotation * 3 / 4;
	}
	else if (track_difference <= 16000)
	{
		return 36600 + rotation * 3 / 4;
	}
	else if (track_difference <= 64400)
	{
		// (tracks - 161) * 16.66 / 80, over 100 for the hundredths, and 100 back for the ms
		return 36600 + rotation * 3 / 4 + (track_difference - 16100) * 833 / 4000;
	}
	// unsigned: past the last group is group 0, so this goes to 3.6 million * 833
	return 60000 + rotation / 2 + (int)((uint32_t)(track_difference - 64400) * 833u / 9750u);
}
