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
static uint16_t cue_text_slot = CUE_SLOT_FIRST;	// the only slot holding the CUE, as on the Pocket
dataslot_type aft;
bool file_error_enabled;
int file_error_code;

static std::string cue_path, cue_text;
static std::map<std::string, uint32_t> sd_card;	// path -> size
static std::vector<std::string> opens;			// every OpenFileNameDataSlot path
static int cue_reads;
static int fake_read_error;	// what every read of the CUE answers, 0 for none
uint32_t dataslot_open_error;
static std::vector<std::string> sub_opens;	// the opens of the subcode's slot
static std::string sub_file;	// what the .sub holds, read through slot 102
static std::vector<uint32_t> sub_reads;	// where each read of it started
static int sub_read_error;		// what a read of it answers, 0 for none
static uint32_t cache_size;		// what the firmware last set the read buffers to
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
	if (a->aft_dataslot == 102) sub_opens.push_back(s);
	else opens.push_back(s);
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

uint32_t dataslot_size(uint16_t slot) { return (slot == cue_text_slot) ? cue_text.size() : 0; }

uint32_t dataslot_read(uint16_t slot, uint32_t address, uint32_t offset, uint32_t length)
{
	uint32_t at = address - APF_SCRACH_ADDRESS_OFFSET;
	if (slot == 102) {
		sub_reads.push_back(offset);
		if ((at + length > sizeof(fake_scratch)) || (offset + length > sub_file.size())) overflow = true;
		else if (!sub_read_error) memcpy(fake_scratch + at, sub_file.data() + offset, length);
		if (sub_read_error) {
			file_error_enabled = 1;
			file_error_code = 9;
		}
		return sub_read_error;
	}
	cue_reads++;
	if (fake_read_error) {
		// a loader that keeps asking never ends: 0.3.0 and 0.4.0 on the Pocket
		if (cue_reads > 1000) {
			fprintf(stderr, "test_cue.cpp: the CUE was read %d times after an error\n", cue_reads);
			exit(1);
		}
		return fake_read_error;
	}
	if ((slot != cue_text_slot) || (at + length > sizeof(fake_scratch)) || (offset + length > cue_text.size())) {
		overflow = true;
		return 1;
	}
	memcpy(fake_scratch + at, cue_text.data() + offset, length);
	return 0;
}

