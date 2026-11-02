// Host tests for the CUE loader. cue.cpp is compiled into this file, so its
// static helpers can be called, and runs against a fake APF: a 16K scratch
// RAM and a list of files standing in for the SD card.

#include <map>
#include <new>
#include <string>
#include <vector>

#define private public // to read the TOC
#include "../../drivers/cue/cue.cpp"
#include "../../drivers/cue/seektime.cpp"
#undef private

/* ---------------------------------------------------------------- fake APF */

unsigned char fake_scratch[16384];
uint32_t fake_dataslot_bram[2];
dataslot_type aft;
bool file_error_enabled;
int file_error_code;

static std::string cue_path, cue_text;
static std::map<std::string, uint32_t> sd_card;	// path -> size
static std::vector<std::string> opens;			// every OpenFileNameDataSlot path
static int cue_reads;
static int fake_read_error;	// what every read of the CUE answers, 0 for none
static bool overflow;	// something the real hardware could not take

// The split dataslot_pathname_file_decode() in apf.cpp does.
static void split_path(dataslot_type *a, const char *p)
{
	const char *name = strrchr(p, '/') + 1;
	memset(a->aft_filepath, 0, sizeof(a->aft_filepath));
	memset(a->aft_filename, 0, sizeof(a->aft_filename));
	memcpy(a->aft_filepath, p, name - p);
	strcpy(a->aft_filename, name);
}

int GetFileNameDataSlot(dataslot_type *a)
{
	split_path(a, cue_path.c_str());
	return 0;
}

int OpenFileNameDataSlot(dataslot_type *a, const char *s)
{
	opens.push_back(s);
	if (strlen(s) > 254) overflow = true; // apf.cpp copies paths into 255 byte buffers
	split_path(a, s);
	if (!sd_card.count(s)) {
		file_error_enabled = 1;
		file_error_code = 2;
		return 1;
	}
	a->aft_op_filesize = sd_card[s];
	return 0;
}

uint32_t dataslot_read(uint16_t slot, uint32_t address, uint32_t offset, uint32_t length)
{
	uint32_t at = address - APF_SCRACH_ADDRESS_OFFSET;
	cue_reads++;
	if (fake_read_error) {
		// a loader that keeps asking never ends: 0.3.0 and 0.4.0 on the Pocket
		if (cue_reads > 1000) {
			fprintf(stderr, "test_cue.cpp: the CUE was read %d times after an error\n", cue_reads);
			exit(1);
		}
		return fake_read_error;
	}
	if ((slot != 100) || (at + length > sizeof(fake_scratch)) || (offset + length > cue_text.size())) {
		overflow = true;
		return 1;
	}
	memcpy(fake_scratch + at, cue_text.data() + offset, length);
	return 0;
}

void clearscrachram(uint32_t offset, uint32_t size) { memset(fake_scratch + offset, 0, size); }
uint32_t RISCFileSeek(const char *, uint32_t, uint32_t, uint32_t, dataslot_type *) { return 1; }
uint32_t RISCFileReadAdv(int, uint8_t, uint8_t, uint8_t, uint32_t) { return 1; }
void RISCSendZeros(uint8_t, uint8_t, uint8_t, uint32_t) {}
void HPS_DisableIO() {}
uint16_t spi_w(uint16_t) { return 0; }
static int statuses;	// what SendStatus has sent
uint16_t HPS_spi_uio_cmd_cont(uint16_t cmd) { if (cmd == UIO_CD_SET) statuses++; return 0; }
void osd_display_timing(uint8_t, uint8_t, uint8_t) {}
void osd_trace_stage(char) {}
int mainprintf(const char *, ...) { return 0; }

/* ----------------------------------------------------------------- helpers */

static int checks, failures;
#define CHECK(c) check((c), #c, __LINE__)
static void check(bool ok, const char *what, int line)
{
	checks++;
	if (!ok) {
		failures++;
		fprintf(stderr, "test_cue.cpp:%d: failed: %s\n", line, what);
	}
}

static const std::string common = "/Assets/pcecd/common/";
static const std::string game = "De-Ja (Japan)";

