library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;

entity psg is
	port (
		CLK 	: in std_logic;
		CLKEN	: in std_logic;
		RESET_N	: in std_logic;

		-- CPU Interface
		DI		: in std_logic_vector(7 downto 0);
		A 		: in std_logic_vector(3 downto 0);
		WE		: in std_logic;

		-- DAC Interface
		DAC_LATCH	: in std_logic;
		LDATA		: out std_logic_vector(23 downto 0);
		RDATA		: out std_logic_vector(23 downto 0);

		-- A save state (state_engine.sv): SS_HOLD stops every register; the registers go out
		-- as a chain of 608 bits, 16 a clock while SS_SHIFT; while held, the waves are read and
		-- written at SS_WF_A (channel, entry).
		SS_HOLD	: in std_logic := '0';
		SS_SHIFT	: in std_logic := '0';
		SS_SI		: in std_logic_vector(15 downto 0) := (others => '0');
		SS_SO		: out std_logic_vector(15 downto 0);
		SS_WF_A	: in std_logic_vector(7 downto 0) := (others => '0');
		SS_WF_WE	: in std_logic := '0';
		SS_WF_D	: in std_logic_vector(4 downto 0) := (others => '0');
		SS_WF_Q	: out std_logic_vector(4 downto 0)
	);
end psg;

architecture rtl of psg is

-- R0 - Channel Selection
signal CHSEL	: integer range 0 to 7;
-- R1 - Main Volume Adjustement
signal LMAL		: std_logic_vector(3 downto 0);
signal RMAL		: std_logic_vector(3 downto 0);

-- R2-R7 - Channel specific registers
type wavedata_t is array(0 to 31) of std_logic_vector(4 downto 0);
type chan_t is
	record
		-- Registers
		FREQ		: std_logic_vector(11 downto 0);
		DDA		: std_logic;
		CHON		: std_logic;
		AL			: std_logic_vector(4 downto 0);
		LAL		: std_logic_vector(3 downto 0);
		RAL		: std_logic_vector(3 downto 0);

		NG_FREQ	: std_logic_vector(4 downto 0);
		NE			: std_logic;

		-- Waveform generator
		WF_ADDR	: std_logic_vector(4 downto 0);
		WF_CNT	: std_logic_vector(12 downto 0);

		WF_RES	: std_logic;
		WF_INC	: std_logic;

		-- Noise generator
		LFSR		: std_logic_vector(17 downto 0);
		NG_CNT	: std_logic_vector(11 downto 0);

		-- Outputs
		DA_OUT	: std_logic_vector(4 downto 0);
		WF_OUT	: std_logic_vector(4 downto 0);
		NG_OUT	: std_logic_vector(4 downto 0);
		-- Global output
		GL_OUT	: std_logic_vector(4 downto 0);

		-- LFO
		LFO_FREQ	: std_logic_vector(7 downto 0);
		LFCTL		: std_logic_vector(1 downto 0);
		LFTRG		: std_logic;
		LFO_CNT	: std_logic_vector(7 downto 0);
		LFO_ADD 	: std_logic_vector(11 downto 0);
	end record;
type chanarray_t is array(0 to 5) of chan_t;
signal CH		: chanarray_t;

-- MiSTer keeps the wave tables in flip-flops, 960 of them. Here each channel's is a RAM read
-- without a clock, with the same timing. Neither way does a reset clear them.
type wavequeue_t is array(0 to 5) of std_logic_vector(4 downto 0);
signal WF_Q		: wavequeue_t;
signal WF_WE	: std_logic_vector(5 downto 0);
signal WF_A		: wavequeue_t;
signal WF_D		: wavequeue_t;
function bool_bit(b : boolean) return std_logic is
begin
	if b then return '1'; else return '0'; end if;
end function;

-- Channels mixing
signal LACC		: std_logic_vector(23 downto 0);
signal RACC		: std_logic_vector(23 downto 0);

signal VT_ADDR	: std_logic_vector(11 downto 0);
signal VT_DATA	: std_logic_vector(23 downto 0);