void clearscrachram(uint32_t offset, uint32_t size) { memset(fake_scratch + offset, 0, size); }
static uint32_t last_seek, last_seek_size;	// what the firmware last asked the read cache for
uint32_t RISCFileSeek(const char *, uint32_t at, uint32_t size, uint32_t, dataslot_type *) { last_seek = at; last_seek_size = size; return 1; }
uint32_t RISCFileReadAdv(int, uint8_t, uint8_t, uint8_t, uint32_t) { return 1; }
void RISCSendZeros(uint8_t, uint8_t, uint8_t, uint32_t) {}
void RISCFileCacheSize(uint32_t size) { cache_size = size; }
void RISCFileCopy(uint8_t *dst, uint32_t len) { for (uint32_t i = 0; i < len; i++) dst[i] = (uint8_t)(last_seek + i); }
bool dataslot_ready() { return true; }
void HPS_DisableIO() {}
static int statuses;	// what SendStatus has sent
static uint16_t last_status;	// the last of them, or for SendDataRequest its first word
static bool status_next;
uint16_t spi_w(uint16_t word)
{
	if (status_next) last_status = word;
	status_next = false;
	return 0;
}
uint16_t HPS_spi_uio_cmd_cont(uint16_t cmd)
{
	if (cmd == UIO_CD_SET) {
		statuses++;
		status_next = true;
	}
	return 0;
}
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
	cue_text_slot = CUE_SLOT_FIRST;
	cue.SetCueSlot(CUE_SLOT_FIRST);
	fake_dataslot_bram[1] = text.size();
	opens.clear();
	sub_opens.clear();
	sub_reads.clear();
	sub_read_error = 0;
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
static std::vector<std::vector<uint8_t>> sent_subcode;	// every transfer of subcode, in order
static int capture(uint8_t *buf, int len, uint8_t)
{
	sent.assign(buf, buf + len);
	if (len >= 2 && (buf[1] & 0x40)) sent_subcode.push_back(sent);
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

/* ---------------------------------------------------------------- subcode */

// A transfer of subcode is 0x4062, the sync word and 96 bytes.
static bool is_subcode(const std::vector<uint8_t> &t)
{
	return (t.size() == 100) && (t[0] == 0x62) && (t[1] == 0x40) && (t[2] == 0) && (t[3] == 0x80);
}

// The 12 bytes of channel Q from a transfer, by the Red Book's order of bits.
static std::vector<uint8_t> channel(const std::vector<uint8_t> &t, int ch)
{
	std::vector<uint8_t> out(12, 0);
	for (int i = 0; i < 96; i++) {
		if (t[4 + i] & (0x80 >> ch)) out[i >> 3] |= 0x80 >> (i & 7);
	}
	return out;
}

// CRC-16-CCITT, bit by bit: the sum subcode Q has, with its bits inverted.
static bool q_crc_good(const std::vector<uint8_t> &q)
{
	uint16_t crc = 0;
	for (int i = 0; i < 10; i++) {
		crc ^= q[i] << 8;
		for (int b = 0; b < 8; b++) crc = (crc & 0x8000) ? (crc << 1) ^ 0x1021 : crc << 1;
	}
	crc = ~crc;
	return (q[10] == (crc >> 8)) && (q[11] == (crc & 0xff));
}

static void tick(int n = 1)
{
	for (int i = 0; i < n; i++) cue.Update();
}

// No .sub: subcode Q made up for each sector played, as MiSTer's, with every other
// channel empty. A play sends a sector and its subcode, two of each on its first.
static void test_subcode_made_up()
{
	three_tracks();
	CHECK(sub_opens == std::vector<std::string>({common + "Three/three.sub"}));
	CHECK(cache_size == SECTOR_CACHE_SIZE);
	CHECK(file_error_code == 0 && !file_error_enabled);	// no .sub is no error

	command(CD_COMM_SAPSP, CD_CDDAMODE_NORMAL, 0x00, 0x06, 0x00, 0x40);	// 00:06:00, address 300, track 1
	cue.latency = 0;
	cue.audiodelay = 0;
	sent_subcode.clear();
	tick();
	CHECK(sent_subcode.size() == 2);	// 300 and 301
	tick();
	CHECK(sent_subcode.size() == 3);
	for (const auto &t : sent_subcode) {
		CHECK(is_subcode(t));
		CHECK(q_crc_good(channel(t, 1)));
		for (int ch = 0; ch < 8; ch++) {
			if (ch != 1) CHECK(channel(t, ch) == std::vector<uint8_t>(12, 0));
		}
	}
	// address 302: 4 seconds 2 frames into track 1, 6 seconds 2 frames on the disc
	const std::vector<uint8_t> q = channel(sent_subcode[2], 1);
	const uint8_t want[10] = {0x01, 0x01, 0x01, 0x00, 0x04, 0x02, 0x00, 0x00, 0x06, 0x02};
	CHECK(!memcmp(q.data(), want, 10));
}

// Paused, the last sector goes round on every tick, with no track to read.
static void test_subcode_when_paused()
{
	three_tracks();
	command(CD_COMM_SAPSP, CD_CDDAMODE_SILENT, 0x00, 0x06, 0x00, 0x40);
	CHECK(cue.state == CD_STATE_PAUSE);
	cue.latency = 2;
	sent_subcode.clear();
	tick(2);	// the head is on its way, so what's sent is the last sector's: nothing yet
	CHECK(sent_subcode.size() == 2);
	CHECK(is_subcode(sent_subcode[1]));
	CHECK(channel(sent_subcode[1], 1) == std::vector<uint8_t>(12, 0));
	tick(3);	// and now it's there
	CHECK(sent_subcode.size() == 5);
	CHECK(q_crc_good(channel(sent_subcode[2], 1)));
	CHECK(sent_subcode[2] == sent_subcode[4]);
	// a drive that's stopped sends none
	cue.state = CD_STATE_IDLE;
	sent_subcode.clear();
	tick(3);
	CHECK(sent_subcode.empty());
}

// A data track sends none, as on MiSTer, nor does a head on its way while playing.
static void test_no_subcode_on_data()
{
	three_tracks();
	command(CD_COMM_SAPSP, CD_CDDAMODE_NORMAL, 0x02, 0x03, 0x25, 0x40);	// address 9100, in the data track
	cue.latency = 0;
	cue.audiodelay = 0;
	sent_subcode.clear();
	tick();
	CHECK(sent_subcode.empty());
	command(CD_COMM_SAPSP, CD_CDDAMODE_NORMAL, 0x00, 0x06, 0x00, 0x40);
	cue.latency = 3;
	sent_subcode.clear();
	tick(3);
	CHECK(sent_subcode.empty());
}

// A .sub beside the CUE, 96 bytes at lba * 96, twelve for each channel: unpacked
// to a symbol a byte, read a run of sectors at a time from its own slot.
static void test_subcode_file()
{
	const std::string dir = common + "Karaoke/";
	const int sectors = 2000;
	sub_file.resize(sectors * 96);
	for (int s = 0; s < sectors; s++) {
		for (int i = 0; i < 96; i++) sub_file[s * 96 + i] = (char)(s * 7 + i * 13 + (s >> 8));
	}
	sd_card.clear();
	sd_card[dir + "k.bin"] = 2352 * sectors;
	sd_card[dir + "k.sub"] = sub_file.size();
	result r = load(dir + "k.cue", "FILE k.bin BINARY\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n");
	CHECK(r.ret == 1);
	CHECK(r.error == 0);
	CHECK(opens == std::vector<std::string>({dir + "k.bin"}));
	CHECK(sub_opens == std::vector<std::string>({dir + "k.sub"}));
	CHECK(cache_size == SECTOR_CACHE_SIZE_SUB);
	CHECK(SUB_CACHE_AT + 21 * 96 <= (int)sizeof(fake_scratch));
	cue.state = CD_STATE_IDLE;
	cue.SendData = capture;

	command(CD_COMM_SAPSP, CD_CDDAMODE_NORMAL, 0x00, 0x03, 0x25, 0x40);	// address 100
	cue.latency = 0;
	cue.audiodelay = 0;
	sent_subcode.clear();
	sub_reads.clear();
	tick(30);
	CHECK(sent_subcode.size() == 31);
	for (int n = 0; n < 31; n++) {
		CHECK(is_subcode(sent_subcode[n]));
		for (int ch = 0; ch < 8; ch++) {
			CHECK(!memcmp(channel(sent_subcode[n], ch).data(), sub_file.data() + (100 + n) * 96 + ch * 12, 12));
		}
	}
	CHECK(sub_reads == std::vector<uint32_t>({100 * 96, 121 * 96}));	// 31 sectors, 21 a read

	// past the file's end, the last sector stays and nothing reads past it
	cue.lba = sectors - 1;
	sent_subcode.clear();
	sub_reads.clear();
	cue.state = CD_STATE_PAUSE;
	tick();
	CHECK(sub_reads == std::vector<uint32_t>({(uint32_t)(sectors - 1) * 96}));
	CHECK(!memcmp(channel(sent_subcode[0], 0).data(), sub_file.data() + (sectors - 1) * 96, 12));
	cue.lba = sectors;
	tick();
	CHECK(sub_reads.size() == 1);
	CHECK(sent_subcode[1] == sent_subcode[0]);

	// a read that fails leaves no box over the game, and is tried again at the next address
	cue.lba = 10;
	sub_read_error = 3;
	sub_reads.clear();
	sent_subcode.clear();
	tick();
	CHECK(sub_reads.size() == 1);
	CHECK(!file_error_enabled && file_error_code == 0);
	sub_read_error = 0;
	cue.lba = 11;
	tick();
	CHECK(sub_reads == std::vector<uint32_t>({10 * 96, 11 * 96}));
	CHECK(!memcmp(channel(sent_subcode[1], 0).data(), sub_file.data() + 11 * 96, 12));
	sd_card.erase(dir + "k.sub");
}

// A CUE with no extension worth changing still loads, with no .sub looked for.
static void test_subcode_short_name()
{
	sd_card.clear();
	sd_card["/k.bin"] = 2352 * 100;
	result r = load("/k.cue", "FILE k.bin BINARY\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n");
	CHECK(r.ret == 1);
	CHECK(sub_opens == std::vector<std::string>({"/k.sub"}));
}

// A CDG track has its subcode in its sectors, already a symbol a byte, so it goes
// as it is. The stub's copy writes each byte's own file position, to see which.
static void test_cdg_track_subcode()
{
	const std::string dir = common + "CDG/";
	sd_card.clear();
	sd_card[dir + "k.bin"] = 2448 * 75 * 60;
	result r = load(dir + "k.cue", "FILE k.bin BINARY\n  TRACK 01 CDG\n    INDEX 01 00:00:00\n");
	CHECK(r.ret == 1);
	CHECK(cache_size == SECTOR_CACHE_SIZE);
	cue.state = CD_STATE_IDLE;
	cue.SendData = capture;
	command(CD_COMM_SAPSP, CD_CDDAMODE_NORMAL, 0x00, 0x02, 0x10, 0x40);	// address 10
	cue.latency = 0;
	cue.audiodelay = 0;
	cue.CDDAFirst = 0;
	sent_subcode.clear();
	tick();
	CHECK(sent_subcode.size() == 1);
	CHECK(is_subcode(sent_subcode[0]));
	CHECK(last_seek == 10 * 2448 + 2352 && last_seek_size == 96);
	for (int i = 0; i < 96; i++) CHECK(sent_subcode[0][4 + i] == (uint8_t)(10 * 2448 + 2352 + i));
}

/* ------------------------------------------------------------- another disc */

// What pcecd.cpp's tray_poll does, and pcecd_set_image's half of it.
static int change_disc(const std::string &path, const std::string &text)
{
	cue_path = path;
	cue_text = text;
	cue_text_slot = CUE_SLOT_OTHER;
	opens.clear();
	sub_opens.clear();
	cue.OpenTray();
	cue.Unload();
	cue.SetCueSlot(CUE_SLOT_OTHER);
	uint16_t ret = cue.Load(101);
	cue.state = (ret == 1) ? CD_STATE_IDLE : CD_STATE_NODISC;
	if (ret != 1) cue.Unload();
	return ret;
}

static std::string one_bin_cue(const std::string &bin)
{
	return "FILE \"" + bin + "\" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n";
}

static void check_sense(uint8_t key, uint8_t asc)
{
	command(CD_COMM_REQUESTSENSE);
	CHECK(sent.size() == 20);
	CHECK(sent[4] == key);
	CHECK(sent[14] == asc);
}

// 46 files to one and back: nothing of the old disc left in the TOC, and the same TOC
// as a first load finds. MiSTer's Unload clears the whole of it; this one cleared the tracks
// it had counted, and left their names and the lead-out's address.
static void test_change_lets_go_of_the_old_disc()
{
	const std::string dir46 = common + game + "/", one = common + "One/";
	sd_card.clear();
	put_bins(dir46, 46);
	sd_card[one + "one.bin"] = 2352 * 500;
	const std::string cue46 = dir46 + game + ".cue", text46 = redump_cue("", 46), text1 = one_bin_cue("one.bin");

	result r46 = load(cue46, text46);
	CHECK(r46.ret == 1);
	CHECK(r46.toc.last == 46);
	result r1 = load(one + "one.cue", text1);
	CHECK(r1.ret == 1);

	load(cue46, text46);
	CHECK(change_disc(one + "one.cue", text1) == 1);
	CHECK(cue.loaded == 1);
	CHECK(same_toc(cue.toc, r1.toc));
	CHECK(opens == std::vector<std::string>({one + "one.bin"}));
	for (int i = 1; i < 100; i++) {
		CHECK(cue.toc.tracks[i].name[0] == 0);
		CHECK(cue.toc.tracks[i].end == 0);
		if (i > 1) CHECK(cue.toc.tracks[i].start == 0);
	}
	CHECK(cue.toc.tracks[1].start == cue.toc.end);	// the lead-out, and not track 2's start
	CHECK(!strcmp(aft.aft_filepath, one.c_str()));	// RISCFileSeek reopens tracks in this folder

	CHECK(change_disc(cue46, text46) == 1);
	CHECK(same_toc(cue.toc, r46.toc));
	CHECK(opens == track_paths(dir46, 46));
	CHECK(!overflow);
}

// A .sub is for its own disc: the read cache goes back to full size with the next one,
// and a load that fails leaves none of it either.
static void test_change_lets_go_of_the_subcode()
{
	const std::string dir = common + "Karaoke/", one = common + "One/", none = common + "None/";
	sub_file.assign(96 * 100, 'x');
	sd_card.clear();
	sd_card[dir + "k.bin"] = 2352 * 100;
	sd_card[dir + "k.sub"] = sub_file.size();
	sd_card[one + "one.bin"] = 2352 * 100;
	const std::string karaoke = "FILE k.bin BINARY\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n";

	load(dir + "k.cue", karaoke);
	cue.SendData = capture;
	CHECK(sub_size == 96 * 100);
	CHECK(cache_size == SECTOR_CACHE_SIZE_SUB);
	CHECK(change_disc(one + "one.cue", one_bin_cue("one.bin")) == 1);
	CHECK(sub_size == 0);
	CHECK(sub_last_lba == -1);
	CHECK(cache_size == SECTOR_CACHE_SIZE);
	CHECK(sub_opens == std::vector<std::string>({one + "one.sub"}));

	load(dir + "k.cue", karaoke);
	cue.SendData = capture;
	CHECK(cache_size == SECTOR_CACHE_SIZE_SUB);
	CHECK(change_disc(none + "gone.cue", one_bin_cue("gone.bin")) == 2);
	CHECK(cue.loaded == 0);
	CHECK(cue.toc.last == 0);
	CHECK(sub_size == 0);
	CHECK(cache_size == SECTOR_CACHE_SIZE);
	cue.CloseTray();
	CHECK(!cue.disc_changed);	// nothing changed to: there's no disc
	command(CD_COMM_TESTUNIT);
	CHECK(last_status == MAKE_STATUS(CD_STATUS_CHECK_COND, 0));
	check_sense(SENSEKEY_NOT_READY, NSE_NO_DISC);

	// and the disc after that one is as good as a first
	CHECK(change_disc(dir + "k.cue", karaoke) == 1);
	CHECK(sub_size == 96 * 100);
	CHECK(cache_size == SECTOR_CACHE_SIZE_SUB);
}

// What the console hears, while the tray is open and after.
static void test_tray()
{
	three_tracks();
	statuses = 0;
	cue.OpenTray();
	CHECK(statuses == 0);	// nothing was waiting on the drive, so nothing is sent
	CHECK(cue.state == CD_STATE_NODISC);

	const uint8_t need_disc[] = {CD_COMM_TESTUNIT, CD_COMM_READ6, CD_COMM_SAPSP, CD_COMM_SAPEP, CD_COMM_PAUSE, CD_COMM_READSUBQ, CD_COMM_GETDIRINFO};
	for (uint8_t c : need_disc) {
		command(c);
		CHECK(statuses == 1);
		CHECK(last_status == MAKE_STATUS(CD_STATUS_CHECK_COND, 0));
		CHECK(cue.state == CD_STATE_NODISC);
		CHECK(!cue.subq_pend);
		check_sense(SENSEKEY_NOT_READY, NSE_TRAY_OPEN);
	}
	command(CD_COMM_MODESELECT6);	// no disc needed
	CHECK(last_status == MAKE_STATUS(CD_STATUS_GOOD, 0));

	// a drive reset from the game doesn't shut it
	cue.Reset();
	command(CD_COMM_TESTUNIT);
	CHECK(last_status == MAKE_STATUS(CD_STATUS_CHECK_COND, 0));
	check_sense(SENSEKEY_NOT_READY, NSE_TRAY_OPEN);

	// the load's state stands behind the open tray
	cue.state = CD_STATE_IDLE;
	command(CD_COMM_READ6, 0, 0, 0, 1);
	CHECK(cue.state == CD_STATE_IDLE);
	check_sense(SENSEKEY_NOT_READY, NSE_TRAY_OPEN);

	cue.CloseTray();
	CHECK(cue.disc_changed);
	command(CD_COMM_READ6, 0, 0, 0, 1);	// told once, whatever the command, and not done
	CHECK(last_status == MAKE_STATUS(CD_STATUS_CHECK_COND, 0));
	CHECK(cue.state == CD_STATE_IDLE);
	CHECK(!cue.disc_changed);
	check_sense(SENSEKEY_UNIT_ATTENTION, NSE_DISC_CHANGED);
	command(CD_COMM_TESTUNIT);
	CHECK(last_status == MAKE_STATUS(CD_STATUS_GOOD, 0));
	command(CD_COMM_GETDIRINFO);
	CHECK(sent[3] == 3);	// the disc answers again

	// a reset with the news not yet told: it's still told, as Mednafen's
	cue.OpenTray();
	cue.state = CD_STATE_IDLE;
	cue.CloseTray();
	cue.Reset();
	command(CD_COMM_TESTUNIT);
	CHECK(last_status == MAKE_STATUS(CD_STATUS_CHECK_COND, 0));
	check_sense(SENSEKEY_UNIT_ATTENTION, NSE_DISC_CHANGED);
}

// A command that hasn't had its status would wait for it for ever, so it gets one, and
// only one, and nothing goes on after it.
static void test_tray_opens_on_a_waiting_command()
{
	three_tracks();
	command(CD_COMM_READ6, 0, 0x34, 0x00, 8);	// the data track, in the middle of a read
	CHECK(cue.state == CD_STATE_READ);
	CHECK(statuses == 0);
	cue.OpenTray();
	CHECK(statuses == 1);
	CHECK(last_status == MAKE_STATUS(CD_STATUS_CHECK_COND, 0));
	tick(10);
	CHECK(statuses == 1);
	CHECK(!cue.has_status);
	check_sense(SENSEKEY_NOT_READY, NSE_TRAY_OPEN);

	// a play that was to interrupt at its end
	three_tracks();
	command(CD_COMM_SAPSP, CD_CDDAMODE_NORMAL, 0x00, 0x00, 0x00, 0x00);
	command(CD_COMM_SAPEP, CD_CDDAMODE_INTERRUPT, 0x00, 0x00, 0x10, 0x00);
	CHECK(statuses == 0);
	CHECK(cue.int_pend);
	cue.OpenTray();
	CHECK(statuses == 1);
	CHECK(last_status == MAKE_STATUS(CD_STATUS_CHECK_COND, 0));
	tick(10);
	CHECK(statuses == 1);

	// READ SUBQ, answered on the next tick
	three_tracks();
	command(CD_COMM_READSUBQ);
	CHECK(statuses == 0);
	cue.OpenTray();
	CHECK(statuses == 1);
	tick(2);
	CHECK(statuses == 1);
	CHECK(sent.empty());

	// a status put off until the seek's done
	three_tracks();
	command(CD_COMM_SAPSP, CD_CDDAMODE_SILENT, 0x00, 0x00, 0x00, 0x00);
	CHECK(cue.has_status);
	statuses = 0;
	cue.OpenTray();
	CHECK(statuses == 1);
	CHECK(!cue.has_status);

	// music playing with nothing waiting: it stops and the console isn't told until it asks
	three_tracks();
	command(CD_COMM_SAPSP, CD_CDDAMODE_NORMAL, 0x00, 0x00, 0x00, 0x00);
	cue.has_status = 0;
	command(CD_COMM_SAPEP, CD_CDDAMODE_NORMAL, 0x00, 0x00, 0x10, 0x00);
	CHECK(cue.state == CD_STATE_PLAY);
	statuses = 0;
	cue.OpenTray();
	CHECK(statuses == 0);
	sent_subcode.clear();
	tick(5);
	CHECK(sent_subcode.empty());
	CHECK(statuses == 0);
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
	test_subcode_made_up();
	test_subcode_when_paused();
	test_no_subcode_on_data();
	test_subcode_file();
	test_subcode_short_name();
	test_cdg_track_subcode();
	test_change_lets_go_of_the_old_disc();
	test_change_lets_go_of_the_subcode();
	test_tray();
	test_tray_opens_on_a_waiting_command();
	printf("%s: %d of %d checks failed\n", failures ? "FAILED" : "OK", failures, checks);
	return failures != 0;
}