static std::string track_file(int t)
{
	char s[32];
	snprintf(s, sizeof(s), " (Track %02d).bin", t);
	return game + s;
}

static uint32_t track_size(int t)
{
	return 2352 * (300 + 37 * t);
}

// Redump-style CUE with one bin per track: track 2 and the last are data.
static std::string redump_cue(const std::string &prefix, int n)
{
	std::string cue;
	for (int t = 1; t <= n; t++) {
		bool data = (t == 2) || ((t == n) && (n > 2));
		char s[64];
		snprintf(s, sizeof(s), "  TRACK %02d %s\r\n", t, data ? "MODE1/2352" : "AUDIO");
		cue += "FILE \"" + prefix + track_file(t) + "\" BINARY\r\n" + s;
		if (t > 1) cue += "    INDEX 00 00:00:00\r\n";
		cue += (t == 1) ? "    INDEX 01 00:00:00\r\n" : data ? "    INDEX 01 00:03:00\r\n" : "    INDEX 01 00:02:00\r\n";
	}
	return cue;
}

static std::vector<std::string> track_paths(const std::string &dir, int n)
{
	std::vector<std::string> paths;
	for (int t = 1; t <= n; t++) paths.push_back(dir + track_file(t));
	return paths;
}

static void put_bins(const std::string &dir, int n)
{
	for (int t = 1; t <= n; t++) sd_card[dir + track_file(t)] = track_size(t);
}

struct result
{
	uint16_t ret;
	toc_t toc;
	int error;
	std::string shown; // the path the file error OSD shows
};

// Loads a CUE the way pcecd_set_image() does, on a freshly booted MPU.
static result load(const std::string &path, const std::string &text, int error = 0)
{
	cue_path = path;
	cue_text = text;
	fake_dataslot_bram[1] = text.size();
	opens.clear();
	cue_reads = 0;
	overflow = false;
	file_error_code = error;
	file_error_enabled = error != 0;
	memset((void *)&cue, 0, sizeof(cue));
	new (&cue) cue_t();

	result r;
	r.ret = cue.Load(101);
	r.toc = cue.toc;
	r.error = file_error_code;
	r.shown = std::string(aft.aft_filepath) + aft.aft_filename;
	CHECK(!overflow);
	return r;
}

static bool same_toc(const toc_t &a, const toc_t &b)
{
	if ((a.last != b.last) || (a.end != b.end)) return false;
	for (int i = 0; i < a.last; i++) {
		const cd_track_t &x = a.tracks[i], &y = b.tracks[i];
		if ((x.start != y.start) || (x.end != y.end) || (x.offset != y.offset) || (x.size != y.size) || (x.first != y.first) ||
			(x.type != y.type) || (x.sector_size != y.sector_size) || (x.dataslot != y.dataslot) || strcmp(x.name, y.name))
			return false;
	}
	return true;
}

/* ------------------------------------------------------------------- tests */

static std::string resolved(const char *dir, const char *file)
{
	strcpy(cue_dir, dir);
	return resolve(file) ? path : "<error>";
}

static void test_resolve()
{
	const char *cues = "/Assets/pcecd/common/_Cues/Japan/";
	CHECK(resolved(cues, "../../_Games/052 De-Ja/x.bin") == "/Assets/pcecd/common/_Games/052 De-Ja/x.bin");
	CHECK(resolved(cues, "..\\..\\_Games\\052 De-Ja\\x.bin") == "/Assets/pcecd/common/_Games/052 De-Ja/x.bin");
	CHECK(resolved("/a/b/", "x.bin") == "/a/b/x.bin");
	CHECK(resolved("/a/b/", "./sub//./x.bin") == "/a/b/sub/x.bin");
	CHECK(resolved("/a/b/", "sub/../x.bin") == "/a/b/x.bin");
	CHECK(resolved("/a/b/", "../../x.bin") == "/x.bin");
	CHECK(resolved("/a/b/", "../../../x.bin") == "<error>");	// above the SD card root
	CHECK(resolved("/a/b/", "/x/y.bin") == "/a/b/x/y.bin");		// always relative to the CUE

	std::string dir = "/" + std::string(100, 'd') + "/";
	CHECK(resolved(dir.c_str(), std::string(152, 'f').c_str()).size() == 254);
	CHECK(resolved(dir.c_str(), std::string(153, 'f').c_str()) == "<error>");

	CHECK(!strcmp(file_name("../a\\b/x (Track 01).bin"), "x (Track 01).bin"));
	CHECK(!strcmp(file_name("x.bin"), "x.bin"));
}