type mix_t is ( MIX_WAIT, MIX_NEXT, MIX_LREAD, MIX_LNEXT, MIX_RREAD, MIX_RNEXT, MIX_END );
signal MIX		: mix_t;
signal MIX_CNT	: std_logic_vector(2 downto 0);

signal LDATA_FF	: std_logic_vector(23 downto 0);
signal RDATA_FF	: std_logic_vector(23 downto 0);

-- the save state's chain: the registers that are written, channel by channel (the LFO is
-- channel 1's, its effect channel 0's; the noise is channels 4 and 5's), then the mixer's
signal SS_V, SS_N	: std_logic_vector(607 downto 0);
signal SS_PAD		: std_logic_vector(9 downto 0);
function mix_bits(m : mix_t) return std_logic_vector is
begin
	case m is
	when MIX_WAIT  => return "000";
	when MIX_NEXT  => return "001";
	when MIX_LREAD => return "010";
	when MIX_LNEXT => return "011";
	when MIX_RREAD => return "100";
	when MIX_RNEXT => return "101";
	when others    => return "110";
	end case;
end function;
function mix_state(b : std_logic_vector(2 downto 0)) return mix_t is
begin
	case b is
	when "000"  => return MIX_WAIT;
	when "001"  => return MIX_NEXT;
	when "010"  => return MIX_LREAD;
	when "011"  => return MIX_LNEXT;
	when "100"  => return MIX_RREAD;
	when "101"  => return MIX_RNEXT;
	when others => return MIX_END;
	end case;
end function;

begin

