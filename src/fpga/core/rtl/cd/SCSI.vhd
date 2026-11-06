library STD;
use STD.TEXTIO.ALL;
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_TEXTIO.all;
use IEEE.NUMERIC_STD.ALL;

entity SCSI is
	port(
		RESET_N		: in std_logic;
		CLK 			: in std_logic;
		
		DBI			: in std_logic_vector(7 downto 0);
		DBO			: out std_logic_vector(7 downto 0);
		SEL_N			: in std_logic;
		ACK_N			: in std_logic;
		RST_N			: in std_logic;
		BSY_N			: out std_logic;
		REQ_N			: out std_logic;
		MSG_N			: out std_logic;
		CD_N			: out std_logic;
		IO_N			: out std_logic;
		
		STATUS		: in std_logic_vector(7 downto 0);
		MESSAGE		: in std_logic_vector(7 downto 0);
		STAT_GET		: in std_logic;
		
		COMMAND		: out std_logic_vector(95 downto 0);
		COMM_SEND	: out std_logic;
		
		DOUT_REQ		: in std_logic;
		DOUT			: out std_logic_vector(79 downto 0);
		DOUT_SEND	: out std_logic;
		
		CD_DATA		: in std_logic_vector(7 downto 0);
		CD_WR			: in std_logic;
		CD_almost_full	: out std_logic;
		CD_DATA_END	: out std_logic;
		STOP_CD_SND	: out std_logic;
		
		DBG_DATAIN_CNT: out unsigned(15 downto 0);

		-- A save state (docs/SAVESTATES.md): SS_HOLD stops it; its 251 bits out at SS_Q, and in
		-- from SS_D at SS_WE. While held, the FIFO is the engine's: SS_FIFO_RD takes its head
		-- (SS_FIFO_Q, before), SS_FIFO_WR puts SS_FIFO_D at its tail, SS_FIFO_CLR empties it;
		-- SS_FIFO_CNT is how many it holds.
		SS_HOLD		: in std_logic := '0';
		SS_Q			: out std_logic_vector(250 downto 0);
		SS_D			: in std_logic_vector(250 downto 0) := (others => '0');
		SS_WE			: in std_logic := '0';
		SS_FIFO_RD	: in std_logic := '0';
		SS_FIFO_WR	: in std_logic := '0';
		SS_FIFO_CLR	: in std_logic := '0';
		SS_FIFO_D	: in std_logic_vector(7 downto 0) := (others => '0');
		SS_FIFO_Q	: out std_logic_vector(7 downto 0);
		SS_FIFO_CNT	: out std_logic_vector(12 downto 0)
	);
end SCSI;

architecture rtl of SCSI is
	
	type SCSIPhase_t is (
		SP_FREE,
		SP_COMM_BEFOREREQ,
		SP_COMM_START,
		SP_COMM_END,
		SP_STAT_START,
		SP_STAT_END,
		SP_STAT_HOLD,
		SP_MSGIN_START,
		SP_MSGIN_END,
		SP_MSGIN_HOLD,
		SP_DATAIN_START,
		SP_DATAIN_END,
		SP_DATAOUT_START,
		SP_DATAOUT_END
	);
	signal SP 			: SCSIPhase_t; 
	
	signal BSY_Nr 		: std_logic;
	signal MSG_Nr 		: std_logic;
	signal CD_Nr 		: std_logic;
	signal IO_Nr 		: std_logic;
	signal REQ_Nr 		: std_logic;
