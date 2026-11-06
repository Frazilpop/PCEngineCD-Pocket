// Host tests for the read cache in drivers/apf/fileio.cpp, which test_cue.cpp stubs
// out: the real code against a fake bridge, each read done the moment it's asked
// for. What comes out has to be the file, byte for byte, whatever the buffers' size,
// however a sector straddles them, and with a copy between sends as a CDG track has.

#include <map>
#include <string>
#include <vector>
#define FILEIO_H // its own folder's fileio.h would come first, and host_stubs.h has what it declares
#include "../../drivers/apf/fileio.cpp"

alignas(16384) unsigned char fake_scratch[16384];
uint32_t fake_dataslot_bram[2];

static std::map<std::string, std::string> files;	// path -> what it holds
static std::string open_name;
static uint32_t read_slot, read_address, read_offset;
static int full_reads, fast_reads;
static std::vector<uint8_t> tx;	// what went to the chips
static bool bad;

static void bridge_read(uint32_t length)
{
	const std::string &f = files[open_name];
	uint32_t at = read_address & 0x3FFF;	// fake_scratch is aligned, so these are its low bits
	if ((at + length > sizeof(fake_scratch)) || (read_offset + length > f.size())) {
		bad = true;
		return;
	}
	memcpy(fake_scratch + at, f.data() + read_offset, length);
}

uint32_t dataslot_size(uint16_t) { return files[open_name].size(); }
bool dataslot_ready() { return true; }
uint32_t dataslot_read_lba_set(uint16_t slot, uint32_t address, uint32_t offset)
{
	read_slot = slot;
	read_address = address;
	read_offset = offset;
	return 0;
}
uint32_t dataslot_read_lba(uint32_t length) { full_reads++; bridge_read(length); return 0; }
uint32_t dataslot_read_lba_fast(uint32_t length, bool) { fast_reads++; bridge_read(length); return 0; }
// a save state's load reads the cache's buffers again (RISCFileCacheLoad)
uint32_t dataslot_read(uint16_t slot, uint32_t address, uint32_t offset, uint32_t length)
{
	dataslot_read_lba_set(slot, address, offset);
	bridge_read(length);
	return 0;
}
int OpenFileNameDataSlot(dataslot_type *a, const char *s)
{
	// as the bridge does, the name goes through the bottom of the scratch RAM
	memset(fake_scratch, 0xEE, 264);
	const char *name = strrchr(s, '/') + 1;
	strcpy(a->aft_filename, name);
	open_name = name;
	return 0;
}
void osd_display_info_update(int) {}
int mainprintf(const char *, ...) { return 0; }
void HPS_EnableIO() { }
void HPS_DisableIO() {}
uint8_t spi_b(uint8_t) { return 0; }
uint16_t spi_w(uint16_t) { return 0; }	// the transfer's header
void HPS_spi_write(const uint8_t *addr, uint32_t len, int) { tx.insert(tx.end(), addr, addr + len); }

static int checks, failures;
#define CHECK(c) check((c), #c, __LINE__)
static void check(bool ok, const char *what, int line)
{
	checks++;
	if (!ok) {
		failures++;
		fprintf(stderr, "test_fileio.cpp:%d: failed: %s\n", line, what);
	}
}

static std::string noise(uint32_t size, uint32_t seed)
{
	std::string s(size, 0);
	for (uint32_t i = 0; i < size; i++) {
		seed = seed * 1664525 + 1013904223;
		s[i] = (char)(seed >> 24);
	}
	return s;
}

static dataslot_type a;

static void start(const char *name)
{
	a.aft_dataslot = 101;
	strcpy(a.aft_filepath, "/");
	strcpy(a.aft_filename, name);
	open_name = name;
	tx.clear();
	full_reads = fast_reads = 0;
	bad = false;
}

// Sectors one after the other, as a track plays or reads.
static void play(uint32_t cache, uint32_t sector, uint32_t send, uint32_t first, uint32_t count)
{
	const std::string &f = files["a.bin"];
	RISCFileCacheSize(cache);
	start("a.bin");
	for (uint32_t s = first; s < first + count; s++) {
		tx.clear();
		RISCFileSeek("a.bin", s * sector, sector, 0, &a);
		RISCFileReadAdv(101, 0, 0, 0, send);
		CHECK(tx.size() == send);
		CHECK(tx.size() == send && !memcmp(tx.data(), f.data() + s * sector, send));
		if (failures) {
			fprintf(stderr, "  cache %u sector %u: at sector %u of %u\n", cache, sector, s - first, count);
			return;
		}
	}
	CHECK(!bad);
}

// The same with a CDG track's subcode copied out after each sector's audio.
static void play_cdg(uint32_t cache, uint32_t first, uint32_t count)
{
	const std::string &f = files["a.bin"];
	RISCFileCacheSize(cache);
	start("a.bin");
	for (uint32_t s = first; s < first + count; s++) {
		uint8_t sub[96];
		tx.clear();
		RISCFileSeek("a.bin", s * 2448, 2448, 0, &a);
		RISCFileReadAdv(101, 0, 0, 0, 2352);
		CHECK(!memcmp(tx.data(), f.data() + s * 2448, 2352));
		CHECK(RISCFileSeek("a.bin", s * 2448 + 2352, 96, 0, &a) == 1);
		RISCFileCopy(sub, 96);
		CHECK(!memcmp(sub, f.data() + s * 2448 + 2352, 96));
		if (failures) {
			fprintf(stderr, "  cdg cache %u: at sector %u of %u\n", cache, s - first, count);
			return;
		}
	}
	CHECK(!bad);
}

int main()
{
	files["a.bin"] = noise(4 * 1024 * 1024, 1);
	files["b.bin"] = noise(1024 * 1024, 2);

	static const uint32_t caches[] = {SECTOR_CACHE_SIZE, SECTOR_CACHE_SIZE_SUB};
	for (uint32_t cache : caches) {
		play(cache, 2352, 2352, 0, 500);	// audio
		play(cache, 2352, 2352, 777, 300);
		play(cache, 2048, 2048, 0, 500);	// data
		play(cache, 2448, 2352, 3, 400);	// CDG's audio alone
		play_cdg(cache, 0, 500);
		play_cdg(cache, 1234, 300);

		// a seek, and it carries on from there
		play(cache, 2352, 2352, 50, 10);
		play(cache, 2352, 2352, 1000, 10);

		// another file, whose name goes through the bottom of the scratch RAM
		RISCFileCacheSize(cache);
		start("a.bin");
		RISCFileSeek("a.bin", 0, 2352, 0, &a);
		tx.clear();
		RISCFileSeek("b.bin", 2352 * 5, 2352, 0, &a);
		RISCFileReadAdv(101, 0, 0, 0, 2352);
		CHECK(!memcmp(tx.data(), files["b.bin"].data() + 2352 * 5, 2352));
		CHECK(open_name == "b.bin");
	}

	// a smaller buffer costs a few more reads and no more data
	play(SECTOR_CACHE_SIZE, 2352, 2352, 0, 700);
	int big = full_reads + fast_reads;
	play(SECTOR_CACHE_SIZE_SUB, 2352, 2352, 0, 700);
	int small = full_reads + fast_reads;
	CHECK(small >= big);
	CHECK(small < big * 5 / 4);

	printf("%s: %d of %d checks failed\n", failures ? "FAILED" : "OK", failures, checks);
	return failures != 0;
}