SS_V(2 downto 0) <= std_logic_vector(to_unsigned(CHSEL, 3));
SS_V(6 downto 3) <= LMAL;
SS_V(10 downto 7) <= RMAL;
SS_V(22 downto 11) <= CH(0).FREQ;
SS_V(23) <= CH(0).DDA;
SS_V(24) <= CH(0).CHON;
SS_V(29 downto 25) <= CH(0).AL;
SS_V(33 downto 30) <= CH(0).LAL;
SS_V(37 downto 34) <= CH(0).RAL;
SS_V(42 downto 38) <= CH(0).DA_OUT;
SS_V(47 downto 43) <= CH(0).WF_ADDR;
SS_V(60 downto 48) <= CH(0).WF_CNT;
SS_V(65 downto 61) <= CH(0).WF_OUT;
SS_V(70 downto 66) <= CH(0).GL_OUT;
SS_V(82 downto 71) <= CH(1).FREQ;
SS_V(83) <= CH(1).DDA;
SS_V(84) <= CH(1).CHON;
SS_V(89 downto 85) <= CH(1).AL;
SS_V(93 downto 90) <= CH(1).LAL;
SS_V(97 downto 94) <= CH(1).RAL;
SS_V(102 downto 98) <= CH(1).DA_OUT;
SS_V(107 downto 103) <= CH(1).WF_ADDR;
SS_V(120 downto 108) <= CH(1).WF_CNT;
SS_V(125 downto 121) <= CH(1).WF_OUT;
SS_V(130 downto 126) <= CH(1).GL_OUT;
SS_V(142 downto 131) <= CH(2).FREQ;
SS_V(143) <= CH(2).DDA;
SS_V(144) <= CH(2).CHON;
SS_V(149 downto 145) <= CH(2).AL;
SS_V(153 downto 150) <= CH(2).LAL;
SS_V(157 downto 154) <= CH(2).RAL;
SS_V(162 downto 158) <= CH(2).DA_OUT;
SS_V(167 downto 163) <= CH(2).WF_ADDR;
SS_V(180 downto 168) <= CH(2).WF_CNT;
SS_V(185 downto 181) <= CH(2).WF_OUT;
SS_V(190 downto 186) <= CH(2).GL_OUT;
SS_V(202 downto 191) <= CH(3).FREQ;
SS_V(203) <= CH(3).DDA;
SS_V(204) <= CH(3).CHON;
SS_V(209 downto 205) <= CH(3).AL;
SS_V(213 downto 210) <= CH(3).LAL;
SS_V(217 downto 214) <= CH(3).RAL;
SS_V(222 downto 218) <= CH(3).DA_OUT;
SS_V(227 downto 223) <= CH(3).WF_ADDR;
SS_V(240 downto 228) <= CH(3).WF_CNT;
SS_V(245 downto 241) <= CH(3).WF_OUT;
SS_V(250 downto 246) <= CH(3).GL_OUT;
SS_V(262 downto 251) <= CH(4).FREQ;
SS_V(263) <= CH(4).DDA;
SS_V(264) <= CH(4).CHON;
SS_V(269 downto 265) <= CH(4).AL;
SS_V(273 downto 270) <= CH(4).LAL;
SS_V(277 downto 274) <= CH(4).RAL;
SS_V(282 downto 278) <= CH(4).DA_OUT;
SS_V(287 downto 283) <= CH(4).WF_ADDR;
SS_V(300 downto 288) <= CH(4).WF_CNT;
SS_V(305 downto 301) <= CH(4).WF_OUT;
SS_V(310 downto 306) <= CH(4).GL_OUT;
SS_V(322 downto 311) <= CH(5).FREQ;
SS_V(323) <= CH(5).DDA;
SS_V(324) <= CH(5).CHON;
SS_V(329 downto 325) <= CH(5).AL;
SS_V(333 downto 330) <= CH(5).LAL;
SS_V(337 downto 334) <= CH(5).RAL;
SS_V(342 downto 338) <= CH(5).DA_OUT;
SS_V(347 downto 343) <= CH(5).WF_ADDR;
SS_V(360 downto 348) <= CH(5).WF_CNT;
SS_V(365 downto 361) <= CH(5).WF_OUT;
SS_V(370 downto 366) <= CH(5).GL_OUT;
SS_V(375 downto 371) <= CH(4).NG_FREQ;
SS_V(376) <= CH(4).NE;
SS_V(394 downto 377) <= CH(4).LFSR;
SS_V(406 downto 395) <= CH(4).NG_CNT;
SS_V(411 downto 407) <= CH(4).NG_OUT;
SS_V(416 downto 412) <= CH(5).NG_FREQ;
SS_V(417) <= CH(5).NE;
SS_V(435 downto 418) <= CH(5).LFSR;
SS_V(447 downto 436) <= CH(5).NG_CNT;
SS_V(452 downto 448) <= CH(5).NG_OUT;
SS_V(460 downto 453) <= CH(1).LFO_FREQ;
SS_V(462 downto 461) <= CH(1).LFCTL;
SS_V(463) <= CH(1).LFTRG;
SS_V(471 downto 464) <= CH(1).LFO_CNT;
SS_V(483 downto 472) <= CH(0).LFO_ADD;
SS_V(507 downto 484) <= LACC;
SS_V(531 downto 508) <= RACC;
SS_V(543 downto 532) <= VT_ADDR;
SS_V(546 downto 544) <= MIX_CNT;
SS_V(570 downto 547) <= LDATA_FF;
SS_V(594 downto 571) <= RDATA_FF;
SS_V(597 downto 595) <= mix_bits(MIX);
SS_V(607 downto 598) <= SS_PAD;
SS_N <= SS_V(591 downto 0) & SS_SI;
SS_SO <= SS_V(607 downto 592);

process( CLK )
begin
	if rising_edge( CLK ) then
		if SS_SHIFT = '1' then
			SS_PAD <= SS_N(607 downto 598);
		end if;
	end if;
end process;