--	signal TR_DONE		: std_logic;
--	signal TR_RDY		: std_logic;
	
	type CommBuf_t is array (0 to 11) of std_logic_vector(7 downto 0);
	signal COMM 		: CommBuf_t;
	signal COMM_POS 	: unsigned(3 downto 0);
	signal COMM_OUT 	: std_logic;
	type CommLen_t is array (0 to 15) of unsigned(3 downto 0);
	constant COMM_LEN : CommLen_t :=
	("0110", "0110", "1010", "1010", "1010", "1010", "1010", "1010", "1010", "1010", "1100", "1100", "1010", "1010", "1010", "1010"); 

	type DataBuf_t is array (0 to 9) of std_logic_vector(7 downto 0);
	signal DATA_BUF 	: DataBuf_t;
	signal DATA_POS	: unsigned(3 downto 0);
	signal DATA_OUT	: std_logic;
	
	signal FULL 		: std_logic;
	signal EMPTY		: std_logic;
	signal FIFO_RD_REQ: std_logic;
	signal FIFO_WR_REQ: std_logic;
	signal FIFO_D 		: std_logic_vector(7 downto 0);
	signal FIFO_Q 		: std_logic_vector(7 downto 0);
	signal CD_WR_OLD 	: std_logic;
	signal STAT_PEND 	: std_logic;
	signal DOUT_PEND  : std_logic;
	
	signal DATAIN_CNT 	: unsigned(15 downto 0);

	signal STAT_COUNT    : unsigned(15 downto 0);
	signal DELAY_COUNT   : unsigned(16 downto 0);

	-- the save state's
	signal F_D			: std_logic_vector(7 downto 0);
	signal F_WR, F_RD, F_CLR : std_logic;
	signal F_USEDW		: std_logic_vector(11 downto 0);
	function sp_bits(s : SCSIPhase_t) return std_logic_vector is
	begin
		case s is
			when SP_FREE => return "0000";
			when SP_COMM_BEFOREREQ => return "0001";
			when SP_COMM_START => return "0010";
			when SP_COMM_END => return "0011";
			when SP_STAT_START => return "0100";
			when SP_STAT_END => return "0101";
			when SP_STAT_HOLD => return "0110";
			when SP_MSGIN_START => return "0111";
			when SP_MSGIN_END => return "1000";
			when SP_MSGIN_HOLD => return "1001";
			when SP_DATAIN_START => return "1010";
			when SP_DATAIN_END => return "1011";
			when SP_DATAOUT_START => return "1100";
			when others => return "1101";
		end case;
	end function;
	function sp_state(b : std_logic_vector(3 downto 0)) return SCSIPhase_t is
	begin
		case b is
			when "0000" => return SP_FREE;
			when "0001" => return SP_COMM_BEFOREREQ;
			when "0010" => return SP_COMM_START;
			when "0011" => return SP_COMM_END;
			when "0100" => return SP_STAT_START;
			when "0101" => return SP_STAT_END;
			when "0110" => return SP_STAT_HOLD;
			when "0111" => return SP_MSGIN_START;
			when "1000" => return SP_MSGIN_END;
			when "1001" => return SP_MSGIN_HOLD;
			when "1010" => return SP_DATAIN_START;
			when "1011" => return SP_DATAIN_END;
			when "1100" => return SP_DATAOUT_START;
			when others => return SP_DATAOUT_END;
		end case;
	end function;

	-- (the save state's chain reads it, and VHDL-93 can't read an out port)
	signal DBO_R : std_logic_vector(7 downto 0);

begin

	DBO <= DBO_R;

	SS_Q(7 downto 0) <= FIFO_D;
	SS_Q(8) <= FIFO_WR_REQ;
	SS_Q(9) <= CD_WR_OLD;
	SS_Q(17 downto 10) <= DBO_R;
	SS_Q(18) <= BSY_Nr;
	SS_Q(19) <= MSG_Nr;
	SS_Q(20) <= CD_Nr;
	SS_Q(21) <= IO_Nr;
	SS_Q(22) <= REQ_Nr;
	SS_Q(30 downto 23) <= COMM(0);
	SS_Q(38 downto 31) <= COMM(1);
	SS_Q(46 downto 39) <= COMM(2);
	SS_Q(54 downto 47) <= COMM(3);
	SS_Q(62 downto 55) <= COMM(4);
	SS_Q(70 downto 63) <= COMM(5);
	SS_Q(78 downto 71) <= COMM(6);
	SS_Q(86 downto 79) <= COMM(7);
	SS_Q(94 downto 87) <= COMM(8);
	SS_Q(102 downto 95) <= COMM(9);
	SS_Q(110 downto 103) <= COMM(10);
	SS_Q(118 downto 111) <= COMM(11);
	SS_Q(122 downto 119) <= std_logic_vector(COMM_POS);
	SS_Q(130 downto 123) <= DATA_BUF(0);
	SS_Q(138 downto 131) <= DATA_BUF(1);
	SS_Q(146 downto 139) <= DATA_BUF(2);
	SS_Q(154 downto 147) <= DATA_BUF(3);
	SS_Q(162 downto 155) <= DATA_BUF(4);
	SS_Q(170 downto 163) <= DATA_BUF(5);
	SS_Q(178 downto 171) <= DATA_BUF(6);
	SS_Q(186 downto 179) <= DATA_BUF(7);
	SS_Q(194 downto 187) <= DATA_BUF(8);
	SS_Q(202 downto 195) <= DATA_BUF(9);
	SS_Q(206 downto 203) <= std_logic_vector(DATA_POS);
	SS_Q(210 downto 207) <= sp_bits(SP);
	SS_Q(211) <= STOP_CD_SND;
	SS_Q(212) <= COMM_OUT;
	SS_Q(213) <= DATA_OUT;
	SS_Q(214) <= CD_DATA_END;
	SS_Q(215) <= STAT_PEND;
	SS_Q(216) <= DOUT_PEND;
	SS_Q(217) <= FIFO_RD_REQ;
	SS_Q(233 downto 218) <= std_logic_vector(STAT_COUNT);
	SS_Q(250 downto 234) <= std_logic_vector(DELAY_COUNT);

	process( RESET_N, CLK )
	begin
		if RESET_N = '0' then
			FIFO_D <= (others => '0');
			FIFO_WR_REQ <= '0';
			--CD_WR_OLD <= '0';
		elsif rising_edge(CLK) then
			if SS_HOLD = '0' then
			FIFO_WR_REQ <= '0';
