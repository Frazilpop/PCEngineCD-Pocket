
#include "cue.h"

int get_cd_seek_ms(int start_sector, int target_sector);

#define CD_DATA_IO_INDEX 2
cue_t cue;

cue_t::cue_t() {
	latency = 0;
	audiodelay = 0;
	loaded = 0;
	index = 0;
	lba = 0;
	scanOffset = 0;
	isData = 1;
	state = CD_STATE_NODISC;
	audioLength = 0;
	audioOffset = 0;
	SendData = NULL;
	has_status = 0;
	data_req = false;
	can_read_next = false;
	CDDAStart = 0;
	CDDAEnd = 0;
	CDDAMode = CD_CDDAMODE_SILENT;
	region = 0;
	fast_seek = false;
	int_pend = false;
	subq_pend = false;

	stat = 0x0000;

}

const uint32_t memory_offset_cue = 0x00000200;
// The CUE is read into the scratch RAM above the open-file struct one chunk at
// a time, so it can be bigger than the 16K scratch RAM.
#define CUE_CHUNK_SIZE (16384 - memory_offset_cue)
#define CUE_PATH_MAX 255 // the APF path buffers in apf.cpp hold 255 bytes
static uint32_t cue_offset; // next byte of the CUE to read
static uint32_t cue_size;
static char cue_dir[CUE_PATH_MAX]; // folder of the CUE, ending in '/'
static char bin_dir[CUE_PATH_MAX]; // folder of the files it names, ending in '/'
static char path[CUE_PATH_MAX];

// Reads the next CUE line into out without its CR/LF. Returns 0 only at the end
// of the CUE: a blank line is a line (it ended Ys IV's CUE at its second line,
// so the disc had no tracks).
static int sgets(char *out, int sz)
{
	const char *chunk = (const char *)(MAIN_SCRACH_ADDRESS_OFFSET + memory_offset_cue);
	int cnt = 0;
	*out = 0;
	if (cue_offset >= cue_size) return 0;
	while (cue_offset < cue_size)
	{
		uint32_t i = cue_offset % CUE_CHUNK_SIZE;
		if ((i == 0) && dataslot_read(100, APF_SCRACH_ADDRESS_OFFSET + memory_offset_cue, cue_offset,
				(cue_size - cue_offset < CUE_CHUNK_SIZE) ? cue_size - cue_offset : CUE_CHUNK_SIZE))
			break;
		char c = chunk[i];
		if (c == 0) {
			cue_offset = cue_size; // a NUL ends the CUE
			break;
		}
		cue_offset++;
		if (c == 10) break;
		if ((c != 13) && (cnt < sz - 1))
		{
			out[cnt++] = c;
			out[cnt] = 0;
		}
	}
	return 1;
}

// Copies the file name of a FILE command, with or without quotes, into out.
static bool file_arg(const char *s, char *out, int size)
{
	char end = ' ';
	int n = 0;
	while (*s == ' ') s++;
	if (*s == '"') {
		end = '"';
		s++;
	}
	while (*s && (*s != end)) {
		if (n == size - 1) return false;
		out[n++] = *s++;
	}
	out[n] = 0;
	return (n > 0) && ((end == ' ') || (*s == '"'));
}

static bool is_sep(char c)
{
	return (c == '/') || (c == '\\');
}

// The part of p after its last '/' or '\'.
static const char *file_name(const char *p)
{
	const char *name = p;
	for (; *p; p++) {
		if (is_sep(*p)) name = p + 1;
	}
	return name;
}

// Appends the parts of src to path[0..*len), resolving "." and "..". Returns
// false if a ".." goes above the root or the path gets too long.
static bool append_parts(int *len, const char *src)
{
	while (*src)
	{
		while (is_sep(*src)) src++;
		const char *start = src;
		while (*src && !is_sep(*src)) src++;
		int n = src - start;

		if ((n == 0) || ((n == 1) && (start[0] == '.'))) continue;
		if ((n == 2) && (start[0] == '.') && (start[1] == '.')) {
			if (*len <= 1) return false;
			int k = *len - 1;
			while ((k > 1) && (path[k] != '/')) k--;
			*len = k;
			continue;
		}
		if (*len + 1 + n >= CUE_PATH_MAX) return false;
		if (*len > 1) path[(*len)++] = '/';
		memcpy(path + *len, start, n);
		*len += n;
	}
	path[*len] = 0;
	return true;
}