-- CPU Interface
process( CLK )
begin
	if rising_edge( CLK ) then
	if SS_HOLD = '0' then

		for i in 0 to 5 loop
			CH(i).WF_RES <= '0';
			CH(i).WF_INC <= '0';
		end loop;

		if RESET_N = '0' then

			CHSEL <= 0;
			LMAL <= (others => '0');
			RMAL <= (others => '0');

			for i in 0 to 5 loop
				CH(i).FREQ <= (others => '0');
				CH(i).DDA <= '0';
				CH(i).CHON <= '0';
				CH(i).LAL <= (others => '0');
				CH(i).RAL <= (others => '0');
				CH(i).NG_FREQ <= (others => '0');
				CH(i).NE <= '0';
				CH(i).DA_OUT <= (others => '0');
				CH(i).LFO_FREQ <= (others => '0');
				CH(i).LFCTL <= "00";
				CH(i).LFTRG <= '0';
			end loop;
		else
			if WE = '1' then
				case A is
				when "0000" =>
					CHSEL <= conv_integer(DI(2 downto 0));

				when "0001" =>
					LMAL <= DI(7 downto 4);
					RMAL <= DI(3 downto 0);

				when "0010" =>
					CH(CHSEL).FREQ(7 downto 0) <= DI;

				when "0011" =>
					CH(CHSEL).FREQ(11 downto 8) <= DI(3 downto 0);

				when "0100" =>
					CH(CHSEL).CHON <= DI(7);
					CH(CHSEL).DDA <= DI(6);
					CH(CHSEL).AL <= DI(4 downto 0);
					if CH(CHSEL).DDA = '1' and DI(6) = '0' then
						CH(CHSEL).WF_RES <= '1';
					end if;

				when "0101" =>
					CH(CHSEL).LAL <= DI(7 downto 4);
					CH(CHSEL).RAL <= DI(3 downto 0);

				when "0110" =>
					if CH(CHSEL).CHON = '1' then
						CH(CHSEL).DA_OUT <= DI(4 downto 0);
					end if;
					if CH(CHSEL).DDA = '0' and CH(CHSEL).CHON = '0' then
						CH(CHSEL).WF_INC <= '1';
					end if;

				when "0111" =>
					if CHSEL = 4 or CHSEL =5 then
						CH(CHSEL).NE <= DI(7);
						CH(CHSEL).NG_FREQ <= DI(4 downto 0);
					end if;

				when "1000" =>
					CH(1).LFO_FREQ <= DI;

				when "1001" =>
					CH(1).LFCTL <= DI(1 downto 0);
					CH(1).LFTRG <= DI(7);

				when others => null;
				end case;
			end if;
		end if;
	end if;
		if SS_SHIFT = '1' then
			CHSEL <= to_integer(unsigned(SS_N(2 downto 0)));
			LMAL <= SS_N(6 downto 3);
			RMAL <= SS_N(10 downto 7);
			CH(0).FREQ <= SS_N(22 downto 11);
			CH(0).DDA <= SS_N(23);
			CH(0).CHON <= SS_N(24);
			CH(0).AL <= SS_N(29 downto 25);
			CH(0).LAL <= SS_N(33 downto 30);
			CH(0).RAL <= SS_N(37 downto 34);
			CH(0).DA_OUT <= SS_N(42 downto 38);
			CH(1).FREQ <= SS_N(82 downto 71);
			CH(1).DDA <= SS_N(83);
			CH(1).CHON <= SS_N(84);
			CH(1).AL <= SS_N(89 downto 85);
			CH(1).LAL <= SS_N(93 downto 90);
			CH(1).RAL <= SS_N(97 downto 94);
			CH(1).DA_OUT <= SS_N(102 downto 98);
			CH(2).FREQ <= SS_N(142 downto 131);
			CH(2).DDA <= SS_N(143);
			CH(2).CHON <= SS_N(144);
			CH(2).AL <= SS_N(149 downto 145);
			CH(2).LAL <= SS_N(153 downto 150);
			CH(2).RAL <= SS_N(157 downto 154);
			CH(2).DA_OUT <= SS_N(162 downto 158);
			CH(3).FREQ <= SS_N(202 downto 191);
			CH(3).DDA <= SS_N(203);
			CH(3).CHON <= SS_N(204);
			CH(3).AL <= SS_N(209 downto 205);
			CH(3).LAL <= SS_N(213 downto 210);
			CH(3).RAL <= SS_N(217 downto 214);
			CH(3).DA_OUT <= SS_N(222 downto 218);
			CH(4).FREQ <= SS_N(262 downto 251);
			CH(4).DDA <= SS_N(263);
			CH(4).CHON <= SS_N(264);
			CH(4).AL <= SS_N(269 downto 265);
			CH(4).LAL <= SS_N(273 downto 270);
			CH(4).RAL <= SS_N(277 downto 274);
			CH(4).DA_OUT <= SS_N(282 downto 278);
			CH(5).FREQ <= SS_N(322 downto 311);
			CH(5).DDA <= SS_N(323);
			CH(5).CHON <= SS_N(324);
			CH(5).AL <= SS_N(329 downto 325);
			CH(5).LAL <= SS_N(333 downto 330);
			CH(5).RAL <= SS_N(337 downto 334);
			CH(5).DA_OUT <= SS_N(342 downto 338);
			CH(4).NG_FREQ <= SS_N(375 downto 371);
			CH(4).NE <= SS_N(376);
			CH(5).NG_FREQ <= SS_N(416 downto 412);
			CH(5).NE <= SS_N(417);
			CH(1).LFO_FREQ <= SS_N(460 downto 453);
			CH(1).LFCTL <= SS_N(462 downto 461);
			CH(1).LFTRG <= SS_N(463);
		end if;
	end if;