--			if EN = '1' then
				CD_WR_OLD <= CD_WR;
				if CD_WR = '1' and CD_WR_OLD = '0' then
					FIFO_D <= CD_DATA;
					if FULL = '0' then
						FIFO_WR_REQ <= '1';
					end if;
				end if;
--			end if;
			end if;
			if SS_WE = '1' then
				FIFO_D <= SS_D(7 downto 0);
				FIFO_WR_REQ <= SS_D(8);
				CD_WR_OLD <= SS_D(9);
			end if;
		end if;
	end process;

	-- held, the FIFO is the engine's; its aclr stays the chip's reset
	F_D   <= SS_FIFO_D when SS_HOLD = '1' else FIFO_D;
	F_WR  <= SS_FIFO_WR when SS_HOLD = '1' else FIFO_WR_REQ;
	F_RD  <= SS_FIFO_RD when SS_HOLD = '1' else FIFO_RD_REQ;
	F_CLR <= not RESET_N or SS_FIFO_CLR;
	SS_FIFO_Q <= FIFO_Q;
	SS_FIFO_CNT <= FULL & F_USEDW;

	
	FIFO : entity work.SCSI_FIFO 
	port map(
		aclr     	=> F_CLR,

		clock			=> CLK,
		data			=> F_D,
		wrreq			=> F_WR,
		full			=> FULL,
		
		almost_full	=> CD_almost_full,
		rdreq			=> F_RD,
		empty			=> EMPTY,
		q				=> FIFO_Q,
		usedw			=> F_USEDW
	);

	process( CLK, RESET_N ) begin
		if RESET_N = '0' then
			DBO_R <= (others => '0');
			BSY_Nr <= '1';
			MSG_Nr <= '1';
			CD_Nr <= '1';
			IO_Nr <= '1';
			REQ_Nr <= '1';
			COMM <= (others => (others => '0'));
			COMM_POS <= (others => '0');
			DATA_BUF <= (others => (others => '0'));
			DATA_POS <= (others => '0');
			SP <= SP_FREE;
			STOP_CD_SND <= '0';
			
			COMM_OUT <= '0';
			DATA_OUT <= '0';
			CD_DATA_END <= '0';
			STAT_PEND <= '0';
			DOUT_PEND <= '0';
			FIFO_RD_REQ <= '0';
			
			STAT_COUNT  <= (others => '0');
			DELAY_COUNT <= (others => '0');
			
			DATAIN_CNT  <= (others => '0');

		elsif rising_edge( CLK ) then
			if SS_HOLD = '0' then
			if STAT_GET = '1' then
				STAT_PEND <= '1';
			end if;
			
			if DOUT_REQ = '1' then
				DOUT_PEND <= '1';
			end if;
			

			COMM_OUT <= '0';
			DATA_OUT <= '0';
			CD_DATA_END <= '0';
			FIFO_RD_REQ <= '0';
			
			if RST_N = '0' then
				BSY_Nr <= '1';
				MSG_Nr <= '1';
				CD_Nr <= '1';
				IO_Nr <= '1';
				REQ_Nr <= '1';
			else
				case SP is
					when SP_FREE =>
						if SEL_N = '0' then
							BSY_Nr <= '0';
							MSG_Nr <= '1';
							CD_Nr <= '0';
							IO_Nr <= '1';
							SP <= SP_COMM_BEFOREREQ;
							DELAY_COUNT <= to_unsigned(1700, DELAY_COUNT'LENGTH);		-- Wait 40 microseconds after control signals are set up, before triggering REQ in COMMAND phase
							DATAIN_CNT <= (others => '0');
						elsif STAT_PEND = '1' then
							STAT_COUNT <= STAT_COUNT + 1;

							if (STAT_COUNT = 45000) then		-- CLK is 42.95 MHz; this gives ~1.05 millisec delay before transitioning to STATUS phase
																		-- this is empirical and may not be correct but it solves
																		-- the Sailor Moon hang issue
								STAT_COUNT <= (others => '0');
								STAT_PEND <= '0';
								DBO_R <= STATUS;
								BSY_Nr <= '0';
								MSG_Nr <= '1';
								CD_Nr <= '0';
								IO_Nr <= '0';
								REQ_Nr <= '0';
								SP <= SP_STAT_START;
							end if;
						elsif EMPTY = '0' then
							DBO_R <= FIFO_Q;
							BSY_Nr <= '0';
							MSG_Nr <= '1';
							CD_Nr <= '1';
							IO_Nr <= '0';
							REQ_Nr <= '0';
							FIFO_RD_REQ <= '1';
							SP <= SP_DATAIN_START;
						elsif DOUT_PEND = '1' then
							DOUT_PEND <= '0';
							BSY_Nr <= '0';
							MSG_Nr <= '1';
							CD_Nr <= '1';
							IO_Nr <= '1';
							REQ_Nr <= '0';
							SP <= SP_DATAOUT_START;
						end if;
						
					when SP_COMM_BEFOREREQ =>
						if (DELAY_COUNT = 0) then
							REQ_Nr <= '0';
							SP <= SP_COMM_START;
						else
							DELAY_COUNT <= DELAY_COUNT - 1;
						end if;

					when SP_COMM_START =>
						if REQ_Nr = '0' and ACK_N = '0' then
							REQ_Nr <= '1';
							COMM(to_integer(COMM_POS)) <= DBI;
							COMM_POS <= COMM_POS + 1;
							SP <= SP_COMM_END;
						end if;
					
					when SP_COMM_END =>
						if REQ_Nr = '1' and ACK_N = '1' then
							if COMM_POS = COMM_LEN(to_integer(unsigned(COMM(0)(7 downto 4)))) then
								COMM_POS <= (others => '0');
								COMM_OUT <= '1';
								CD_Nr <= '1';
								SP <= SP_FREE;
								if ((COMM(0) = x"08") or (COMM(0) = x"DA")) then	-- READ6 and PAUSE commands should mute sound, but still drain FIFO
									STOP_CD_SND <= '1';
								end if;
								if ((COMM(0) = x"D8") or (COMM(0) = x"D9")) then	-- SAPSP and SAPEP commands should unmute sound (FIFO should be empty by now)
									STOP_CD_SND <= '0';
								end if;
							else
								SP <= SP_COMM_BEFOREREQ;
								DELAY_COUNT <= to_unsigned(5370, DELAY_COUNT'LENGTH);	-- Wait 125 microseconds after ACK, before next REQ in COMMAND phase
							end if;
						end if;

					when SP_STAT_START =>
						if REQ_Nr = '0' and ACK_N = '0' then
							REQ_Nr <= '1';
							SP <= SP_STAT_END;
						end if;
					
					when SP_STAT_END =>
						if REQ_Nr = '1' and ACK_N = '1' then
							SP <= SP_STAT_HOLD;
							DELAY_COUNT <= to_unsigned(49400, DELAY_COUNT'LENGTH);	-- wait 1.15 milliseconds after ACK in STATUS pahse before transitioning to next phase (MSGIN)
						end if;

					when SP_STAT_HOLD =>
						if (DELAY_COUNT = 0) then
							DBO_R <= MESSAGE;
							BSY_Nr <= '0';
							MSG_Nr <= '0';
							CD_Nr <= '0';
							IO_Nr <= '0';
							REQ_Nr <= '0';
							SP <= SP_MSGIN_START;
						else
							DELAY_COUNT <= DELAY_COUNT - 1;
						end if;
					
					when SP_MSGIN_START =>
						if REQ_Nr = '0' and ACK_N = '0' then
							REQ_Nr <= '1';
							SP <= SP_MSGIN_END;
						end if;
					
					when SP_MSGIN_END =>
						if REQ_Nr = '1' and ACK_N = '1' then
							SP <= SP_MSGIN_HOLD;
							DELAY_COUNT <= to_unsigned(6600, DELAY_COUNT'LENGTH);		-- wait 154 microseconds after ACK in STATUS phase before transitioning to next phase/disconnecting
						end if;

					when SP_MSGIN_HOLD =>
						if (DELAY_COUNT = 0) then
							BSY_Nr <= '1';
							MSG_Nr <= '1';
							CD_Nr <= '1';
							IO_Nr <= '1';
							REQ_Nr <= '1';
							SP <= SP_FREE;
						else
							DELAY_COUNT <= DELAY_COUNT - 1;
						end if;

					when SP_DATAIN_START =>
						if REQ_Nr = '0' and ACK_N = '0' then
							REQ_Nr <= '1';
							SP <= SP_DATAIN_END;
							STOP_CD_SND <= '0';		-- unmute
						end if;
					
					when SP_DATAIN_END =>
						if REQ_Nr = '1' and ACK_N = '1' then
							if EMPTY = '0' then
								DBO_R <= FIFO_Q;
								REQ_Nr <= '0';
								FIFO_RD_REQ <= '1';
								SP <= SP_DATAIN_START;
							else
								CD_DATA_END <= '1';
								SP <= SP_FREE;
							end if;
							DATAIN_CNT <= DATAIN_CNT + 1;
						end if;
						
					when SP_DATAOUT_START =>
						if REQ_Nr = '0' and ACK_N = '0' then
							REQ_Nr <= '1';
							DATA_BUF(to_integer(DATA_POS)) <= DBI;
							DATA_POS <= DATA_POS + 1;
							SP <= SP_DATAOUT_END;
						end if;
					
					when SP_DATAOUT_END =>
						if REQ_Nr = '1' and ACK_N = '1' then
							if DATA_POS = 10 then
								DATA_POS <= (others => '0');
								DATA_OUT <= '1';
								SP <= SP_FREE;
							else
								REQ_Nr <= '0';
								SP <= SP_DATAOUT_START;
							end if;
						end if;
						
					when others => null;
				end case;
			end if;
			end if;
			if SS_WE = '1' then
				DBO_R <= SS_D(17 downto 10);
				BSY_Nr <= SS_D(18);
				MSG_Nr <= SS_D(19);
				CD_Nr <= SS_D(20);
				IO_Nr <= SS_D(21);
				REQ_Nr <= SS_D(22);
				COMM(0) <= SS_D(30 downto 23);
				COMM(1) <= SS_D(38 downto 31);
				COMM(2) <= SS_D(46 downto 39);
				COMM(3) <= SS_D(54 downto 47);
				COMM(4) <= SS_D(62 downto 55);
				COMM(5) <= SS_D(70 downto 63);
				COMM(6) <= SS_D(78 downto 71);
				COMM(7) <= SS_D(86 downto 79);
				COMM(8) <= SS_D(94 downto 87);
				COMM(9) <= SS_D(102 downto 95);
				COMM(10) <= SS_D(110 downto 103);
				COMM(11) <= SS_D(118 downto 111);
				COMM_POS <= unsigned(SS_D(122 downto 119));
				DATA_BUF(0) <= SS_D(130 downto 123);
				DATA_BUF(1) <= SS_D(138 downto 131);
				DATA_BUF(2) <= SS_D(146 downto 139);
				DATA_BUF(3) <= SS_D(154 downto 147);
				DATA_BUF(4) <= SS_D(162 downto 155);
				DATA_BUF(5) <= SS_D(170 downto 163);
				DATA_BUF(6) <= SS_D(178 downto 171);
				DATA_BUF(7) <= SS_D(186 downto 179);
				DATA_BUF(8) <= SS_D(194 downto 187);
				DATA_BUF(9) <= SS_D(202 downto 195);
				DATA_POS <= unsigned(SS_D(206 downto 203));
				SP <= sp_state(SS_D(210 downto 207));
				STOP_CD_SND <= SS_D(211);
				COMM_OUT <= SS_D(212);
				DATA_OUT <= SS_D(213);
				CD_DATA_END <= SS_D(214);
				STAT_PEND <= SS_D(215);
				DOUT_PEND <= SS_D(216);
				FIFO_RD_REQ <= SS_D(217);
				STAT_COUNT <= unsigned(SS_D(233 downto 218));
				DELAY_COUNT <= unsigned(SS_D(250 downto 234));
			end if;
		end if;
	end process;
	
	BSY_N <= BSY_Nr;
	MSG_N <= MSG_Nr;
	CD_N <= CD_Nr;
	IO_N <= IO_Nr;
	REQ_N <= REQ_Nr;
	
	COMMAND <= COMM(11) & COMM(10) & COMM(9) & COMM(8) & COMM(7) & COMM(6) & COMM(5) & COMM(4) & COMM(3) & COMM(2) & COMM(1) & COMM(0);
	COMM_SEND <= COMM_OUT;
	
	DOUT <= DATA_BUF(9) & DATA_BUF(8) & DATA_BUF(7) & DATA_BUF(6) & DATA_BUF(5) & DATA_BUF(4) & DATA_BUF(3) & DATA_BUF(2) & DATA_BUF(1) & DATA_BUF(0);
	DOUT_SEND <= DATA_OUT;
	
	DBG_DATAIN_CNT <= DATAIN_CNT;

end rtl;