// Puts the full path of 'file' (the name in a FILE command) in path. It is
// relative to the CUE's folder, '\' counts as '/', and "." and ".." are resolved.
static bool resolve(const char *file)
{
	int len = 1;
	path[0] = '/';
	return append_parts(&len, cue_dir) && append_parts(&len, file);
}

// Opens the file named by a FILE command and copies its name into 'name'. It
// is looked for relative to the CUE's folder, then next to the CUE (all that
// firmware up to 0.2.3 did).
static int open_cue_file(const char *file, char *name, int size)
{
	const char *fname = file_name(file);
	bool error_enabled = file_error_enabled;
	int error_code = file_error_code;
	bool resolved = resolve(file);
	if (!resolved || OpenFileNameDataSlot(&aft, path)) {
		if (resolved && (fname == file)) return 1; // no folders, nothing else to try
		snprintf(path, CUE_PATH_MAX, "%s%s", cue_dir, fname);
		if (OpenFileNameDataSlot(&aft, path)) return 1;
		// the failed first try must not leave the error OSD up
		file_error_enabled = error_enabled;
		file_error_code = error_code;
	}
	// Tracks only keep their file name: RISCFileSeek reopens them in the folder
	// of the open file, so all files of a CUE must be in one folder.
	if ((bin_dir[0] && strcmp(bin_dir, aft.aft_filepath)) || ((int)strlen(fname) >= size)) {
		mainprintf("CUE: files must be in one folder, names under %d characters\r\n", size);
		file_error_enabled = 1;
		file_error_code = error_info_dataslot_File_Not_Found;
		return 1;
	}
	strcpy(bin_dir, aft.aft_filepath);
	strcpy(name, fname);
	return 0;
}

// The last track of a file ends where the file does.
void cue_t::EndTrack(int i) {
	cd_track_t *track = &this->toc.tracks[i];
	if (!track->end)
	{
		track->end = track->start + (track->size - track->offset + track->sector_size - 1) / track->sector_size;
	}
	this->toc.end = track->end;
}

// Where a disc address is in the file of track i. Below tracks[i].first the
// address is in a PREGAP, which the file does not have.
uint32_t cue_t::FilePos(int i, int lba) {
	return this->toc.tracks[i].offset + (lba - this->toc.tracks[i].start) * this->toc.tracks[i].sector_size;
}

	// dataslot_type aft;