// The TOC firmware 0.2.3 builds for a Redump CUE with its bins next to it.
static void test_plain_cue()
{
	const std::string dir = common + "De-Ja (Japan)/";
	sd_card.clear();
	put_bins(dir, 5);
	result r = load(dir + game + ".cue", redump_cue("", 5));
	CHECK(r.ret == 1);
	CHECK(r.error == 0);
	CHECK(opens == track_paths(dir, 5));
	CHECK(r.toc.last == 5);
	CHECK(r.toc.end == 2055);
	const int starts[] = {0, 562, 861, 1272, 1795}, ends[] = {337, 711, 1122, 1570, 2055};
	for (int i = 0; i < 5; i++) {
		CHECK(r.toc.tracks[i].start == starts[i]);
		CHECK(r.toc.tracks[i].end == ends[i]);
		CHECK(r.toc.tracks[i].size == (int)track_size(i + 1));
		CHECK(r.toc.tracks[i].name == track_file(i + 1));
	}
}

// One unquoted bin holding every track, with a PREGAP. The disc addresses are
// 0.2.3's bar the end, as the PREGAP is on the disc and not in the file. The file
// positions are not: 0.2.3's went on 150 frames too far from the PREGAP on.
static void test_single_bin()
{
	const std::string dir = common + "Gate/";
	sd_card.clear();
	sd_card[dir + "gate.bin"] = 2352 * 75 * 60 * 20;
	result r = load(dir + "gate.cue",
		"FILE gate.bin BINARY\n"
		"  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n"
		"  TRACK 02 AUDIO\n    PREGAP 00:02:00\n    INDEX 01 10:00:00\n"
		"  TRACK 03 AUDIO\n    INDEX 00 12:00:00\n    INDEX 01 12:02:00\n"
		"  TRACK 04 MODE1/2352\n    INDEX 00 15:00:00\n    INDEX 01 15:03:00\n");
	CHECK(opens == std::vector<std::string>({dir + "gate.bin"}));
	CHECK(r.toc.last == 4);
	CHECK(r.toc.end == 90150);
	const int starts[] = {0, 45150, 54300, 67875}, ends[] = {45000, 54150, 67650, 90150};
	const int firsts[] = {0, 45150, 54150, 67650};
	const int offsets[] = {0, 45000 * 2352, 54150 * 2352, 67725 * 2352};
	for (int i = 0; i < 4; i++) {
		CHECK(r.toc.tracks[i].start == starts[i]);
		CHECK(r.toc.tracks[i].end == ends[i]);
		CHECK(r.toc.tracks[i].first == firsts[i]);
		CHECK(r.toc.tracks[i].offset == offsets[i]);
		CHECK(!strcmp(r.toc.tracks[i].name, "gate.bin"));
	}
}

// The frames of a PREGAP are in no file: FilePos of an address past it is where
// the track's own data is.
static void test_pregap_positions()
{
	const std::string dir = common + "Gap/";
	sd_card.clear();
	sd_card[dir + "gap.bin"] = 2352 * 7000;
	load(dir + "gap.cue",
		"FILE \"gap.bin\" BINARY\n"
		"  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
		"  TRACK 02 MODE1/2352\n    PREGAP 00:03:00\n    INDEX 01 00:44:65\n"
		"  TRACK 03 AUDIO\n    PREGAP 00:02:00\n    INDEX 01 01:07:72\n");
	CHECK(cue.toc.tracks[1].start == 3365 + 225);
	CHECK(cue.toc.tracks[2].start == 5097 + 225 + 150);
	CHECK(cue.toc.tracks[0].end == 3365);	// the gap after it is not the track's
	CHECK(cue.FilePos(1, 3365 + 225) == 3365 * 2352);
	CHECK(cue.FilePos(2, 5097 + 375) == 5097 * 2352);
	CHECK(cue.toc.end == 7000 + 375);
	CHECK(cue.GetTrackByLBA(3400, &cue.toc) == 1);	// in the gap
	CHECK(3400 < cue.toc.tracks[1].first);
}

