// Every disc in a folder through the firmware's own CUE loader, and the data
// checked where it says the tracks are.
//
//   disc_check <folder> [<folder> ...]     (make disc-check DIR=...)
//
// A data track's first sector has to be there: for a raw sector, its sync bytes,
// and a header naming the disc address the loader gave it, as the mastering tool
// wrote it (a rebuilt hack's bin can keep an old address, which is reported, not
// failed: the sector is still where the file says). "PC Engine CD-ROM SYSTEM" in
// the track's first two sectors is the check for both sector sizes. Every track
// has to lie inside its file, and the disc's last frame has to be the file's last.
// "old" is what 0.2.3's single-file sums would have read for that sector. A disc of
// audio alone is noted, not failed: a CD+G disc is one, and the system card plays it.

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <map>
#include <new>
#include <string>
#include <vector>
#include <algorithm>

#define private public // to read the TOC
#include "../../drivers/cue/cue.cpp"
#undef private

unsigned char fake_scratch[16384];
uint32_t fake_dataslot_bram[2];
dataslot_type aft;
bool file_error_enabled;
int file_error_code;

static std::string cue_real, cue_text;

static void split_path(dataslot_type *a, const char *p)
{
	const char *name = strrchr(p, '/') + 1;
	memset(a->aft_filepath, 0, sizeof(a->aft_filepath));
	memset(a->aft_filename, 0, sizeof(a->aft_filename));
	memcpy(a->aft_filepath, p, name - p);
	strcpy(a->aft_filename, name);
}

int GetFileNameDataSlot(dataslot_type *a) { split_path(a, cue_real.c_str()); return 0; }

int OpenFileNameDataSlot(dataslot_type *a, const char *s)
{
	struct stat st;
	split_path(a, s);
	if (stat(s, &st)) {
		file_error_enabled = 1;
		file_error_code = 2;
		return 1;
	}
	a->aft_op_filesize = st.st_size;
	return 0;
}

uint32_t dataslot_size(uint16_t slot) { return (slot == CUE_SLOT_FIRST) ? cue_text.size() : 0; }

uint32_t dataslot_read(uint16_t slot, uint32_t address, uint32_t offset, uint32_t length)
{
	uint32_t at = address - APF_SCRACH_ADDRESS_OFFSET;
	if ((slot != CUE_SLOT_FIRST) || (at + length > sizeof(fake_scratch)) || (offset + length > cue_text.size())) return 1;
	memcpy(fake_scratch + at, cue_text.data() + offset, length);
	return 0;
}

void clearscrachram(uint32_t offset, uint32_t size) { memset(fake_scratch + offset, 0, size); }
uint32_t dataslot_open_error;
bool dataslot_ready() { return true; }
void RISCFileCacheSize(uint32_t) {}
void RISCFileCopy(uint8_t *, uint32_t) {}
uint32_t RISCFileSeek(const char *, uint32_t, uint32_t, uint32_t, dataslot_type *) { return 1; }
uint32_t RISCFileReadAdv(int, uint8_t, uint8_t, uint8_t, uint32_t) { return 1; }
void RISCSendZeros(uint8_t, uint8_t, uint8_t, uint32_t) {}
void HPS_DisableIO() {}
uint16_t spi_w(uint16_t) { return 0; }
uint16_t HPS_spi_uio_cmd_cont(uint16_t) { return 0; }
void osd_display_timing(uint8_t, uint8_t, uint8_t) {}
void osd_trace_stage(char) {}
int mainprintf(const char *, ...) { return 0; }
int get_cd_seek_cms(int, int) { return 0; }

static std::string dir_of(const std::string &p) { return p.substr(0, p.rfind('/') + 1); }

static bool read_at(const std::string &file, uint32_t pos, unsigned char *buf, size_t n)
{
	int fd = open(file.c_str(), O_RDONLY);
	if (fd < 0) return false;
	ssize_t got = pread(fd, buf, n, pos);
	close(fd);
	return got == (ssize_t)n;
}

static int bcd(unsigned char b) { return (b >> 4) * 10 + (b & 15); }
static bool has_sync(const unsigned char *s)
{
	static const unsigned char sync[12] = {0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0};
	return !memcmp(s, sync, 12);
}

static int bad_discs;