uint16_t cue_t::LoadCUE(int dataslot) {
	static char line[256]; // room for a FILE line with folders in it
	char fline[255];
	char s[255];
	// static char fname[80];
	char *lptr;
	int hdr = 0;
	int toc_size;
	// First we get the Cue File
	aft.aft_dataslot = 100;
	GetFileNameDataSlot(&aft);
	toc_size = DATASLOT_BRAM(1); // This is where the Cue file will be The BINs are in the 101 dataslot
	if (toc_size == 0) return 100;
	clearscrachram(0,16384);
	memset((void *)&this->toc, 0, sizeof(this->toc));
	strcpy(cue_dir, aft.aft_filepath);
	bin_dir[0] = 0;
	cue_offset = 0;
	cue_size = toc_size;
	aft.aft_dataslot = dataslot;
	// Where a track is on the disc and where it is in its file are two things.
	// A disc address (LBA) counts the frames of every file so far and every
	// PREGAP line, which is on the disc but not in the file; a file position
	// counts bytes, and a file's tracks need not have one sector size (two of
	// the hacks have a MODE1/2048 track among AUDIO in one .bin). Each track
	// keeps its INDEX 01 as both, start and offset, and FilePos goes from there.
	int mm, ss, bb;
	int file_base = 0;	// the disc address of the current file's first frame
	int pregap = 0;		// PREGAP frames so far in the current file
	int pending = 0;	// PREGAP frames of the track being read
	int index0 = -1;	// its INDEX 00, in frames from the start of the file
	bool in_file = false;	// the current file has had a track
	int last_index = 0;	// the track before's INDEX 01, in frames from the start of the file
	int last_size = 0;	// its sector size
	uint32_t last_pos = 0;	// and its file position
	while (sgets(line, sizeof(line)))
	{
		lptr = line;
		// mainprintf("%s\r\n", line);
		while ((*lptr == 0x20) || (*lptr == 0x09)) lptr++;
		if (!*lptr) continue;

		/* decode FILE commands */
		if (!(memcmp(lptr, "FILE", 4)))
		{
			if (!file_arg(lptr + 4, s, sizeof(s))) return -1;
			if (open_cue_file(s, this->toc.tracks[this->toc.last].name, sizeof(this->toc.tracks[0].name))) {
				return 1;
				}
			if (!strstr(lptr, "BINARY") && !strstr(lptr, "MOTOROLA") && !strstr(lptr, "WAVE"))
			{
				return -1;
			}
			// the file before ends where its data does, and this one starts there
			if (this->toc.last) {
				EndTrack(this->toc.last - 1);
				file_base = this->toc.end;
			}
			hdr = (strstr(lptr, ".wav") || strstr(lptr, ".WAV")) ? 44 : 0;
			pregap = 0;
			pending = 0;
			index0 = -1;
			in_file = false;
		}

		/* decode TRACK commands */
		else if (sscanf(lptr, "TRACK %d %*s", &bb) == 1)
		{
			if (bb != (this->toc.last + 1))
			{
				break;
			}
			cd_track_t *track = &this->toc.tracks[this->toc.last];
			track->dataslot = aft.aft_dataslot;
			track->size = aft.aft_op_filesize;
			strcpy(track->name, aft.aft_filename);
			if (strstr(lptr, "MODE1/2048"))
			{
				track->sector_size = 2048;
				track->type = 1;
			}
			else if (strstr(lptr, "MODE1/2352"))
			{
				track->sector_size = 2352;
				track->type = 1;
			}
			else if (strstr(lptr, "AUDIO"))
			{
				track->sector_size = 2352;
				track->type = 0;
			}
			else if (strstr(lptr, "CDG"))
			{
				track->sector_size = 2448;
				track->type = 2;
			}
			pending = 0;
			index0 = -1;
		}

		/* decode PREGAP commands */
		else if (sscanf(lptr, "PREGAP %02d:%02d:%02d", &mm, &ss, &bb) == 3)
		{
			pending += bb + (ss * 75) + (mm * 60 * 75);
		}
		/* decode INDEX commands */
		else if ((sscanf(lptr, "INDEX 00 %02d:%02d:%02d", &mm, &ss, &bb) == 3) ||
			(sscanf(lptr, "INDEX 0 %02d:%02d:%02d", &mm, &ss, &bb) == 3))
		{
			index0 = bb + (ss * 75) + (mm * 60 * 75);
		}
		else if ((sscanf(lptr, "INDEX 01 %02d:%02d:%02d", &mm, &ss, &bb) == 3) || (sscanf(lptr, "INDEX 1 %02d:%02d:%02d", &mm, &ss, &bb) == 3))
		{
			cd_track_t *track = &this->toc.tracks[this->toc.last];
			int index1 = bb + (ss * 75) + (mm * 60 * 75);
			int gap = (index0 >= 0) ? index0 : index1;	// the track's own frames start here in the file

			if (in_file)
			{
				// the frames since the last track are that track's, and then the gap's, in this one's size
				track->offset = last_pos + (gap - last_index) * last_size + (index1 - gap) * track->sector_size;
				// the track before ends at its own last frame; a PREGAP after it is nobody's
				if (!this->toc.tracks[this->toc.last - 1].end)
				{
					this->toc.tracks[this->toc.last - 1].end = file_base + pregap + gap;
				}
			}
			else
			{
				track->offset = hdr + index1 * track->sector_size;
			}
			pregap += pending;
			pending = 0;
			track->start = file_base + pregap + index1;
			track->first = file_base + pregap + gap;
			last_index = index1;
			last_size = track->sector_size;
			last_pos = track->offset;
			in_file = true;
			index0 = -1;
			this->toc.last++;
			if (this->toc.last == 99) break;
		}
	}

	if (this->toc.last) EndTrack(this->toc.last - 1);

	for (int i = 0; i < this->toc.last; i++)
	{
		mainprintf("\x1b[32mPCECD: Track = %u, start = %u, end = %u, offset = %u, sector_size=%d, type = %u, dataslot = %u first = %u \r\n name = %s \r\n\x1b[0m", i, this->toc.tracks[i].start, this->toc.tracks[i].end, this->toc.tracks[i].offset, this->toc.tracks[i].sector_size, this->toc.tracks[i].type, this->toc.tracks[i].dataslot, this->toc.tracks[i].first, this->toc.tracks[i].name);
	}
	
	return 1;
}