// A MODE1/2048 track among AUDIO in one bin (Mugen Senshi Valis's, Valis IV's):
// a frame after it is 2048 bytes on from a frame in it.
static void test_mixed_sector_sizes()
{
	const std::string dir = common + "Mixed/";
	sd_card.clear();
	sd_card[dir + "mix.bin"] = 3000 * 2352 + 1000 * 2048 + 500 * 2352;
	load(dir + "mix.cue",
		"FILE \"mix.bin\" BINARY\n"
		"  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
		"  TRACK 02 MODE1/2048\n    INDEX 01 00:40:00\n"
		"  TRACK 03 AUDIO\n    INDEX 01 00:53:25\n");
	CHECK(cue.toc.tracks[1].offset == 3000 * 2352);
	CHECK(cue.toc.tracks[2].offset == 3000 * 2352 + 1000 * 2048);
	CHECK(cue.FilePos(1, 3010) == 3000 * 2352 + 10 * 2048);
	CHECK(cue.FilePos(2, 4010) == 3000 * 2352 + 1000 * 2048 + 10 * 2352);
	CHECK(cue.toc.end == 4500);
}

// A CUE's blank lines and tabs are nothing (Ys IV's second line is blank, and the
// loader stopped there with no tracks).
static void test_blank_lines()
{
	const std::string dir = common + "Blank/";
	sd_card.clear();
	sd_card[dir + "b.bin"] = 2352 * 1000;
	result r = load(dir + "b.cue",
		"FILE \"b.bin\" BINARY\n\n"
		"  REM SESSION 01        (*)\n"
		"\tTRACK 01 AUDIO\r\n\t\tINDEX 01 00:00:00\r\n\t\t REM LBA: 0\r\n\r\n   \r\n"
		"    TRACK 02 MODE1/2352\n      INDEX 01 00:02:00\n\n");
	CHECK(r.toc.last == 2);
	CHECK(r.toc.tracks[1].start == 150);
	CHECK(r.toc.end == 1000);
}

// CUEs in one folder, bins in another: same TOC as with the bins next to the CUE.
static void test_relative_paths()
{
	const std::string beside = common + "De-Ja (Japan)/", cues = common + "_Cues/Japan/", games = common + "_Games/052 De-Ja/";
	sd_card.clear();
	put_bins(beside, 5);
	toc_t plain = load(beside + game + ".cue", redump_cue("", 5)).toc;

	sd_card.clear();
	put_bins(games, 5);
	for (const char *prefix : {"../../_Games/052 De-Ja/", "..\\..\\_Games\\052 De-Ja\\", "./../.././/_Games/052 De-Ja/"}) {
		result r = load(cues + game + ".cue", redump_cue(prefix, 5));
		CHECK(r.ret == 1);
		CHECK(r.error == 0);
		CHECK(opens == track_paths(games, 5));
		CHECK(same_toc(r.toc, plain));
	}
}

// Folders that don't exist: the bin next to the CUE is used, as in 0.2.3,
// and the failed first try leaves no error behind.
static void test_fallback()
{
	const std::string dir = common + "De-Ja (Japan)/";
	sd_card.clear();
	put_bins(dir, 5);
	for (const char *prefix : {"Old Folder/", "C:\\Rips\\", "../../../../../../"}) {
		result r = load(dir + game + ".cue", redump_cue(prefix, 5));
		CHECK(r.ret == 1);
		CHECK(r.error == 0);
		CHECK(r.toc.last == 5);
		CHECK(opens.back() == dir + track_file(5));
	}
	CHECK(load(dir + game + ".cue", redump_cue("Old Folder/", 5), 6).error == 6); // keeps an earlier error
}

