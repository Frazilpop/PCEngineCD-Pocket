library STD;
use STD.TEXTIO.ALL;
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_TEXTIO.all;
use IEEE.NUMERIC_STD.ALL;

entity cd is
	port(
		RST_N			: in  std_logic;
		CLK 			: in  std_logic;
		EN 			: in  std_logic;

		EXT_A 		: in  std_logic_vector(20 downto 0);
		EXT_DI 		: in  std_logic_vector(7 downto 0);
		EXT_DO 		: out std_logic_vector(7 downto 0);
		EXT_WR_N		: in  std_logic;
		EXT_RD_N		: in  std_logic;
		CPU_CE		: in  std_logic;
		
		SEL_N			: out std_logic;
		IRQ_N			: out std_logic;
		
		RAM_CS_N		: out std_logic;
		BRAM_EN		: out std_logic;
		
		CD_STAT		: in std_logic_vector(7 downto 0);
		CD_MSG		: in std_logic_vector(7 downto 0);
		CD_STAT_GET	: in std_logic;
		
		CD_COMM		: out std_logic_vector(95 downto 0);
		CD_COMM_SEND: out std_logic;
		
		CD_DOUT_REQ	: in std_logic;
		CD_DOUT		: out std_logic_vector(79 downto 0);
		CD_DOUT_SEND: out std_logic;
		
		CD_REGION   : in  std_logic;
		CD_RESET		: out std_logic;
		
		CD_DATA		: in std_logic_vector(7 downto 0);
		CD_DATA_WR	: in std_logic;
		CD_AUDIO_WR	: in std_logic;
		CD_SUBCD_WR	: in std_logic;
		CD_DATA_END	: out std_logic;
		-- The ADPCM chip's memory, outside (adpcm_psram.sv): cd.vhd's slots as they were, a
		-- read's address taken on ADRAM_RD and its data used at the slot's end.
		ADRAM_A		: out std_logic_vector(16 downto 0);
		ADRAM_DI		: out std_logic_vector(3 downto 0);
		ADRAM_DO		: in  std_logic_vector(3 downto 0);
		ADRAM_WE		: out std_logic;
		ADRAM_RD		: out std_logic;

		CD_almost_full		: out std_logic;
		AUDIO_almost_full	: out std_logic;
		
		DM				: in std_logic;
		
		CD_SL			: out signed(15 downto 0);
		CD_SR			: out signed(15 downto 0);
		AD_S			: out signed(15 downto 0);

		-- A save state (state_engine.sv). SS_HOLD stops every register here, in SCSI.vhd,
		-- MSM5205.vhd and the two CEGens wherever they are (EN can't: it also turns off the
		-- selects, the CD RAM and the backup RAM's lock). The registers go out as a chain of
		-- 672 bits, 16 a clock while SS_SHIFT. SS_FREEZE_OK: the ADPCM memory has nothing in
		-- flight (its refresh slot). While held, the FIFO SS_FSEL chooses (0 SCSI's, 1 CD
		-- audio's, 2 the subcode's) is the engine's: SS_FRD takes its head (SS_FQ, before),
		-- SS_FWR puts SS_FD at its tail, SS_FCLR empties it; SS_FCNT is how many it holds.
		SS_HOLD		: in  std_logic := '0';
		SS_SHIFT		: in  std_logic := '0';
		SS_SI			: in  std_logic_vector(15 downto 0) := (others => '0');
		SS_SO			: out std_logic_vector(15 downto 0);
		SS_FREEZE_OK: out std_logic;
		SS_FSEL		: in  std_logic_vector(1 downto 0) := (others => '0');
		SS_FRD		: in  std_logic := '0';
		SS_FWR		: in  std_logic := '0';
		SS_FCLR		: in  std_logic := '0';
		SS_FD			: in  std_logic_vector(31 downto 0) := (others => '0');
		SS_FQ			: out std_logic_vector(31 downto 0);
		SS_FCNT		: out std_logic_vector(12 downto 0)
	);
end cd;

architecture rtl of cd is

	signal REG_SEL 			: std_logic;
	signal RAM_SEL 			: std_logic;
	signal CDRAM_DO			: std_logic_vector(7 downto 0);
	
	signal SCSI_DBI			: std_logic_vector(7 downto 0);
	signal SCSI_DBO			: std_logic_vector(7 downto 0);
	signal SCSI_ACK_N			: std_logic;
	signal SCSI_RST_N			: std_logic;
	signal SCSI_SEL_N			: std_logic;
	signal SCSI_BSY_N			: std_logic;
	signal SCSI_REQ_N			: std_logic;
	signal SCSI_MSG_N			: std_logic;
	signal SCSI_CD_N			: std_logic;
	signal SCSI_IO_N			: std_logic;
	signal CD_STOP_CD_SND	: std_logic;
	
	signal CD_DTD				: std_logic;	--CD data transfer done flag
	signal CD_DTR				: std_logic;	--CD data transfer ready flag
	signal CD_SUBCD			: std_logic;	--CD Subcode data ready flag
	signal CD_DTD_EN			: std_logic;
	signal CD_DTR_EN			: std_logic;
--	signal CD_MOTOR			: std_logic;
	signal CD_SUBCD_EN		: std_logic;
	signal ADPCM_END_EN		: std_logic;
	signal ADPCM_HALF_EN		: std_logic;
	signal CH_SEL				: std_logic;
	signal BRAM_LOCK			: std_logic;
	
	signal AUTO_ACK			: std_logic;
	signal TR_DONE_OLD		: std_logic;
	signal TR_RDY_OLD			: std_logic;
	signal SCSI_REQ_N_OLD	: std_logic;
	signal SCSI_BSY_N_OLD	: std_logic;
	signal SCSI_ACK_N_OLD	: std_logic;
	signal CD_DATA_CNT		: unsigned(10 downto 0);
	
	signal R1802_0				: std_logic;
	signal R1802_1				: std_logic;
	signal R180E_7_4			: std_logic_vector(3 downto 0);
	signal R180F_0				: std_logic;
	signal R180F_7_4			: std_logic_vector(3 downto 0);
	
	signal CDDA_VOL			: std_logic_vector(15 downto 0);
	
	--ADPCM controller
	signal ADPCM_OFFS			: std_logic_vector(15 downto 0);
	signal ADPCM_LEN			: std_logic_vector(16 downto 0);
	signal ADPCM_RDADDR		: std_logic_vector(16 downto 0);
	signal ADPCM_WRADDR		: std_logic_vector(16 downto 0);
	signal ADPCM_CTRL			: std_logic_vector(7 downto 0);
	signal ADPCM_DMA_EN		: std_logic;
	signal ADPCM_DMA_RUN		: std_logic;
	signal ADPCM_END			: std_logic;							--ADPCM end reached flag
	signal ADPCM_HALF			: std_logic;							--ADPCM half reached flag
	signal ADPCM_PLAY			: std_logic;
	signal ADPCM_FREQ			: std_logic_vector(3 downto 0);
	signal ADPCM_FADER		: std_logic_vector(2 downto 0);
	signal ADPCM_RDDATA		: std_logic_vector(7 downto 0);
	signal ADPCM_WRDATA		: std_logic_vector(7 downto 0);
	signal ADPCM_WRITE_PEND	: std_logic;
	signal ADPCM_READ_PEND	: std_logic;
	signal PLAY_READ_PEND	: std_logic;
	signal DMA_WRITE_PEND	: std_logic;
	signal ADPCM_WRITE_NIB	: std_logic;
	signal ADPCM_READ_NIB	: std_logic;
	signal WRITE_PEND			: std_logic;
	signal READ_PEND			: std_logic;
	
	--ADPCM DRAM
	type DRAMSlot_t is (
		SLOT_REFRESH,
		SLOT_READ,
		SLOT_WRITE
	);
	signal DRAM_SLOT 			: DRAMSlot_t; 
	signal DRAM_CLK_CNT		: unsigned(4 downto 0);
	signal DRAM_CLKEN			: std_logic;
	signal DRAM_SLOT_CNT		: unsigned(1 downto 0);
	
	--ADPCM decoder
	signal M5205_D				: std_logic_vector(3 downto 0);
	signal M5205_CLK			: std_logic;
	signal M5205_VCK_R		: std_logic;
	signal M5205_VCK_F		: std_logic;
	signal M5205_SOUT			: signed(15 downto 0);
	signal M5205_CLK_CNT 	: integer range 0 to 511;
	type M5205ClockTable_t is array (0 to 15) of integer range 0 to 511;
	constant ACT : M5205ClockTable_t :=
	(443,	--96712Hz
	 415,	--103199Hz
	 387,	--110619Hz
	 360,	--119048Hz
	 332,	--129032Hz
	 304,	--140647Hz
	 276,	--154799Hz
	 249,	--171821Hz
	 221,	--193424Hz
	 193,	--221239Hz
	 166,	--257732Hz
	 138,	--309598Hz
	 110,	--386100Hz
	 82,	--515464Hz
	 55,	--769231Hz
	 27	--1538462Hz
	);
	
	--CDDA
	signal CD_WR_OLD 			: std_logic;
	signal CD_BYTE_CNT		: unsigned(1 downto 0);
	signal FIFO_FULL 			: std_logic;
	signal FIFO_EMPTY 		: std_logic;
	signal FIFO_RD_REQ		: std_logic;
	signal FIFO_WR_REQ		: std_logic;
	signal FIFO_D 				: std_logic_vector(31 downto 0);
	signal FIFO_Q 				: std_logic_vector(31 downto 0);
	signal FIFO_SCLR			: std_logic;
	signal CDDA_CE 			: std_logic;
	signal ADPCM_CE         : std_logic;
	signal CDDA_SAMPLE		: std_logic;
	signal CDDA_SAMPLE_OLD	: std_logic;
	signal OUTL 				: signed(15 downto 0);
	signal OUTR 				: signed(15 downto 0);
	
	--CD SUBCODE
	signal SUBCD_WR_OLD 			: std_logic;
	signal SUBCD_FIFO_FULL 		: std_logic;
	signal SUBCD_FIFO_EMPTY 	: std_logic;
	signal SUBCD_FIFO_RD_REQ	: std_logic;
	signal SUBCD_FIFO_WR_REQ	: std_logic;
	signal SUBCD_FIFO_D 			: std_logic_vector(7 downto 0);
	signal SUBCD_FIFO_Q 			: std_logic_vector(7 downto 0);
	signal SUBCD_FIFO_SCLR		: std_logic;
	signal SUBCD_CE			: std_logic;
	signal SUBCD_CE_OLD		: std_logic;
	signal SUBCD_CNT			: unsigned(3 downto 0);
	signal SUBCD_BYTE			: std_logic_vector(7 downto 0);
	signal SUBCD_BYTENUM		: unsigned(7 downto 0);
	
	--Fader
	function bool_bit(b : boolean) return std_logic is
	begin
		if b then return '1'; else return '0'; end if;
	end function;

	signal FADE_VOL 			: unsigned(10 downto 0);
	signal FADE_CNT 			: unsigned(7 downto 0);
	signal CDDA_FADE_VOL		: unsigned(10 downto 0);
	signal ADPCM_FADE_VOL	: unsigned(10 downto 0);

	-- the save state's: the chain, the sub-chips' state, the FIFOs' ports
	signal SS_V, SS_N			: std_logic_vector(671 downto 0);
	signal SS_PAD				: std_logic_vector(9 downto 0);
	signal CDDA_CE_SS_Q, CDDA_CE_SS_D, ADPCM_CE_SS_Q, ADPCM_CE_SS_D : std_logic_vector(27 downto 0);
	signal M5205_SS_Q, M5205_SS_D : std_logic_vector(34 downto 0);
	signal SCSI_SS_Q, SCSI_SS_D : std_logic_vector(250 downto 0);
	signal SCSI_RESET_N		: std_logic;
	signal M5205_RST_N		: std_logic;
	signal SS_SCSI_FQ			: std_logic_vector(7 downto 0);
	signal SS_SCSI_FCNT		: std_logic_vector(12 downto 0);
	signal FIFO_USEDW			: std_logic_vector(9 downto 0);
	signal SUBCD_FIFO_USEDW	: std_logic_vector(8 downto 0);
	signal F_D					: std_logic_vector(31 downto 0);
	signal F_WR, F_RD, F_CLR	: std_logic;
	signal SF_D					: std_logic_vector(7 downto 0);
	signal SF_WR, SF_RD, SF_CLR : std_logic;

	-- (the save state's chain reads it, and VHDL-93 can't read an out port)
	signal ADRAM_RD_R : std_logic;

begin

	ADRAM_RD <= ADRAM_RD_R;

	SS_V(7 downto 0) <= SCSI_DBI;
	SS_V(8) <= SCSI_ACK_N;
	SS_V(9) <= SCSI_RST_N;
	SS_V(10) <= SCSI_SEL_N;
	SS_V(11) <= CD_DTD;
	SS_V(12) <= CD_DTR;
	SS_V(13) <= CD_SUBCD;
	SS_V(14) <= CH_SEL;
	SS_V(15) <= BRAM_LOCK;
	SS_V(16) <= CD_DTD_EN;
	SS_V(17) <= CD_DTR_EN;
	SS_V(18) <= CD_SUBCD_EN;
	SS_V(19) <= ADPCM_END_EN;
	SS_V(20) <= ADPCM_HALF_EN;
	SS_V(21) <= AUTO_ACK;
	SS_V(22) <= R1802_0;
	SS_V(23) <= R1802_1;
	SS_V(24) <= R180F_0;
	SS_V(25) <= CDDA_SAMPLE_OLD;
	SS_V(26) <= SUBCD_CE_OLD;
	SS_V(27) <= ADPCM_DMA_EN;
	SS_V(28) <= ADPCM_DMA_RUN;
	SS_V(29) <= ADPCM_END;
	SS_V(30) <= ADPCM_HALF;
	SS_V(31) <= ADPCM_PLAY;
	SS_V(32) <= ADPCM_WRITE_PEND;
	SS_V(33) <= ADPCM_READ_PEND;
	SS_V(34) <= PLAY_READ_PEND;
	SS_V(35) <= DMA_WRITE_PEND;
	SS_V(36) <= ADPCM_WRITE_NIB;
	SS_V(37) <= ADPCM_READ_NIB;
	SS_V(38) <= SCSI_REQ_N_OLD;
	SS_V(39) <= SCSI_BSY_N_OLD;
	SS_V(40) <= SCSI_ACK_N_OLD;
	SS_V(44 downto 41) <= R180E_7_4;
	SS_V(48 downto 45) <= R180F_7_4;
	SS_V(64 downto 49) <= CDDA_VOL;
	SS_V(80 downto 65) <= ADPCM_OFFS;
	SS_V(97 downto 81) <= ADPCM_LEN;
	SS_V(114 downto 98) <= ADPCM_RDADDR;
	SS_V(131 downto 115) <= ADPCM_WRADDR;
	SS_V(139 downto 132) <= ADPCM_CTRL;
	SS_V(143 downto 140) <= ADPCM_FREQ;
	SS_V(146 downto 144) <= ADPCM_FADER;
	SS_V(154 downto 147) <= ADPCM_RDDATA;
	SS_V(162 downto 155) <= ADPCM_WRDATA;
	SS_V(166 downto 163) <= M5205_D;
	SS_V(177 downto 167) <= std_logic_vector(CD_DATA_CNT);
	SS_V(182 downto 178) <= std_logic_vector(DRAM_CLK_CNT);
	SS_V(183) <= DRAM_CLKEN;
	SS_V(185 downto 184) <= std_logic_vector(DRAM_SLOT_CNT);
	SS_V(186) <= ADRAM_RD_R;
	SS_V(195 downto 187) <= std_logic_vector(to_unsigned(M5205_CLK_CNT, 9));
	SS_V(196) <= M5205_CLK;
	SS_V(198 downto 197) <= std_logic_vector(CD_BYTE_CNT);
	SS_V(230 downto 199) <= FIFO_D;
	SS_V(231) <= FIFO_WR_REQ;
	SS_V(232) <= CD_WR_OLD;
	SS_V(240 downto 233) <= SUBCD_FIFO_D;
	SS_V(241) <= SUBCD_FIFO_WR_REQ;
	SS_V(242) <= SUBCD_WR_OLD;
	SS_V(243) <= FIFO_SCLR;
	SS_V(244) <= FIFO_RD_REQ;
	SS_V(245) <= SUBCD_CE;
	SS_V(246) <= SUBCD_FIFO_SCLR;
	SS_V(247) <= SUBCD_FIFO_RD_REQ;
	SS_V(248) <= CDDA_SAMPLE;
	SS_V(264 downto 249) <= std_logic_vector(OUTL);
	SS_V(280 downto 265) <= std_logic_vector(OUTR);
	SS_V(284 downto 281) <= std_logic_vector(SUBCD_CNT);
	SS_V(292 downto 285) <= SUBCD_BYTE;
	SS_V(300 downto 293) <= std_logic_vector(SUBCD_BYTENUM);
	SS_V(311 downto 301) <= std_logic_vector(FADE_VOL);
	SS_V(319 downto 312) <= std_logic_vector(FADE_CNT);
	SS_V(347 downto 320) <= CDDA_CE_SS_Q;
	SS_V(375 downto 348) <= ADPCM_CE_SS_Q;
	SS_V(410 downto 376) <= M5205_SS_Q;
	SS_V(661 downto 411) <= SCSI_SS_Q;
	SS_V(671 downto 662) <= SS_PAD;
	SS_N <= SS_V(655 downto 0) & SS_SI;
	SS_SO <= SS_V(671 downto 656);
	CDDA_CE_SS_D <= SS_N(347 downto 320);
	ADPCM_CE_SS_D <= SS_N(375 downto 348);
	M5205_SS_D <= SS_N(410 downto 376);
	SCSI_SS_D <= SS_N(661 downto 411);

	process(CLK)
	begin
		if rising_edge(CLK) then
			if SS_SHIFT = '1' then
				SS_PAD <= SS_N(671 downto 662);
			end if;
		end if;
	end process;

	-- the refresh slot: the last read's nibble taken, the next write not yet asked for
	SS_FREEZE_OK <= '1' when DRAM_SLOT_CNT = "00" else '0';

	-- held, the FIFOs are the engine's
	SS_FQ <= x"000000" & SS_SCSI_FQ when SS_FSEL = "00"
	    else FIFO_Q when SS_FSEL = "01"
	    else x"000000" & SUBCD_FIFO_Q;
	SS_FCNT <= SS_SCSI_FCNT when SS_FSEL = "00"
	    else "00" & FIFO_FULL & FIFO_USEDW when SS_FSEL = "01"
	    else "0000" & SUBCD_FIFO_USEDW;
	F_D    <= SS_FD when SS_HOLD = '1' else FIFO_D;
	F_WR   <= (SS_FWR and bool_bit(SS_FSEL = "01")) when SS_HOLD = '1' else FIFO_WR_REQ;
	F_RD   <= (SS_FRD and bool_bit(SS_FSEL = "01")) when SS_HOLD = '1' else FIFO_RD_REQ;
	F_CLR  <= (SS_FCLR and bool_bit(SS_FSEL = "01")) when SS_HOLD = '1' else FIFO_SCLR;
	SF_D   <= SS_FD(7 downto 0) when SS_HOLD = '1' else SUBCD_FIFO_D;
	SF_WR  <= (SS_FWR and bool_bit(SS_FSEL = "10")) when SS_HOLD = '1' else SUBCD_FIFO_WR_REQ;
	SF_RD  <= (SS_FRD and bool_bit(SS_FSEL = "10")) when SS_HOLD = '1' else SUBCD_FIFO_RD_REQ;
	SF_CLR <= (SS_FCLR and bool_bit(SS_FSEL = "10")) when SS_HOLD = '1' else SUBCD_FIFO_SCLR;

	-- the sub-chips' resets come from registers on the chain, which pass through anything as
	-- it moves: held, they stay off
	SCSI_RESET_N <= RST_N and (SCSI_RST_N or SS_HOLD);
	M5205_RST_N <= (not ADPCM_CTRL(7) and ADPCM_PLAY and EN) or SS_HOLD;

	REG_SEL <= '1' when EXT_A(20 downto 13) = x"FF" and EXT_A(12 downto 8) = "11000" else '0';

	process( CLK, RST_N ) 
	variable NEW_ADPCM_LEN : std_logic_vector(16 downto 0);
	begin
		if RST_N = '0' then
			SCSI_DBI <= (others => '0');
			SCSI_ACK_N <= '1';
			SCSI_RST_N <= '1';
			SCSI_SEL_N <= '1';
			CD_DTD <= '0';
			CD_DTR <= '0';
			CD_SUBCD <= '0';
			CH_SEL <= '0';
			BRAM_LOCK <= '1';
			CD_DTD_EN <= '0';
			CD_DTR_EN <= '0';
--			CD_MOTOR <= '0';
			CD_SUBCD_EN <= '0';
			ADPCM_END_EN <= '0';
			ADPCM_HALF_EN <= '0';
			AUTO_ACK <= '0';
			
			CDDA_VOL <= (others => '0');
			
			SUBCD_CE_OLD <= '0';
			ADPCM_OFFS <= (others => '0');
			ADPCM_LEN <= (others => '0');
			ADPCM_RDADDR <= (others => '0');
			ADPCM_WRADDR <= (others => '0');
			ADPCM_CTRL <= (others => '0');
			ADPCM_DMA_EN <= '0';
			ADPCM_DMA_RUN <= '0';
			ADPCM_END <= '0';
			ADPCM_HALF <= '0';
			ADPCM_PLAY <= '0';
			ADPCM_FREQ <= (others => '0');
			ADPCM_WRDATA <= (others => '0');
			ADPCM_RDDATA <= (others => '0');
			ADPCM_WRITE_PEND <= '0';
			ADPCM_READ_PEND <= '0';
			PLAY_READ_PEND <= '0';
			ADPCM_WRITE_NIB <= '0';
			ADPCM_READ_NIB <= '0';
			M5205_D <= (others => '0');
		elsif rising_edge( CLK ) then
			if EN = '1' and SS_HOLD = '0' then
			if CPU_CE = '1' then
				SCSI_SEL_N <= '1';
				if REG_SEL = '1' and EXT_WR_N = '0' then
					case EXT_A(7 downto 0) is
						when x"00" =>
							SCSI_SEL_N <= '0';
							CD_DTD <= '0';
							CD_DTR <= '0';
--							if SCSI_DBI = x"00" then
--								CD_MOTOR <= '1';
--							end if;
						when x"01" =>
							SCSI_DBI <= EXT_DI;
						when x"02" =>
							SCSI_ACK_N <= not EXT_DI(7);
							CD_DTR_EN <= EXT_DI(6);
							CD_DTD_EN <= EXT_DI(5);
							CD_SUBCD_EN <= EXT_DI(4);
							ADPCM_END_EN <= EXT_DI(3);
							ADPCM_HALF_EN <= EXT_DI(2);
							R1802_1 <= EXT_DI(1);
							R1802_0 <= EXT_DI(0);
						when x"04" =>
							SCSI_RST_N <= not EXT_DI(1);
							if EXT_DI(1) = '1' then
								CD_DTD <= '0';
								CD_DTR <= '0';
							end if;
						when x"05" =>
							if CDDA_SAMPLE = '1' and CDDA_SAMPLE_OLD = '0' then
								if CH_SEL = '0' then
									CDDA_VOL <= std_logic_vector(OUTL);   -- CDDA_VOL is returned by a different process in *the same cycle*, so we assign the opposite of what documentation says
								else
									CDDA_VOL <= std_logic_vector(OUTR);
								end if;
								CH_SEL <= not CH_SEL;
							end if;
							CDDA_SAMPLE_OLD <= CDDA_SAMPLE;
							
						when x"07" =>
							BRAM_LOCK <= not EXT_DI(7);  -- unlock when bit 7 is '1', but also lock if bit 7 is '0'
						when x"08" =>
							ADPCM_OFFS(7 downto 0) <= EXT_DI;
						when x"09" =>
							ADPCM_OFFS(15 downto 8) <= EXT_DI;
						when x"0A" =>
							ADPCM_WRDATA <= EXT_DI;
							ADPCM_WRITE_NIB <= '0';
							ADPCM_WRITE_PEND <= '1';
						when x"0B" =>
							ADPCM_DMA_EN <= EXT_DI(1);
							ADPCM_DMA_RUN <= EXT_DI(0);
						when x"0D" =>
							ADPCM_CTRL <= EXT_DI;
							if EXT_DI(5) = '1' and ADPCM_CTRL(5) = '0' then
								ADPCM_PLAY <= '1';
								ADPCM_HALF <= '0';
							elsif EXT_DI(5) = '0' and ADPCM_CTRL(5) = '1' then
								ADPCM_PLAY <= '0';
							end if;
						when x"0E" =>
							R180E_7_4 <= EXT_DI(7 downto 4);
							ADPCM_FREQ <= EXT_DI(3 downto 0);
						when x"0F" =>
							R180F_7_4 <= EXT_DI(7 downto 4);
							ADPCM_FADER <= EXT_DI(3 downto 1);
							R180F_0 <= EXT_DI(0);
						when others => null;
					end case;
				elsif REG_SEL = '1' and EXT_RD_N = '0' then
					case EXT_A(7 downto 0) is
						when x"03" =>
							BRAM_LOCK <= '1';
						when x"07" =>
							CD_SUBCD <= '0';
						when x"08" =>
							if SCSI_REQ_N = '0' and SCSI_IO_N = '0' and SCSI_CD_N = '1' and SCSI_ACK_N = '1' then 
								SCSI_ACK_N <= '0';
								AUTO_ACK <= '1';
							end if;
						when x"0A" =>
							ADPCM_READ_NIB <= '0';
							ADPCM_READ_PEND <= '1';
						when others => null;
					end case;
				end if;
			end if;
			
			if AUTO_ACK = '1' and SCSI_REQ_N = '1' then
				SCSI_ACK_N <= '1';
				AUTO_ACK <= '0';
			end if;
			
			if (ADPCM_DMA_EN = '1' or ADPCM_DMA_RUN = '1') and DMA_WRITE_PEND = '0' then
				if SCSI_REQ_N = '0' and SCSI_IO_N = '0' and SCSI_CD_N = '1' and SCSI_ACK_N = '1' then
					ADPCM_WRDATA <= SCSI_DBO;
					DMA_WRITE_PEND <= '1';
				end if;
			end if;
			
			SCSI_REQ_N_OLD <= SCSI_REQ_N;
			SCSI_BSY_N_OLD <= SCSI_BSY_N;
			if CD_DTD = '0' and SCSI_REQ_N = '0' and SCSI_REQ_N_OLD = '1' and SCSI_BSY_N = '0' and SCSI_IO_N = '0' and SCSI_CD_N = '0' then
				CD_DTD <= '1';
			elsif CD_DTD = '1' and ((SCSI_REQ_N = '1' and SCSI_REQ_N_OLD = '0' and SCSI_MSG_N = '0') or (SCSI_BSY_N = '1' and SCSI_BSY_N_OLD = '0')) then
				CD_DTD <= '0';
			end if;
			
			SCSI_ACK_N_OLD <= SCSI_ACK_N;
			if CD_DTR = '0' and SCSI_REQ_N = '0' and SCSI_BSY_N = '0' and SCSI_CD_N = '1' and SCSI_MSG_N = '1' and SCSI_IO_N = '0' then
				CD_DTR <= '1';
				CD_DATA_CNT <= (others => '0');
			elsif CD_DTR = '1' and SCSI_ACK_N = '1' and SCSI_ACK_N_OLD = '0' and SCSI_BSY_N = '0' and SCSI_CD_N = '1' and SCSI_MSG_N = '1' and SCSI_IO_N = '0' then
				CD_DATA_CNT <= CD_DATA_CNT + 1;
				if CD_DATA_CNT = 2047 then
					CD_DTR <= '0';
					ADPCM_DMA_RUN <= '0';
				end if;
			elsif CD_DTR = '1' and (SCSI_BSY_N = '1' and SCSI_BSY_N_OLD = '0') then
				CD_DTR <= '0';
			end if;

			SUBCD_CE_OLD <= SUBCD_CE;
			if CD_SUBCD = '0' and SUBCD_CE = '1' and SUBCD_CE_OLD = '0' then
				CD_SUBCD <= '1';
			end if;
			
			if M5205_VCK_R = '1' and ADPCM_PLAY = '1' then
				PLAY_READ_PEND <= '1';
			end if;
			
			if DRAM_CLKEN = '1' and ADPCM_CTRL(7) = '0' then
				case DRAM_SLOT is
					when SLOT_READ =>
						NEW_ADPCM_LEN := std_logic_vector(unsigned(ADPCM_LEN) - 1);
						if ADPCM_READ_PEND = '1' or PLAY_READ_PEND = '1' then
							M5205_D <= ADRAM_DO;
							if PLAY_READ_PEND = '1' then
								PLAY_READ_PEND <= '0';
							end if;
							
							ADPCM_READ_NIB <= not ADPCM_READ_NIB;
							if ADPCM_READ_NIB = '0' then
								ADPCM_RDDATA(7 downto 4) <= ADRAM_DO;
							else
								ADPCM_RDDATA(3 downto 0) <= ADRAM_DO;
							end if;
							if ADPCM_READ_NIB = '1' then
								if ADPCM_LEN /= "0"&x"0000" then
									ADPCM_LEN <= NEW_ADPCM_LEN;
								end if;
								if ADPCM_READ_PEND = '1' then
									ADPCM_READ_PEND <= '0';
								end if;
							end if;
							if ADPCM_LEN < "0"&x"8000" then
								ADPCM_HALF <= '1';
							elsif ADPCM_LEN = "0"&x"8000" and ADPCM_CTRL(4) = '0' then
								ADPCM_HALF <= '1';
							else
								ADPCM_HALF <= '0';
							end if;
							if ADPCM_LEN = "0"&x"0000" then
								ADPCM_END <= '1';
								if ADPCM_READ_PEND = '1' and ADPCM_CTRL(4) = '0' then
									ADPCM_HALF <= '0';
								end if;
								if ADPCM_CTRL(6) = '1' and ADPCM_PLAY = '1' then
									ADPCM_PLAY <= '0';
									M5205_D <= (others => '0');
									ADPCM_CTRL(5) <= '0';
								end if;
							end if;
						end if;
						
					when SLOT_WRITE =>
						NEW_ADPCM_LEN := std_logic_vector(unsigned(ADPCM_LEN) + 1);
						if ADPCM_WRITE_PEND = '1' or DMA_WRITE_PEND = '1' then
							ADPCM_WRITE_NIB <= not ADPCM_WRITE_NIB;
							if ADPCM_WRITE_NIB = '1' then
								ADPCM_LEN <= NEW_ADPCM_LEN;
								if ADPCM_WRITE_PEND = '1' then
									ADPCM_WRITE_PEND <= '0';
								end if;
								if DMA_WRITE_PEND = '1' then
									DMA_WRITE_PEND <= '0';
									SCSI_ACK_N <= '0';
									AUTO_ACK <= '1';
								end if;
							end if;
							ADPCM_HALF <= not ADPCM_LEN(15) and not ADPCM_LEN(16);
							if ADPCM_LEN = "0"&x"0000" then
								ADPCM_END <= '1';
							end if;
						end if;
						
					when others => null;
				end case;
			end if;
			
			if ADPCM_CTRL(4) = '1' then
				ADPCM_LEN <= "0"&ADPCM_OFFS;
				ADPCM_END <= '0';
			end if;
			
			if ADPCM_CTRL(7) = '1' then
				ADPCM_OFFS <= (others => '0');
				ADPCM_LEN <= (others => '0');
				ADPCM_WRADDR <= (others => '0');
				ADPCM_RDADDR <= (others => '0');
				ADPCM_END <= '0';
				ADPCM_HALF <= '0';
			end if;
			
			if DRAM_CLKEN = '1' and DRAM_SLOT = SLOT_WRITE and (ADPCM_WRITE_PEND = '1' or DMA_WRITE_PEND = '1') then
				if ADPCM_CTRL(1) = '1' then
					ADPCM_WRADDR <= ADPCM_OFFS & "0";
				else
					ADPCM_WRADDR <= std_logic_vector(unsigned(ADPCM_WRADDR) + 1);
				end if;
			elsif CPU_CE = '1' and REG_SEL = '1' and EXT_WR_N = '0' and EXT_A(7 downto 0) = x"0D" and EXT_DI(0) = '0' and ADPCM_CTRL(0) = '1' then
				if ADPCM_CTRL(1) = '1' then
					ADPCM_WRADDR <= ADPCM_OFFS & "0";
				else
					ADPCM_WRADDR <= std_logic_vector(unsigned(ADPCM_WRADDR) + 1);
				end if;
			end if;
			
			if DRAM_CLKEN = '1' and DRAM_SLOT = SLOT_READ and (ADPCM_READ_PEND = '1' or PLAY_READ_PEND = '1') then
				if ADPCM_CTRL(3) = '1' then
					ADPCM_RDADDR <= ADPCM_OFFS & "0";
				else
					ADPCM_RDADDR <= std_logic_vector(unsigned(ADPCM_RDADDR) + 1);
				end if;
			elsif CPU_CE = '1' and REG_SEL = '1' and EXT_WR_N = '0' and EXT_A(7 downto 0) = x"0D" and EXT_DI(2) = '0' and ADPCM_CTRL(2) = '1' then
				if ADPCM_CTRL(3) = '1' then
					ADPCM_RDADDR <= ADPCM_OFFS & "0";
				else
					ADPCM_RDADDR <= std_logic_vector(unsigned(ADPCM_RDADDR) + 1);
				end if;
			end if;
			end if;
			if SS_SHIFT = '1' then
				SCSI_DBI <= SS_N(7 downto 0);
				SCSI_ACK_N <= SS_N(8);
				SCSI_RST_N <= SS_N(9);
				SCSI_SEL_N <= SS_N(10);
				CD_DTD <= SS_N(11);
				CD_DTR <= SS_N(12);
				CD_SUBCD <= SS_N(13);
				CH_SEL <= SS_N(14);
				BRAM_LOCK <= SS_N(15);
				CD_DTD_EN <= SS_N(16);
				CD_DTR_EN <= SS_N(17);
				CD_SUBCD_EN <= SS_N(18);
				ADPCM_END_EN <= SS_N(19);
				ADPCM_HALF_EN <= SS_N(20);
				AUTO_ACK <= SS_N(21);
				R1802_0 <= SS_N(22);
				R1802_1 <= SS_N(23);
				R180F_0 <= SS_N(24);
				CDDA_SAMPLE_OLD <= SS_N(25);
				SUBCD_CE_OLD <= SS_N(26);
				ADPCM_DMA_EN <= SS_N(27);
				ADPCM_DMA_RUN <= SS_N(28);
				ADPCM_END <= SS_N(29);
				ADPCM_HALF <= SS_N(30);
				ADPCM_PLAY <= SS_N(31);
				ADPCM_WRITE_PEND <= SS_N(32);
				ADPCM_READ_PEND <= SS_N(33);
				PLAY_READ_PEND <= SS_N(34);
				DMA_WRITE_PEND <= SS_N(35);
				ADPCM_WRITE_NIB <= SS_N(36);
				ADPCM_READ_NIB <= SS_N(37);
				SCSI_REQ_N_OLD <= SS_N(38);
				SCSI_BSY_N_OLD <= SS_N(39);
				SCSI_ACK_N_OLD <= SS_N(40);
				R180E_7_4 <= SS_N(44 downto 41);
				R180F_7_4 <= SS_N(48 downto 45);
				CDDA_VOL <= SS_N(64 downto 49);
				ADPCM_OFFS <= SS_N(80 downto 65);
				ADPCM_LEN <= SS_N(97 downto 81);
				ADPCM_RDADDR <= SS_N(114 downto 98);
				ADPCM_WRADDR <= SS_N(131 downto 115);
				ADPCM_CTRL <= SS_N(139 downto 132);
				ADPCM_FREQ <= SS_N(143 downto 140);
				ADPCM_FADER <= SS_N(146 downto 144);
				ADPCM_RDDATA <= SS_N(154 downto 147);
				ADPCM_WRDATA <= SS_N(162 downto 155);
				M5205_D <= SS_N(166 downto 163);
				CD_DATA_CNT <= unsigned(SS_N(177 downto 167));
			end if;
		end if;
	end process;

	WRITE_PEND <= ADPCM_WRITE_PEND or DMA_WRITE_PEND;
	READ_PEND <= ADPCM_READ_PEND or PLAY_READ_PEND;
	process( REG_SEL, EXT_A, SCSI_DBO, SCSI_DBI, SCSI_BSY_N, SCSI_REQ_N, SCSI_MSG_N, SCSI_CD_N, SCSI_IO_N, SCSI_ACK_N, SCSI_RST_N, 
				CD_DTR, CD_DTD, CD_SUBCD, SUBCD_BYTE, CD_DTR_EN, CD_DTD_EN, CD_SUBCD_EN, R1802_0, R1802_1, CH_SEL, ADPCM_RDDATA, ADPCM_DMA_EN, ADPCM_DMA_RUN, ADPCM_END, ADPCM_HALF, ADPCM_END_EN, ADPCM_HALF_EN, 
				ADPCM_CTRL, ADPCM_FREQ, R180E_7_4, ADPCM_PLAY, ADPCM_FADER, R180F_0, R180F_7_4, READ_PEND, WRITE_PEND, CDDA_VOL, CD_REGION) 
	begin
		EXT_DO <= x"00";
		if REG_SEL = '1' then
			case EXT_A(7 downto 0) is
				when x"00" =>
					EXT_DO <= not SCSI_BSY_N & not SCSI_REQ_N & not SCSI_MSG_N & not SCSI_CD_N & not SCSI_IO_N & "000";
				when x"01" =>
					if SCSI_BSY_N = '0' then
						EXT_DO <= SCSI_DBO;
					else
						EXT_DO <= SCSI_DBI;
					end if;
				when x"02" =>
					EXT_DO <= not SCSI_ACK_N & CD_DTR_EN & CD_DTD_EN & CD_SUBCD_EN & ADPCM_END_EN & ADPCM_HALF_EN & R1802_1 & R1802_0;
				when x"03" =>
					EXT_DO <= "0" & CD_DTR & CD_DTD & CD_SUBCD & ADPCM_END & ADPCM_HALF & CH_SEL & "0";--TODO	
				when x"04" =>
					EXT_DO <= "000000" & not SCSI_RST_N & "0";
				when x"05" =>
					EXT_DO <= CDDA_VOL(7 downto 0);
				when x"06" =>
					EXT_DO <= CDDA_VOL(15 downto 8);
				when x"07" =>
					EXT_DO <= SUBCD_BYTE;
				when x"08" =>
					if SCSI_BSY_N = '0' then
						EXT_DO <= SCSI_DBO;
					else
						EXT_DO <= SCSI_DBI;
					end if;
					
				when x"0A" =>
					EXT_DO <= ADPCM_RDDATA;
				when x"0B" =>
					EXT_DO <= "000000" & ADPCM_DMA_EN & ADPCM_DMA_RUN;
				when x"0C" =>
					EXT_DO <= READ_PEND & "000" & ADPCM_PLAY & WRITE_PEND & "0" & ADPCM_END;
				when x"0D" =>
					EXT_DO <= ADPCM_CTRL;
				when x"0E" =>
					EXT_DO <= R180E_7_4 & ADPCM_FREQ;
				when x"0F" =>
					EXT_DO <= R180F_7_4 & ADPCM_FADER & R180F_0;
					
				when x"C1" =>
					EXT_DO <= x"AA";
				when x"C2" =>
					EXT_DO <= x"55";
				when x"C3" =>
					EXT_DO <= x"00";

				when x"C5" =>
					if CD_REGION = '1' then
						EXT_DO <= x"55";
					else
						EXT_DO <= x"AA";
					end if;
				when x"C6" =>
					if CD_REGION = '1' then
						EXT_DO <= x"AA";
					else
						EXT_DO <= x"55";
					end if;
				when x"C7" =>
					if CD_REGION = '1' then
						EXT_DO <= x"C0";
					else
						EXT_DO <= x"03";
					end if;
				when others => null;
			end case;
		end if;
	end process;
	
	SEL_N <= not (REG_SEL and EN);
	IRQ_N <= not ((CD_DTR_EN and CD_DTR) or (CD_DTD_EN and CD_DTD) or (CD_SUBCD_EN and CD_SUBCD) or (ADPCM_END_EN and ADPCM_END) or (ADPCM_HALF_EN and ADPCM_HALF));
	
	RAM_SEL <= '1' when EXT_A(20 downto 13) >= x"68" and EXT_A(20 downto 13) <= x"87" else '0';
	RAM_CS_N <= not (RAM_SEL and EN);
	
	BRAM_EN <= not BRAM_LOCK or not EN;
	CD_RESET <= not SCSI_RST_N;
	
	SCSI : entity work.SCSI
	port map (
		RESET_N		=> SCSI_RESET_N,-- and EN
		CLK			=> CLK,
		
		DBI			=> SCSI_DBI,
		DBO			=> SCSI_DBO,
		SEL_N			=> SCSI_SEL_N,
		ACK_N			=> SCSI_ACK_N,
		RST_N			=> '1', --SCSI_RST_N,
		BSY_N			=> SCSI_BSY_N,
		REQ_N			=> SCSI_REQ_N,
		MSG_N			=> SCSI_MSG_N,
		CD_N			=> SCSI_CD_N,
		IO_N			=> SCSI_IO_N,
		
		STATUS		=> CD_STAT,
		MESSAGE		=> CD_MSG,
		STAT_GET		=> CD_STAT_GET,
		
		COMMAND		=> CD_COMM,
		COMM_SEND	=> CD_COMM_SEND,
		
		DOUT_REQ		=> CD_DOUT_REQ,
		DOUT			=> CD_DOUT,
		DOUT_SEND	=> CD_DOUT_SEND,
		STOP_CD_SND	=> CD_STOP_CD_SND,
		
		CD_DATA		=> CD_DATA,
		CD_WR			=> CD_DATA_WR,
		CD_almost_full => CD_almost_full,
		CD_DATA_END	=> CD_DATA_END,

		SS_HOLD		=> SS_HOLD,
		SS_Q			=> SCSI_SS_Q,
		SS_D			=> SCSI_SS_D,
		SS_WE			=> SS_SHIFT,
		SS_FIFO_RD	=> SS_FRD and bool_bit(SS_FSEL = "00"),
		SS_FIFO_WR	=> SS_FWR and bool_bit(SS_FSEL = "00"),
		SS_FIFO_CLR	=> SS_FCLR and bool_bit(SS_FSEL = "00"),
		SS_FIFO_D	=> SS_FD(7 downto 0),
		SS_FIFO_Q	=> SS_SCSI_FQ,
		SS_FIFO_CNT	=> SS_SCSI_FCNT
	);


	--ADPCM DRAM
	process( RST_N, CLK )
	begin
		if RST_N = '0' then
			DRAM_CLK_CNT <= (others => '0');
			DRAM_CLKEN <= '0';
			DRAM_SLOT_CNT <= (others => '0');
			ADRAM_RD_R <= '0';
		elsif rising_edge(CLK) then
			if EN = '1' and SS_HOLD = '0' then
				DRAM_CLKEN <= '0';
				ADRAM_RD_R <= '0';
				if DRAM_CLK_CNT = 9-1 and DRAM_SLOT = SLOT_READ then
					ADRAM_RD_R <= '1';
				end if;
				DRAM_CLK_CNT <= DRAM_CLK_CNT + 1;
				if DRAM_CLK_CNT = 18-1 then
					DRAM_CLK_CNT <= (others => '0');
					DRAM_CLKEN <= '1';
				end if;
				
				if DRAM_CLKEN = '1' then
					DRAM_SLOT_CNT <= DRAM_SLOT_CNT + 1;
				end if;
			end if;
			if SS_SHIFT = '1' then
				DRAM_CLK_CNT <= unsigned(SS_N(182 downto 178));
				DRAM_CLKEN <= SS_N(183);
				DRAM_SLOT_CNT <= unsigned(SS_N(185 downto 184));
				ADRAM_RD_R <= SS_N(186);
			end if;
		end if;
	end process;
	
	process( DRAM_SLOT_CNT )
	begin
		case DRAM_SLOT_CNT is
			when "00" => DRAM_SLOT <= SLOT_REFRESH;
			when "01" => DRAM_SLOT <= SLOT_WRITE;
			when "10" => DRAM_SLOT <= SLOT_WRITE;
			when others => DRAM_SLOT <= SLOT_READ;
		end case;
	end process;
	
	ADRAM_A <= ADPCM_WRADDR when DRAM_SLOT = SLOT_WRITE else ADPCM_RDADDR;
	ADRAM_DI <= ADPCM_WRDATA(3 downto 0) when ADPCM_WRITE_NIB = '1' else ADPCM_WRDATA(7 downto 4);
	ADRAM_WE <= DRAM_CLKEN when DRAM_SLOT = SLOT_WRITE and (ADPCM_WRITE_PEND = '1' or DMA_WRITE_PEND = '1') else '0';

	
	process( RST_N, CLK )
	begin
		if RST_N = '0' then
			M5205_CLK_CNT <= 0;
			M5205_CLK <= '0';
		elsif rising_edge(CLK) then
			if SS_HOLD = '0' then
			M5205_CLK <= '0';
			if EN = '1' then
				if ADPCM_CE = '1' then
					-- M5205 CLK = 42954545Hz / (ACT(n)+1)
					M5205_CLK_CNT <= M5205_CLK_CNT + 1;
					if M5205_CLK_CNT >= 15 - unsigned(ADPCM_FREQ) then
						M5205_CLK_CNT <= 0;
						M5205_CLK <= '1';
					end if;
				end if;
			end if;
			end if;
			if SS_SHIFT = '1' then
				M5205_CLK_CNT <= to_integer(unsigned(SS_N(195 downto 187)));
				M5205_CLK <= SS_N(196);
			end if;
		end if;
	end process;
	
	MSM5205 : entity work.MSM5205
	port map (
		RST_N		=> M5205_RST_N,
		CLK		=> CLK,
		
		XTI		=> M5205_CLK,
		D			=> M5205_D,
		VCK_R		=> M5205_VCK_R,
		--VCK_F		=> M5205_VCK_F,
		
		SOUT		=> M5205_SOUT,

		SS_HOLD	=> SS_HOLD,
		SS_Q		=> M5205_SS_Q,
		SS_D		=> M5205_SS_D,
		SS_WE		=> SS_SHIFT
	);

	
	--CDDA
	process( RST_N, CLK )
	begin
		if RST_N = '0' then
			CD_BYTE_CNT <= (others => '0');
			FIFO_D <= (others => '0');
			FIFO_WR_REQ <= '0';
			CD_WR_OLD <= '0';
		elsif rising_edge(CLK) then
			if SS_HOLD = '0' then
			FIFO_WR_REQ <= '0';
			if EN = '1' then
				CD_WR_OLD <= CD_AUDIO_WR;
				if DM = '1' then
					CD_BYTE_CNT <= (others => '0');
				elsif CD_AUDIO_WR = '1' and CD_WR_OLD = '0' then
					CD_BYTE_CNT <= CD_BYTE_CNT + 1;
					case CD_BYTE_CNT is
						when "00" => FIFO_D(7 downto 0) <= CD_DATA;
						when "01" => FIFO_D(15 downto 8) <= CD_DATA;
						when "10" => FIFO_D(23 downto 16) <= CD_DATA;
						when others => 
							FIFO_D(31 downto 24) <= CD_DATA;
							if FIFO_FULL = '0' and DM = '0' then
								FIFO_WR_REQ <= '1';
							end if;
					end case;
				end if;
			end if;
			end if;
			if SS_SHIFT = '1' then
				CD_BYTE_CNT <= unsigned(SS_N(198 downto 197));
				FIFO_D <= SS_N(230 downto 199);
				FIFO_WR_REQ <= SS_N(231);
				CD_WR_OLD <= SS_N(232);
			end if;
		end if;
	end process;
	
	FIFO : entity work.CDDA_FIFO 
	port map(
		clock		=> CLK,
		data		=> F_D,
		wrreq		=> F_WR,
		full		=> FIFO_FULL,
		almost_full => AUDIO_almost_full,
		sclr		=> F_CLR,
		rdreq		=> F_RD,
		empty		=> FIFO_EMPTY,
		usedw		=> FIFO_USEDW,
		q			=> FIFO_Q
	);
	
	CDDA_CLK_GEN : entity work.CEGen
	port map(
		CLK   		=> CLK,
		RST_N       => RST_N,		
		IN_CLK   	=> 429545,
		OUT_CLK   	=> 441,
		CE   			=> CDDA_CE,
		SS_HOLD		=> SS_HOLD,
		SS_Q			=> CDDA_CE_SS_Q,
		SS_D			=> CDDA_CE_SS_D,
		SS_WE			=> SS_SHIFT
	);

	ADPCM_CLK_GEN : entity work.CEGen
	port map(
		CLK         => CLK,
		RST_N       => RST_N,
		IN_CLK      => 42954545,
		OUT_CLK     => 1540200,
		CE          => ADPCM_CE,
		SS_HOLD		=> SS_HOLD,
		SS_Q			=> ADPCM_CE_SS_Q,
		SS_D			=> ADPCM_CE_SS_D,
		SS_WE			=> SS_SHIFT
	);
	
	--CD SUBCODE
	process( RST_N, CLK )
	begin
		if RST_N = '0' then
			SUBCD_FIFO_D <= (others => '0');
			SUBCD_FIFO_WR_REQ <= '0';
			SUBCD_WR_OLD <= '0';
		elsif rising_edge(CLK) then
			if SS_HOLD = '0' then
			SUBCD_FIFO_WR_REQ <= '0';
			if EN = '1' then
				SUBCD_WR_OLD <= CD_SUBCD_WR;
				if CD_SUBCD_WR = '1' and SUBCD_WR_OLD = '0' then
					SUBCD_FIFO_D(7 downto 0) <= CD_DATA;
					if SUBCD_FIFO_FULL = '0' and DM = '0' then
						SUBCD_FIFO_WR_REQ <= '1';
					end if;
				end if;
			end if;
			end if;
			if SS_SHIFT = '1' then
				SUBCD_FIFO_D <= SS_N(240 downto 233);
				SUBCD_FIFO_WR_REQ <= SS_N(241);
				SUBCD_WR_OLD <= SS_N(242);
			end if;
		end if;
	end process;
	
	CDSUBC_FIFO : entity work.CDSUBC_FIFO 
	port map(
		clock		=> CLK,
		data		=> SF_D,
		wrreq		=> SF_WR,
		full		=> SUBCD_FIFO_FULL,
		sclr		=> SF_CLR,
		rdreq		=> SF_RD,
		empty		=> SUBCD_FIFO_EMPTY,
		usedw		=> SUBCD_FIFO_USEDW,
		q			=> SUBCD_FIFO_Q
	);
	
	process( RST_N, CLK )
	begin
		if RST_N = '0' then
			FIFO_SCLR <= '1';
			FIFO_RD_REQ <= '0';
			OUTL <= (others => '0');
			OUTR <= (others => '0');
			SUBCD_CE <= '0';
			SUBCD_CNT <= (others => '0');
			SUBCD_BYTE <= (others => '0');
			SUBCD_BYTENUM <= (others => '0');
			SUBCD_FIFO_SCLR <= '1';
			SUBCD_FIFO_RD_REQ <= '0';

		elsif rising_edge(CLK) then
			if SS_HOLD = '0' then
			FIFO_RD_REQ <= '0';
			FIFO_SCLR <= '0';
			SUBCD_FIFO_RD_REQ <= '0';
			SUBCD_FIFO_SCLR <= '0';
			
			if CDDA_CE = '1' and EN = '1' then	-- ~44.1kHz
				CDDA_SAMPLE <= not CDDA_SAMPLE;
				if FIFO_EMPTY = '0' then
					FIFO_RD_REQ <= '1';
					if (CD_STOP_CD_SND = '0') then
						OUTL <= resize(shift_right(signed(FIFO_Q(15 downto 0)) * signed(CDDA_FADE_VOL), 10), OUTL'length);
						OUTR <= resize(shift_right(signed(FIFO_Q(31 downto 16)) * signed(CDDA_FADE_VOL), 10), OUTR'length);
					else
						OUTL <= (others => '0');
						OUTR <= (others => '0');
						FIFO_SCLR <= '1';
						SUBCD_FIFO_SCLR <= '1';
					end if;
				end if;


				if SUBCD_CNT = 0 then
					SUBCD_CE <= '1';									-- set interrupt flag
					
					if SUBCD_FIFO_EMPTY = '0' then
						SUBCD_FIFO_RD_REQ <= '1';
						SUBCD_BYTE <= SUBCD_FIFO_Q(7 downto 0);
					end if;

					-- Note that there are 96 bytes in a subcode sector, PLUS 2 bytes as a 'synchronization word'
					-- The sync word bytes are "0x00, 0x80" when the motor is running, or "0x1F, 0xFD" when it is not running
						--> Currently, Main_MiSTer send these two bytes, and only implements the 'motor on' version (0x00, 0x80)
					-- When paused, the last sector (with correct SUNCODEQ timing information) should be repeated constantly
						--> Not yet implemented

					if (SUBCD_BYTENUM = 97) then
						SUBCD_BYTENUM <= (others => '0');		-- 98 bytes in sector
					else
						SUBCD_BYTENUM <= SUBCD_BYTENUM + 1;
					end if;
				else
					SUBCD_CE <= '0';									-- SUBCODE 1 sample every 6 CDDA sample intervals
				end if;

				if SUBCD_CNT = 5 then
					SUBCD_CNT <= (others => '0');
				else
					SUBCD_CNT <= SUBCD_CNT + 1;
				end if;

			end if;
			end if;
			if SS_SHIFT = '1' then
				FIFO_SCLR <= SS_N(243);
				FIFO_RD_REQ <= SS_N(244);
				SUBCD_CE <= SS_N(245);
				SUBCD_FIFO_SCLR <= SS_N(246);
				SUBCD_FIFO_RD_REQ <= SS_N(247);
				CDDA_SAMPLE <= SS_N(248);
				OUTL <= signed(SS_N(264 downto 249));
				OUTR <= signed(SS_N(280 downto 265));
				SUBCD_CNT <= unsigned(SS_N(284 downto 281));
				SUBCD_BYTE <= SS_N(292 downto 285);
				SUBCD_BYTENUM <= unsigned(SS_N(300 downto 293));
			end if;
		end if;
	end process;

			
	--Fader
	process( RST_N, CLK )
	begin
		if RST_N = '0' then
			FADE_VOL <= "01111111111";
			FADE_CNT <= (others => '0');
		elsif rising_edge(CLK) then
			if CDDA_CE = '1' and EN = '1' and SS_HOLD = '0' then
				if FADE_VOL(9 downto 0) > 0 and ADPCM_FADER(2) = '1' then
					FADE_CNT <= FADE_CNT + 1;
					if (FADE_CNT = 107 and ADPCM_FADER(1) = '1') or 	--2.5s
						(FADE_CNT = 255 and ADPCM_FADER(1) = '0') then	--6s
						FADE_CNT <= (others => '0');
						FADE_VOL <= "0" & (FADE_VOL(9 downto 0) - 1);
					end if;
				elsif ADPCM_FADER(2) = '0' then
					FADE_VOL <= "01111111111";
				end if;
			end if;
			if SS_SHIFT = '1' then
				FADE_VOL <= unsigned(SS_N(311 downto 301));
				FADE_CNT <= unsigned(SS_N(319 downto 312));
			end if;
		end if;
	end process;
	
	CDDA_FADE_VOL <= FADE_VOL when ADPCM_FADER(0) = '0' else "01111111111";
	ADPCM_FADE_VOL <= FADE_VOL when ADPCM_FADER(0) = '1' else "01111111111";
	
	CD_SL <= OUTL;
	CD_SR <= OUTR;

	AD_S <= x"0000" when ADPCM_PLAY = '0' else resize(shift_right(M5205_SOUT * signed(ADPCM_FADE_VOL), 10), AD_S'length);

end rtl;