uint16_t cue_t::Load(int dataslot)
{
	// Unload();
	uint16_t temp = LoadCUE(dataslot);
	if (temp){
		this->loaded = 1;
		return temp;
	} else {
		this->loaded = 0;
		return temp;
	}
return 0;
}

void cue_t::Unload()
{
	if (this->loaded)
	{


		for (int i = 0; i < this->toc.last; i++)
			{
				this->toc.tracks[i].dataslot = 0;
				this->toc.tracks[i].first = 0;
				this->toc.tracks[i].size = 0;
				this->toc.tracks[i].offset = 0;
				this->toc.tracks[i].pregap = 0;
				this->toc.tracks[i].start = 0;
				this->toc.tracks[i].end = 0;
				this->toc.tracks[i].type = 0;
				this->toc.tracks[i].sector_size = 0;
				// sprintf(this->toc.tracks[i].name,"");
				// int j = 0;
				// do{
					// this->toc.tracks[i].name = NULL;
					// j++;
				// }while(j < 128);
			}
			this->loaded = 0;
			this->toc.end=0;
			this->toc.last=0;
	}
	 mainprintf ("Im Here Father %d \r\n", this->toc.last);
}

void cue_t::Reset() {
	latency = 0;
	audiodelay = 0;
	index = 0;
	lba = 0;
	scanOffset = 0;
	isData = 1;
	state = loaded ? CD_STATE_IDLE : CD_STATE_NODISC;
	audioLength = 0;
	audioOffset = 0;
	has_status = 0;
	data_req = false;
	can_read_next = false;
	CDDAStart = 0;
	CDDAEnd = 0;
	CDDAMode = CD_CDDAMODE_SILENT;
	int_pend = false;
	subq_pend = false;
	stat = 0x0000;

}

void cue_t::Update() {
	msf_t msf;
	bool subq_send = false;

	if (this->state == CD_STATE_READ)
	{
		if (this->latency > 0)
		{
			this->latency--;
			return;
		}

		if (this->index >= this->toc.last)
		{
			this->state = CD_STATE_IDLE;
			return;
		}

		if (!this->can_read_next)
			return;

		this->can_read_next = false;

		if (this->toc.tracks[this->index].type == 1)
		{
			// CD-ROM (Mode 1)
			ReadData();
		}
		else
		{
			if (this->lba >= this->toc.tracks[this->index].start)
			{
				this->isData = 0x00;
			}

		}

		this->cnt--;

		if (!this->cnt) {
			PendStatus(MAKE_STATUS(CD_STATUS_GOOD, 0));
			this->state = CD_STATE_IDLE;
		}

		this->lba++;
		if (this->lba >= this->toc.tracks[this->index].end)
		{
			this->index++;
			this->isData = 0x01;
		}
	}
	else if (this->state == CD_STATE_PLAY)
	{
		if (this->latency > 0)
		{
			this->latency--;
			goto skip;
		}

		if (this->audiodelay > 0)
		{
			this->audiodelay--;
			goto skip;
		}

		this->index = GetTrackByLBA(this->lba, &this->toc);

		for (int i = 0; i <= this->CDDAFirst; i++)
		{
			if (this->toc.tracks[this->index].type == 2)
			{
				RISCFileSeek(this->toc.tracks[this->index].name, FilePos(this->index, this->lba), this->toc.tracks[this->index].sector_size, this->index, &aft);
				ReadCDG();
			}
			else if (this->toc.tracks[this->index].type == 0)
			{
				if (this->lba < this->toc.tracks[this->index].first)
				{
					// in a PREGAP, which the file does not have: silence, as a disc has there
					RISCSendZeros(0x30, 0x09, UIO_CD_DATA, 2352);
				}
				else
				{
					RISCFileSeek(this->toc.tracks[this->index].name, FilePos(this->index, this->lba), this->toc.tracks[this->index].sector_size, this->index, &aft);
					ReadCDDA();
				}
			}
			this->lba++;
		}

		this->CDDAFirst = 0;

		if ((this->lba > this->CDDAEnd) || this->toc.tracks[this->index].type || this->index > this->toc.last)
		{
			if (this->CDDAMode == CD_CDDAMODE_LOOP) {
				this->lba = this->CDDAStart;
			}
			else {
				this->state = CD_STATE_IDLE;
			}
			if (this->int_pend) {
				SendStatus(MAKE_STATUS(CD_STATUS_GOOD, 0));
			}
			this->int_pend = false;
			//riscprintf("\x1b[32mPCECD: playback reached the end %d\r\n\x1b[0m", this->lba);
		}

	skip:
		if (this->subq_pend) {
			this->subq_pend = false;
			subq_send = true;
		}
	}
	else if (this->state == CD_STATE_PAUSE)
	{
		subq_send = this->subq_pend;
		this->subq_pend = false;

		if (this->latency > 0)
		{
			this->latency--;
		}
	}
	else
	{
		subq_send = this->subq_pend;
		this->subq_pend = false;
	}

	// READ SUBQ is answered from here, on the drive's tick, as MiSTer's is
	if (subq_send)
	{
		static uint8_t buf[12];
		int lba_rel = this->lba - this->toc.tracks[this->index].start;

		buf[0] = 0x0A;
		buf[1] = 0 | 0x80;
		buf[2] = this->state == CD_STATE_PAUSE ? 2 : (this->state == CD_STATE_PLAY ? 0 : 3);
		buf[3] = 0;
		buf[4] = BCD(this->index + 1);	// Track
		buf[5] = 1;	// Pregap = index 0, TOC points to index 1; very few audio discs have more indexes

		LBAToMSF(lba_rel, &msf);
		buf[6] = BCD(msf.m);
		buf[7] = BCD(msf.s);
		buf[8] = BCD(msf.f);

		LBAToMSF(this->lba + 150, &msf);
		buf[9] = BCD(msf.m);
		buf[10] = BCD(msf.s);
		buf[11] = BCD(msf.f);

		if (SendData)
			SendData(buf, 10 + 2, CD_DATA_IO_INDEX);
		SendStatus(MAKE_STATUS(CD_STATUS_GOOD, 0));
	}

	int lba_test = this->lba;
	int index_test = GetTrackByLBA(lba_test, &this->toc);
	lba_test = lba_test - this->toc.tracks[index_test].start;
	LBAToMSF(lba_test, &msf);
	osd_display_timing(this->index + 1,  msf.m , msf.s);
}