static void test_errors()
{
	const std::string cues = common + "_Cues/Japan/", games = common + "_Games/052 De-Ja/";

	// missing bin: both places are tried, then the file error OSD
	sd_card.clear();
	result r = load(cues + game + ".cue", redump_cue("../../_Games/052 De-Ja/", 5));
	CHECK(r.ret == 2);
	CHECK(r.error == 2);
	CHECK(opens == std::vector<std::string>({games + track_file(1), cues + track_file(1)}));

	// bins in two folders: tracks would be reopened in the wrong one
	put_bins(games, 5);
	sd_card[common + "Other/" + track_file(2)] = track_size(2);
	std::string cue = redump_cue("../../_Games/052 De-Ja/", 5);
	cue.replace(cue.find("../../_Games/052 De-Ja/" + track_file(2)), 23, "../../Other/");
	r = load(cues + game + ".cue", cue);
	CHECK(r.ret == 2);
	CHECK(r.error == 2);
	CHECK(opens.size() == 2);

	// FILE line with no closing quote
	r = load(cues + game + ".cue", "FILE \"" + track_file(1) + " BINARY\r\n  TRACK 01 AUDIO\r\n");
	CHECK(r.ret == 0xFFFF);
	CHECK(opens.empty());

	// a file name too long for the TOC's 128 byte track names
	const std::string long_name = std::string(130, 'n') + ".bin";
	sd_card[cues + long_name] = track_size(1);
	r = load(cues + game + ".cue", "FILE \"" + long_name + "\" BINARY\r\n  TRACK 01 MODE1/2352\r\n    INDEX 01 00:00:00\r\n");
	CHECK(r.error == 2);
	CHECK(r.toc.last == 0);

	// a path over 254 characters is never sent to the APF
	const std::string deep = common + std::string(180, 'c') + "/";
	sd_card[deep + track_file(1)] = track_size(1);
	r = load(deep + game + ".cue", redump_cue("s/s/s/s/s/s/s/s/s/s/s/s/s/s/s/s/s/s/s/s/", 1));
	CHECK(r.ret == 1);
	CHECK(opens == std::vector<std::string>({deep + track_file(1)}));
}

// (and tracks[99] holds the address after the 99th: toc_t has 100)
// 99 tracks plus REM lines make a 40K CUE: three chunk reads, and the same TOC
// as the same tracks in a small CUE. Tracks past 99 are ignored.
static void test_big_cue()
{
	const std::string cues = common + "_Cues/Japan/", games = common + "_Games/052 De-Ja/";
	sd_card.clear();
	put_bins(games, 120);
	std::string small = redump_cue("../../_Games/052 De-Ja/", 99), big;
	for (size_t at = 0; at < small.size();) {
		size_t end = small.find('\n', at) + 1;
		big += small.substr(at, end - at);
		if (!small.compare(at, 4, "FILE")) big += "REM " + std::string(300, 'x') + "\r\n";
		at = end;
	}
	CHECK(big.size() > 40000);

	toc_t want = load(cues + game + ".cue", small).toc;
	CHECK(cue_reads == 1);
	result r = load(cues + game + ".cue", big);
	CHECK(cue_reads == (int)(big.size() + 15871) / 15872);
	CHECK(cue_reads >= 3);
	CHECK(r.toc.last == 99);
	CHECK(same_toc(r.toc, want));

	r = load(cues + game + ".cue", redump_cue("../../_Games/052 De-Ja/", 120));
	CHECK(r.toc.last == 99);
	CHECK(opens.size() == 99);
}

// Slide a CUE across the end of the first 15,872 byte chunk one byte at a
// time, so every line of it gets split between two reads.
static void test_chunk_boundary()
{
	const std::string cues = common + "_Cues/Japan/", games = common + "_Games/052 De-Ja/";
	sd_card.clear();
	put_bins(games, 5);
	std::string cue = redump_cue("../../_Games/052 De-Ja/", 5);
	toc_t want = load(cues + game + ".cue", cue).toc;
	const size_t chunk = 16384 - 0x200;
	int bad = 0;
	for (size_t pad = chunk - cue.size() - 2; pad <= chunk + 2; pad++) {
		std::string text;
		while (pad - text.size() > 105) text += "REM " + std::string(94, 'p') + "\r\n";
		text += "REM " + std::string(pad - text.size() - 6, 'q') + "\r\n" + cue;
		result r = load(cues + game + ".cue", text);
		if ((r.ret != 1) || !same_toc(r.toc, want)) bad++;
	}
	CHECK(bad == 0);
}

