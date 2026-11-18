// What pcecd.cpp and fileio.cpp want beyond tests/host/host_stubs.h, whose fake APF
// the CUE loader's tests already use. Force-included after it (tools/sim.sh).
#ifndef SIM_DRIVE_HOST_H
#define SIM_DRIVE_HOST_H
#define UIO_CD_GET 0x34
#define UIO_SET_SDSTAT 0x33
extern bool file_error_enabled;
extern int file_error_code;
extern uint32_t dataslot_open_error;
extern dataslot_type aft;

typedef struct {
	char stage;
	uint32_t resets;
	uint32_t commands;
	uint32_t data_ends;
	uint8_t last[6];
	uint32_t bios_size;
	bool bios_us;
	bool hucard;
	uint32_t bios_error;
	uint32_t park_asks, parks, park_missed, park_late, wait_max, restores, restore_refused;
} drive_trace_t;
extern drive_trace_t drive_trace;

uint32_t RISCGetTimer2(uint32_t fraction);
// a save state's drive block, as main.cpp reads and writes it for the state file: 2K of its
// own, or with --pocket the MPU's RAM from 0xF000 in the bridge's model
extern uint8_t *sim_drive_block;
#define DRIVE_BLOCK sim_drive_block
bool RISCCheckTimer2(uint32_t time);
uint8_t HPS_spi_uio_cmd8(uint8_t cmd, uint8_t parm);
void HPS_io_file_tx_data(const uint8_t *addr, uint32_t len, int cmd);
#endif