void cue_t::CommandExec() {
	msf_t msf;
	int new_lba = 0;
	static uint8_t buf[32];
	uint32_t temp_latency;

	memset(buf, 0, 32);
	switch (comm[0]) {
	case CD_COMM_TESTUNIT:
		if (state == CD_STATE_NODISC) {
			CommandError(SENSEKEY_NOT_READY, NSE_NO_DISC, 0, 0);
			SendStatus(MAKE_STATUS(CD_STATUS_CHECK_COND, 0));
		}
		else {
			SendStatus(MAKE_STATUS(CD_STATUS_GOOD, 0));
		}

		break;

	case CD_COMM_REQUESTSENSE:
		buf[0] = 18;
		buf[1] = 0 | 0x80;

		buf[2] = 0x70;
		buf[4] = sense.key;
		buf[9] = 0x0A;
		buf[14] = sense.asc;
		buf[15] = sense.ascq;
		buf[16] = sense.fru;

		sense.key = sense.asc = sense.ascq = sense.fru = 0;

		if (SendData)
			SendData(buf, 18 + 2, CD_DATA_IO_INDEX);

		SendStatus(MAKE_STATUS(CD_STATUS_GOOD, 0));

		break;

	case CD_COMM_GETDIRINFO: {
		int len = 0;
		switch (comm[1]) {
		case 0:
		default:
			buf[0] = 4;
			buf[1] = 0 | 0x80;
			buf[2] = 1;
			buf[3] = BCD(this->toc.last);
			buf[4] = 0;
			buf[5] = 0;
			len = 4 + 2;
			// mainprintf("Command 0 T %u \r\n", (this->toc.last));
			break;
		case 1:
			new_lba = this->toc.end + 150;
			LBAToMSF(new_lba, &msf);

			buf[0] = 4;
			buf[1] = 0 | 0x80;
			buf[2] = BCD(msf.m);
			buf[3] = BCD(msf.s);
			buf[4] = BCD(msf.f);
			// mainprintf("Command 1 M %0.4x S %0.4x F %0.4x  M %0.4x S %0.4x F %0.4x\r\n", buf[2], buf[3], buf[4], msf.m, msf.s, msf.f);
			buf[5] = 0;
			len = 4 + 2;
			break;

		case 2:
			int track = U8(comm[2]);
			new_lba = this->toc.tracks[track - 1].start + 150;
			LBAToMSF(new_lba, &msf);

			buf[0] = 4;
			buf[1] = 0 | 0x80;
			buf[2] = BCD(msf.m);
			buf[3] = BCD(msf.s);
			buf[4] = BCD(msf.f);
			buf[5] = this->toc.tracks[track - 1].type << 2;
			// mainprintf("Command 2 M %0.4x S %0.4x F %0.4x  M %0.4x S %0.4x F %0.4x start %d \r\n", buf[2], buf[3], buf[4], msf.m, msf.s, msf.f, this->toc.tracks[track - 1].start);
			len = 4 + 2;
			break;
		}

		if (SendData && len)
			SendData(buf, len, CD_DATA_IO_INDEX);

		SendStatus(MAKE_STATUS(CD_STATUS_GOOD, 0));
	}
		break;

	case CD_COMM_READ6: {
		new_lba = ((comm[1] << 16) | (comm[2] << 8) | comm[3]) & 0x1FFFFF;
		int cnt_ = comm[4] ? comm[4] : 256;

		int index = GetTrackByLBA(new_lba, &this->toc);

		this->index = index;

		/* HuVideo streams by fetching 120 sectors at a time, taking advantage of the geometry
		 * of the disc to reduce/eliminate seek time */
		if ((this->lba == new_lba) && (cnt_ == 120))
		{
			this->latency = 0;
		}
		/* Sherlock Holmes streams by fetching 252 sectors at a time, and suffers
		 * from slight pauses at each seek */
		else if ((this->lba == new_lba) && (cnt_ == 252))
		{
			this->latency = 5;
		}
		else if (fast_seek)
		{
			this->latency = 0;
		}
		else
		{
			this->latency = (get_cd_seek_ms(this->lba, new_lba) * 3) / 40;	// in ticks of 13.33 ms
			this->audiodelay = 0;
		}

		this->lba = new_lba;
		this->cnt = cnt_;


		this->audioOffset = 0;
		this->can_read_next = true;
		this->state = CD_STATE_READ;
	}
		break;

	case CD_COMM_MODESELECT6:
		if (comm[4]) {
			data_req = true;
		}
		else {
			SendStatus(MAKE_STATUS(CD_STATUS_GOOD, 0));
		}

		break;

	case CD_COMM_SAPSP: {
		switch (comm[9] & 0xc0)
		{
		default:
		case 0x00:
			new_lba = (comm[3] << 16) | (comm[4] << 8) | comm[5];
			break;

		case 0x40:
			MSFToLBA(&new_lba, U8(comm[2]), U8(comm[3]), U8(comm[4]));
			break;

		case 0x80:
		{
			int track = U8(comm[2]);

			if (!track)
				track = 1;
			else if (track > toc.last)
				track = toc.last;
			new_lba = this->toc.tracks[track - 1].start;
		}
		break;
		}

		if (fast_seek)
		{
			this->latency = 0;
			this->audiodelay = 0;
		}
		else
		{
			temp_latency = (get_cd_seek_ms(this->lba, new_lba) * 3) / 40;	// in ticks of 13.33 ms
			this->audiodelay = (220 * 3) / 40;

			if (temp_latency > this->audiodelay)
				this->latency = temp_latency - this->audiodelay;
			else {
				this->latency = temp_latency;
				this->audiodelay = 0;
			}
		}

		this->lba = new_lba;
		int index = GetTrackByLBA(new_lba, &this->toc);

		this->index = index;

		this->CDDAStart = new_lba;
		this->CDDAEnd = this->toc.end;
		this->CDDAMode = comm[1];
		this->CDDAFirst = 1;

		if (this->CDDAMode == CD_CDDAMODE_SILENT) {
			this->state = CD_STATE_PAUSE;
		}
		else {
			this->state = CD_STATE_PLAY;
		}

		PendStatus(MAKE_STATUS(CD_STATUS_GOOD, 0));
	}
		break;

	case CD_COMM_SAPEP: {
		switch (comm[9] & 0xc0)
		{
		default:
		case 0x00:
			new_lba = (comm[3] << 16) | (comm[4] << 8) | comm[5];
			break;

		case 0x40:
			MSFToLBA(&new_lba, U8(comm[2]), U8(comm[3]), U8(comm[4]));
			break;

		case 0x80:
		{
			int track = U8(comm[2]);

			// Note that track (imput from PCE) starts numbering at 1
			// but toc.tracks starts numbering at 0
			//
			if (!track)	track = 1;
			new_lba = ((track-1) >= toc.last) ? this->toc.end : (this->toc.tracks[track - 1].start);
		}
		break;
		}

		this->CDDAMode = comm[1];
		this->CDDAEnd = new_lba;

		if (this->CDDAMode == CD_CDDAMODE_SILENT) {
			this->state = CD_STATE_IDLE;
		}
		else {
			this->state = CD_STATE_PLAY;
		}

		if (this->CDDAMode == CD_CDDAMODE_INTERRUPT) {
			this->int_pend = true;
		}
		else {
			SendStatus(MAKE_STATUS(CD_STATUS_GOOD, 0));
		}

	}
		break;

	case CD_COMM_PAUSE: {
		this->state = CD_STATE_PAUSE;

		SendStatus(MAKE_STATUS(CD_STATUS_GOOD, 0));
	}
		break;

	case CD_COMM_READSUBQ: {
		this->subq_pend = true;
	}
		break;

	default:
		CommandError(SENSEKEY_ILLEGAL_REQUEST, NSE_INVALID_COMMAND, 0, 0);
		has_status = 0;
		SendStatus(MAKE_STATUS(CD_STATUS_CHECK_COND, 0));
		break;
	}
}