// A read of the CUE that fails ends the load with the code in the error box's
// number, and the disc isn't mounted: it used to ask again for ever.
static void test_read_error()
{
	fake_read_error = 3;
	result r = load(common + "_Cues/Japan/" + game + ".cue", redump_cue("../../_Games/052 De-Ja/", 5));
	fake_read_error = 0;
	CHECK(r.ret == 203);
	CHECK(cue_reads == 1);
	CHECK(r.toc.last == 0);
}

/* ------------------------------------------------- the drive, against MiSTer */

static std::vector<uint8_t> sent;	// what the drive last sent the console as data
static int capture(uint8_t *buf, int len, uint8_t)
{
	sent.assign(buf, buf + len);
	return 1;
}

static void command(uint8_t c0, uint8_t c1 = 0, uint8_t c2 = 0, uint8_t c3 = 0, uint8_t c4 = 0, uint8_t c9 = 0)
{
	uint8_t c[14] = {c0, c1, c2, c3, c4, 0, 0, 0, 0, c9};
	sent.clear();
	statuses = 0;
	cue.SetCommand(c);
	cue.CommandExec();
}

// A disc of two audio tracks and a data track, loaded and ready.
static void three_tracks()
{
	const std::string dir = common + "Three/";
	sd_card.clear();
	sd_card[dir + "three.bin"] = 2352 * 75 * 60 * 3;
	result r = load(dir + "three.cue",
		"FILE three.bin BINARY\n"
		"  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
		"  TRACK 02 AUDIO\n    INDEX 01 01:00:00\n"
		"  TRACK 03 MODE1/2352\n    INDEX 01 02:00:00\n");
	CHECK(r.ret == 1);
	CHECK(r.toc.end == 13500);
	cue.state = CD_STATE_IDLE;
	cue.SendData = capture;
}

static int msf_frames(const uint8_t *p)
{
	return (U8(p[0]) * 60 + U8(p[1])) * 75 + U8(p[2]);
}

// The numbers are MiSTer's get_cd_seek_ms / 13.33, from its source at 7912f76,
// on a compile of it beside the firmware's. A seek's rotation counted in whole here until
// now, where MiSTer counts 3/4 or 1/2 of it, and the limits were missing.
static void test_seek()
{
	static const int seeks[][3] = {
		{0, 1, 2}, {0, 5, 18}, {0, 500, 28}, {0, 1500, 34}, {0, 5000, 40}, {0, 12000, 53}, {0, 30000, 64},
		{100000, 20000, 86}, {0, 200000, 141}, {333000, 0, 178}, {0, 350000, 270}, {0, 360001, 0}, {-1, 100, 0},
	};
	for (const auto &s : seeks) CHECK(get_cd_seek_cms(s[0], s[1]) / SEEK_TICK_CMS == s[2]);
}

// One track past the last is the lead-out: it was address 0 here, so 00:02:00.
static void test_leadout()
{
	three_tracks();
	command(CD_COMM_GETDIRINFO, 2, 0x04);
	CHECK(sent.size() == 6);
	CHECK(sent.size() == 6 && msf_frames(&sent[2]) == 13500 + 150);
	CHECK(sent.size() == 6 && sent[5] == 0);

	// and the last track still says it is data
	command(CD_COMM_GETDIRINFO, 2, 0x03);
	CHECK(sent.size() == 6 && msf_frames(&sent[2]) == 9000 + 150);
	CHECK(sent.size() == 6 && sent[5] == 4);
}