end process;


process( CLK ) begin
	if rising_edge( CLK ) then
		if SS_HOLD = '0' then
		for i in 0 to 5 loop
			if RESET_N = '0' then
				CH(i).GL_OUT <= (others => '0');
				CH(i).WF_CNT <= (others => '0');
				CH(i).LFSR <= (others => '0');
				CH(i).NG_CNT <= (others => '0');
				CH(i).LFO_CNT <= (others => '0');
			else
				if CH(i).WF_RES = '1' then
					CH(i).WF_ADDR <= (others => '0');
				end if;
				if CH(i).WF_INC = '1' then
					CH(i).WF_ADDR <= CH(i).WF_ADDR + 1;
				end if;

				if CH(i).LFCTL /= "00" then
					CH(i).WF_OUT <= WF_Q(i);

					if CH(i).LFTRG = '1' then
						CH(i).WF_ADDR <= (others => '0');
						CH(i).WF_CNT <= (CH(i).FREQ - 1) & "1";
						CH(i).LFO_CNT <= CH(i).LFO_FREQ - 1;
					else
						if CLKEN = '1' then
							CH(i).LFO_CNT <= CH(i).LFO_CNT - 1;
							if CH(i).LFO_CNT = 0 then
								CH(i).LFO_CNT <= CH(i).LFO_FREQ - 1;
								CH(i).WF_CNT <= CH(i).WF_CNT - 1;
								if CH(i).WF_CNT = 0 then
									CH(i).WF_CNT <= (CH(i).FREQ - 1) & "1";
									CH(i).WF_ADDR <= CH(i).WF_ADDR + 1;
								end if;
							end if;
						end if;
					end if;
				elsif CH(i).CHON = '0' then
					CH(i).WF_CNT <= (CH(i).FREQ - 1 + CH(i).LFO_ADD) & "1";
				elsif CH(i).DDA = '0' then
					CH(i).WF_OUT <= WF_Q(i);

					if CLKEN = '1' then
						CH(i).WF_CNT <= CH(i).WF_CNT - 1;
						if CH(i).WF_CNT = 0 then
							CH(i).WF_CNT <= (CH(i).FREQ - 1 + CH(i).LFO_ADD) & "1";
							CH(i).WF_ADDR <= CH(i).WF_ADDR + 1;
						end if;
					end if;
				end if;

				if CH(i).NE = '0' then
				if CH(i).NG_FREQ = "11111" then
						CH(i).NG_CNT <= "000000111111";
					else
						CH(i).NG_CNT <= ( not(CH(i).NG_FREQ) - 1) & "1111111";
					end if;
				else
					if CH(i).LFSR(0) = '0' then
						CH(i).NG_OUT <= "00000";
					else
						CH(i).NG_OUT <= "11111";
					end if;

					if CLKEN = '1' then
						CH(i).NG_CNT <= CH(i).NG_CNT - 1;
						if CH(i).NG_CNT = 0 then
							if CH(i).NG_FREQ = "11111" then
								CH(i).NG_CNT <= "000000111111";
							else
								CH(i).NG_CNT <= ( not(CH(i).NG_FREQ) - 1) & "1111111";
							end if;
							if CH(i).LFSR = 0 then
								CH(i).LFSR(0) <= '1';
							else
								CH(i).LFSR <= (CH(i).LFSR(0) xor CH(i).LFSR(1) xor CH(i).LFSR(11) xor CH(i).LFSR(12) xor CH(i).LFSR(17)) & CH(i).LFSR(17 downto 1);
							end if;
						end if;
					end if;
				end if;

				if CH(i).CHON = '0' then
					CH(i).GL_OUT <= "10000";		-- Not zero; this should be midpoint in the range to reduce 'pop' sound
				elsif CH(i).DDA = '1' then
					CH(i).GL_OUT <= CH(i).DA_OUT;
				elsif CH(i).NE = '1' then
					CH(i).GL_OUT <= CH(i).NG_OUT;
				else
					CH(i).GL_OUT <= CH(i).WF_OUT;
				end if;
			end if;
		end loop;
		end if;
		if SS_SHIFT = '1' then
			CH(0).WF_ADDR <= SS_N(47 downto 43);
			CH(0).WF_CNT <= SS_N(60 downto 48);
			CH(0).WF_OUT <= SS_N(65 downto 61);
			CH(0).GL_OUT <= SS_N(70 downto 66);
			CH(1).WF_ADDR <= SS_N(107 downto 103);
			CH(1).WF_CNT <= SS_N(120 downto 108);
			CH(1).WF_OUT <= SS_N(125 downto 121);
			CH(1).GL_OUT <= SS_N(130 downto 126);
			CH(2).WF_ADDR <= SS_N(167 downto 163);
			CH(2).WF_CNT <= SS_N(180 downto 168);
			CH(2).WF_OUT <= SS_N(185 downto 181);
			CH(2).GL_OUT <= SS_N(190 downto 186);
			CH(3).WF_ADDR <= SS_N(227 downto 223);
			CH(3).WF_CNT <= SS_N(240 downto 228);
			CH(3).WF_OUT <= SS_N(245 downto 241);
			CH(3).GL_OUT <= SS_N(250 downto 246);
			CH(4).WF_ADDR <= SS_N(287 downto 283);
			CH(4).WF_CNT <= SS_N(300 downto 288);
			CH(4).WF_OUT <= SS_N(305 downto 301);
			CH(4).GL_OUT <= SS_N(310 downto 306);
			CH(5).WF_ADDR <= SS_N(347 downto 343);
			CH(5).WF_CNT <= SS_N(360 downto 348);
			CH(5).WF_OUT <= SS_N(365 downto 361);
			CH(5).GL_OUT <= SS_N(370 downto 366);
			CH(4).LFSR <= SS_N(394 downto 377);
			CH(4).NG_CNT <= SS_N(406 downto 395);
			CH(4).NG_OUT <= SS_N(411 downto 407);
			CH(5).LFSR <= SS_N(435 downto 418);
			CH(5).NG_CNT <= SS_N(447 downto 436);
			CH(5).NG_OUT <= SS_N(452 downto 448);
			CH(1).LFO_CNT <= SS_N(471 downto 464);
		end if;
	end if;