uint16_t cue_t::GetStatus() {
	return stat;
}

int cue_t::SetCommand(uint8_t* buf) {
	memcpy(comm, buf, 14);
	return 0;
}

void cue_t::PendStatus(uint16_t status) {
	stat = status;
	has_status = 1;
}

void cue_t::SendStatus(uint16_t status) {
	HPS_spi_uio_cmd_cont(UIO_CD_SET);
	spi_w(status);
	spi_w(region ? 2 : 0);
	HPS_DisableIO();
}

void cue_t::SendDataRequest() {
	HPS_spi_uio_cmd_cont(UIO_CD_SET);
	spi_w(0);
	spi_w((region ? 2 : 0) | 1);
	HPS_DisableIO();
}

void cue_t::SetRegion(uint8_t rgn) {
	region = rgn;
}

void cue_t::SetFastSeek(bool fast) {
	fast_seek = fast;
}

void cue_t::LBAToMSF(int lba, msf_t* msf) {
	msf->m = (lba / 75) / 60;
	msf->s = (lba / 75) % 60;
	msf->f = (lba % 75);
}

void cue_t::MSFToLBA(int* lba, uint8_t m, uint8_t s, uint8_t f) {
	*lba = f + s * 75 + m * 60 * 75 - 150;
}

void cue_t::MSFToLBA(int* lba, msf_t* msf) {
	*lba = msf->f + msf->s * 75 + msf->m * 60 * 75 - 150;
}