// Any command ends the wait for the end of a track, as on MiSTer. It didn't, so
// the end of a track sent a status in the middle of whatever came next.
static void test_interrupt_ends_with_a_command()
{
	three_tracks();
	command(CD_COMM_SAPSP, CD_CDDAMODE_NORMAL, 0, 0, 0, 0);
	command(CD_COMM_SAPEP, CD_CDDAMODE_INTERRUPT, 0, 0, 10, 0);
	CHECK(cue.int_pend);
	CHECK(statuses == 0);	// the status waits for the end of the track

	command(CD_COMM_TESTUNIT);
	CHECK(!cue.int_pend);
	CHECK(statuses == 1);	// the test's own

	statuses = 0;
	cue.state = CD_STATE_PLAY;
	cue.latency = cue.audiodelay = 0;
	cue.lba = cue.CDDAEnd + 1;
	cue.Update();
	CHECK(cue.state == CD_STATE_IDLE);
	CHECK(statuses == 0);

	// left alone, it does send it
	command(CD_COMM_SAPEP, CD_CDDAMODE_INTERRUPT, 0, 0, 10, 0);
	cue.latency = cue.audiodelay = 0;
	cue.lba = cue.CDDAEnd + 1;
	cue.Update();
	CHECK(statuses == 1);
}

// READ SUBQ says where the drive was before the tick that answers it.
static void test_subq_before_the_tick()
{
	three_tracks();
	cue.state = CD_STATE_PLAY;
	cue.CDDAEnd = 4000;
	cue.CDDAMode = CD_CDDAMODE_NORMAL;
	cue.CDDAFirst = 0;
	cue.latency = cue.audiodelay = 0;
	cue.index = 0;
	cue.lba = 100;
	command(CD_COMM_READSUBQ);
	CHECK(sent.empty());	// answered on the tick
	cue.Update();
	CHECK(cue.lba == 101);
	CHECK(sent.size() == 12);
	CHECK(sent.size() == 12 && sent[2] == 0);	// playing
	CHECK(sent.size() == 12 && msf_frames(&sent[6]) == 100);
	CHECK(sent.size() == 12 && msf_frames(&sent[9]) == 100 + 150);
}

// A file that won't open, or a CUE with no tracks, is no disc, as on MiSTer. The
// error box still has to say how far it got, after pcecd_set_image's Unload.
static void test_no_disc()
{
	const std::string dir = common + "Half/";
	sd_card.clear();
	sd_card[dir + "1.bin"] = 2352 * 100;
	result r = load(dir + "half.cue",
		"FILE 1.bin BINARY\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
		"FILE 2.bin BINARY\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n");
	CHECK(r.ret == 2);
	cue.Unload();
	CHECK(cue.TrackCount() == 1);
	CHECK(cue.toc.last == 0);

	r = load(dir + "none.cue", "REM nothing here\n");
	CHECK(r.ret == 101);
	CHECK(cue.TrackCount() == 0);
}

// A CDG track is audio to the console. It was type 2, which the TOC reported as
// neither, and its sectors went to the data path.
static void test_cdg_is_audio()
{
	const std::string dir = common + "Karaoke/";
	sd_card.clear();
	sd_card[dir + "k.bin"] = 2448 * 75 * 60;
	result r = load(dir + "k.cue", "FILE k.bin BINARY\n  TRACK 01 CDG\n    INDEX 01 00:00:00\n");
	CHECK(r.ret == 1);
	CHECK(r.toc.end == 75 * 60);
	CHECK(r.toc.tracks[0].type == 0);
	CHECK(r.toc.tracks[0].sector_size == 2448);
	CHECK(cue.FilePos(0, 10) == 24480);
	cue.state = CD_STATE_IDLE;
	cue.SendData = capture;
	command(CD_COMM_GETDIRINFO, 2, 0x01);
	CHECK(sent.size() == 6 && sent[5] == 0);
}

int main()
{
	test_resolve();
	test_plain_cue();
	test_single_bin();
	test_pregap_positions();
	test_mixed_sector_sizes();
	test_blank_lines();
	test_relative_paths();
	test_fallback();
	test_errors();
	test_read_error();
	test_big_cue();
	test_chunk_boundary();
	test_seek();
	test_leadout();
	test_interrupt_ends_with_a_command();
	test_subq_before_the_tick();
	test_no_disc();
	test_cdg_is_audio();
	printf("%s: %d of %d checks failed\n", failures ? "FAILED" : "OK", failures, checks);
	return failures != 0;
}