end process;

process( CLK )
	variable DATA: std_logic_vector(4 downto 0);
begin
	if rising_edge( CLK ) then
		if SS_HOLD = '1' then
			null;
		elsif RESET_N = '0' then
			for i in 0 to 5 loop
				CH(i).LFO_ADD <= (others => '0');
			end loop;
		else
			DATA := WF_Q(1) xor "10000";	-- the wave minus 16, as MAME and Geargrafx; MiSTer's "1000" flips bit 3
			CH(0).LFO_ADD(11 downto 8) <= DATA(4) & DATA(4) & DATA(4) & DATA(4);
			case CH(1).LFCTL is
			when "01" =>   CH(0).LFO_ADD(7 downto 0) <= DATA(4) & DATA(4) & DATA(4) & DATA;
			when "10" =>   CH(0).LFO_ADD(7 downto 0) <= DATA(4) & DATA & "00";
			when "11" =>   CH(0).LFO_ADD(7 downto 0) <= DATA(3 downto 0) & "0000";
			when others => CH(0).LFO_ADD <= (others => '0');
			end case;
		end if;
		if SS_SHIFT = '1' then
			CH(0).LFO_ADD <= SS_N(483 downto 472);
		end if;
	end if;
end process;

WF_MEM : for i in 0 to 5 generate
	signal WF_RAM : wavedata_t := (others => (others => '0'));
	attribute ramstyle : string;
	attribute ramstyle of WF_RAM : signal is "MLAB";