static void check_disc(const std::string &path)
{
	cue_real = path;
	FILE *f = fopen(path.c_str(), "rb");
	if (!f) return;
	cue_text.clear();
	int c;
	while ((c = fgetc(f)) != EOF) cue_text.push_back((char)c);
	fclose(f);
	fake_dataslot_bram[1] = cue_text.size();
	file_error_code = 0;
	memset((void *)&cue, 0, sizeof(cue));
	new (&cue) cue_t();
	uint16_t ret = cue.Load(101);

	toc_t &toc = cue.toc;
	std::string dir = dir_of(path), problems, notes;
	char s[200];
	int data_tracks = 0, ipl = -1, old_wrong = 0;
	static unsigned char buf[2352 * 2];
	if ((ret != 1) || file_error_code || !toc.last) {
		snprintf(s, sizeof(s), " load: ret %d error %d tracks %d;", ret, file_error_code, toc.last);
		problems += s;
	}
	for (int i = 0; i < toc.last; i++) {
		cd_track_t &t = toc.tracks[i];
		uint32_t frames = (t.end - t.start);
		uint64_t past = (uint64_t)t.offset + (uint64_t)frames * t.sector_size;
		if ((uint64_t)t.offset >= (uint64_t)t.size || past > (uint64_t)t.size + t.sector_size) {
			snprintf(s, sizeof(s), " track %d outside its file (%d..%llu of %d);", i + 1, t.offset, (unsigned long long)past, t.size);
			problems += s;
		}
		if ((t.end <= t.start) || (i && (t.first < toc.tracks[i - 1].end))) {
			snprintf(s, sizeof(s), " track %d start %d first %d end %d overlaps;", i + 1, t.start, t.first, t.end);
			problems += s;
		}
		if (t.type != 1) continue;
		data_tracks++;
		std::string file = dir + t.name;
		if (!read_at(file, t.offset, buf, 2 * t.sector_size)) {
			snprintf(s, sizeof(s), " track %d unreadable at %d;", i + 1, t.offset);
			problems += s;
			continue;
		}
		if (t.sector_size == 2352) {
			if (!has_sync(buf)) {
				snprintf(s, sizeof(s), " track %d no sync at %d;", i + 1, t.offset);
				problems += s;
			}
			else {
				int addr = (bcd(buf[12]) * 60 + bcd(buf[13])) * 75 + bcd(buf[14]) - 150;
				if (addr != t.start) {
					snprintf(s, sizeof(s), " track %d header says %d, TOC %d;", i + 1, addr, t.start);
					notes += s;
				}
			}
		}
		for (size_t n = 0; n + 23 < 2u * t.sector_size; n++) {
			if (!memcmp(buf + n, "PC Engine CD-ROM SYSTEM", 23)) ipl = i + 1;
		}
		// 0.2.3 read a single-file disc's sectors at lba * size, whatever came before
		uint32_t old_pos = t.start * t.sector_size;
		if ((toc.tracks[0].name[0] && !strcmp(t.name, toc.tracks[0].name)) && toc.last > 1 && !strcmp(toc.tracks[1].name, toc.tracks[0].name) && old_pos != (uint32_t)t.offset) old_wrong++;
	}
	if (data_tracks && (ipl < 0)) problems += " no PC Engine IPL in any data track's first two sectors;";
	if (!data_tracks) notes += " audio only, as a CD+G disc is;";
	if (sub_size) notes += (sub_size >= toc.end * 96) ? " has its .sub;" : " its .sub stops short of the disc;";
	// the last frame of the last file is the disc's
	if (toc.last) {
		cd_track_t &t = toc.tracks[toc.last - 1];
		if ((uint32_t)(t.offset + (uint64_t)(t.end - t.start) * t.sector_size) < (uint32_t)t.size) {
			snprintf(s, sizeof(s), " last track stops short of the file;");
			problems += s;
		}
	}
	std::string name = path.substr(path.rfind('/') + 1);
	name = name.substr(0, name.size() - 4);
	printf("%-5s %-52.52s tracks %3d  end %6d  data %2d  ipl trk %2d%s%s%s\n", problems.empty() ? "good" : "BAD", name.c_str(), toc.last, toc.end, data_tracks, ipl, old_wrong ? "  (0.2.3 read this disc's data from the wrong place)" : "", problems.c_str(), notes.empty() ? "" : ("  note:" + notes).c_str());
	if (!problems.empty()) bad_discs++;
}

static void walk(const std::string &dir, std::vector<std::string> &cues)
{
	DIR *d = opendir(dir.c_str());
	if (!d) return;
	while (dirent *e = readdir(d)) {
		if (e->d_name[0] == '.') continue;
		std::string p = dir + "/" + e->d_name;
		struct stat st;
		if (stat(p.c_str(), &st)) continue;
		if (S_ISDIR(st.st_mode)) walk(p, cues);
		else if (p.size() > 4 && !strcasecmp(p.c_str() + p.size() - 4, ".cue")) cues.push_back(p);
	}
	closedir(d);
}

int main(int argc, char **argv)
{
	std::vector<std::string> cues;
	for (int i = 1; i < argc; i++) walk(argv[i], cues);
	std::sort(cues.begin(), cues.end());
	for (auto &c : cues) check_disc(c);
	printf("%d discs, %d bad\n", (int)cues.size(), bad_discs);
	return bad_discs != 0;
}