int cue_t::GetTrackByLBA(int lba, toc_t* toc) {
	int index = 0;
	while ((toc->tracks[index].end <= lba) && (index < toc->last)) index++;
	return index;
}

void cue_t::ReadData()
{
	cd_track_t *track = &this->toc.tracks[this->index];
	if (track->type && (this->lba >= 0))
	{
		if (this->lba < track->first)
		{
			// in a PREGAP, which the file does not have
			RISCSendZeros(0x00, (0x08 | 0x80), UIO_CD_DATA, 2048);
			return;
		}
		// a raw sector's 2048 bytes of data are after its 16 of sync and header
		RISCFileSeek(track->name, FilePos(this->index, this->lba) + ((track->sector_size == 2048) ? 0 : 16), track->sector_size, this->index, &aft);
		RISCFileReadAdv(track->dataslot, 0x00, (0x08 | 0x80), UIO_CD_DATA, track->sector_size);
	}
}

void cue_t::ReadCDDA()
{
	this->audioLength = 2352;
	this->audioOffset = 0;// 2352;
	RISCFileReadAdv(this->toc.tracks[this->index].dataslot,0x30,0x09,UIO_CD_DATA,2352);
}

void cue_t::ReadCDG()
{
	this->audioLength = 2448;
	this->audioOffset = 0;// 2352;
	RISCFileReadAdv(this->toc.tracks[this->index].dataslot,0x90,(0x09 | 0x80),UIO_CD_DATA,2448);
}

void cue_t::CommandError(uint8_t key, uint8_t asc, uint8_t ascq, uint8_t fru) {
	sense.key = key;
	sense.asc = asc;
	sense.ascq = ascq;
	sense.fru = fru;
}