begin
	-- held for a save state, the waves are the engine's to read and write
	WF_A(i) <= SS_WF_A(4 downto 0) when SS_HOLD = '1' else CH(i).WF_ADDR;
	WF_WE(i) <= (SS_WF_WE and bool_bit(conv_integer(SS_WF_A(7 downto 5)) = i)) when SS_HOLD = '1' else
	            '1' when RESET_N = '1' and WE = '1' and A = "0110" and CHSEL = i and CH(i).DDA = '0' else '0';
	WF_D(i) <= SS_WF_D when SS_HOLD = '1' else DI(4 downto 0);
	process( CLK )
	begin
		if rising_edge( CLK ) then
			if WF_WE(i) = '1' then
				WF_RAM(conv_integer(WF_A(i))) <= WF_D(i);
			end if;
		end if;
	end process;
	WF_Q(i) <= WF_RAM(conv_integer(WF_A(i)));
end generate;
SS_WF_Q <= WF_Q(conv_integer(SS_WF_A(7 downto 5))) when conv_integer(SS_WF_A(7 downto 5)) < 6 else "00000";

-- Channels mixing
VT : entity work.dpram generic map (12,24,"HUC6280/voltab.mif")
port map (
	clock		=> CLK,
	address_a=> VT_ADDR,
	q_a		=> VT_DATA
);

process( CLK )
begin
	if rising_edge( CLK ) then
		if SS_HOLD = '1' then
			null;
		elsif RESET_N = '0' then
			LDATA_FF <= (others => '0');
			RDATA_FF <= (others => '0');
			MIX <= MIX_WAIT;
		else
			case MIX is
			when MIX_WAIT =>
				LACC <= (others => '0');
				RACC <= (others => '0');
				MIX_CNT <= (others => '0');
				VT_ADDR <= (others => '1');
				if DAC_LATCH = '1' then
					MIX <= MIX_NEXT;
				end if;

			when MIX_NEXT =>
				VT_ADDR <= CH(conv_integer(MIX_CNT)).GL_OUT
					& ( "1011101" - CH(conv_integer(MIX_CNT)).AL - (CH(conv_integer(MIX_CNT)).LAL & "1") - (LMAL & "1") );
				MIX <= MIX_LREAD;

			when MIX_LREAD =>
				MIX <= MIX_LNEXT;

			when MIX_LNEXT =>
				LACC <= LACC + VT_DATA;
				VT_ADDR <= CH(conv_integer(MIX_CNT)).GL_OUT
					& ( "1011101" - CH(conv_integer(MIX_CNT)).AL - (CH(conv_integer(MIX_CNT)).RAL & "1") - (RMAL & "1") );
				MIX <= MIX_RREAD;

			when MIX_RREAD =>
				MIX <= MIX_RNEXT;

			when MIX_RNEXT =>
				RACC <= RACC + VT_DATA;
				if MIX_CNT = "101" then
					MIX <= MIX_END;
				else
					MIX_CNT <= MIX_CNT + 1;
					MIX <= MIX_NEXT;
				end if;

			when MIX_END =>
				LDATA_FF <= LACC;
				RDATA_FF <= RACC;
				MIX <= MIX_WAIT;

			when others => null;
			end case;
		end if;
		if SS_SHIFT = '1' then
			LACC <= SS_N(507 downto 484);
			RACC <= SS_N(531 downto 508);
			VT_ADDR <= SS_N(543 downto 532);
			MIX_CNT <= SS_N(546 downto 544);
			LDATA_FF <= SS_N(570 downto 547);
			RDATA_FF <= SS_N(594 downto 571);
			MIX <= mix_state(SS_N(597 downto 595));
		end if;
	end if;
end process;

LDATA <= LDATA_FF;
RDATA <= RDATA_FF;

end rtl;

