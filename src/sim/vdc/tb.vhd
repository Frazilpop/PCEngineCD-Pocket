-- Programs the VDC and VCE as a game would, background on, every VRAM word $FFFF so
-- that all the display area is colour $FF, and prints each line the Pocket's line
-- buffer would take: the writer half of core/linebuffer.v, ce_pix being CE_FS.
-- tools/vdc-compare.sh runs it against old and new chips.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;

entity tb is
	generic (DOT, HSR, HDR : integer; NAME : string);
end entity;

architecture sim of tb is
	signal CLK : std_logic := '0';
	signal RESET_N : std_logic := '0';
	signal CPU_CE : std_logic := '0';
	signal cpu_cnt : integer range 0 to 11 := 0;
	signal VDC_A : std_logic_vector(1 downto 0) := "00";
	signal VDC_DI, VCE_DI : std_logic_vector(7 downto 0) := x"00";
	signal VDC_CS_N, VDC_WR_N, VCE_CE_N, VCE_WR_N : std_logic := '1';
	signal VCE_A : std_logic_vector(2 downto 0) := "000";
	signal CE_FS, BORDER, HS_N, VS_N, HBL : std_logic;
	signal VD : std_logic_vector(8 downto 0);
	signal measuring : boolean := false;
	signal finished : boolean := false;
begin
	CLK <= not CLK after 11640 ps when not finished else CLK;

	process (CLK) begin
		if rising_edge(CLK) then
			CPU_CE <= '0';
			if cpu_cnt = 11 then cpu_cnt <= 0; CPU_CE <= '1'; else cpu_cnt <= cpu_cnt + 1; end if;
		end if;
	end process;

	u : entity work.dut port map (
		CLK => CLK, RESET_N => RESET_N, CPU_CE => CPU_CE,
		VDC_A => VDC_A, VDC_DI => VDC_DI, VDC_CS_N => VDC_CS_N, VDC_WR_N => VDC_WR_N,
		VCE_A => VCE_A, VCE_DI => VCE_DI, VCE_CE_N => VCE_CE_N, VCE_WR_N => VCE_WR_N,
		CE_FS => CE_FS, BORDER => BORDER, HS_N => HS_N, VS_N => VS_N, HBL => HBL, VD => VD);

	stim : process
		procedure ce_wait is begin
			wait until rising_edge(CLK) and CPU_CE = '1';
		end procedure;
		procedure vdc_write(a : std_logic_vector(1 downto 0); d : integer) is begin
			ce_wait;
			VDC_A <= a; VDC_DI <= std_logic_vector(to_unsigned(d, 8)); VDC_CS_N <= '0'; VDC_WR_N <= '0';
			ce_wait;
			VDC_CS_N <= '1'; VDC_WR_N <= '1';
			ce_wait; ce_wait;
		end procedure;
		procedure reg(r, v : integer) is begin
			vdc_write("00", r);
			vdc_write("10", v mod 256);
			vdc_write("11", v / 256);
		end procedure;
	begin
		wait for 200 ns;
		wait until rising_edge(CLK);
		RESET_N <= '1';
		for i in 0 to 20 loop ce_wait; end loop;
		-- VCE control: the dot clock
		wait until rising_edge(CLK);
		VCE_A <= "000"; VCE_DI <= std_logic_vector(to_unsigned(DOT, 8)); VCE_CE_N <= '0'; VCE_WR_N <= '0';
		wait until rising_edge(CLK);
		VCE_CE_N <= '1'; VCE_WR_N <= '1';
		for i in 0 to 20 loop ce_wait; end loop;
		reg(16#09#, 0);        -- MWR
		reg(16#0A#, HSR);
		reg(16#0B#, HDR);
		reg(16#0C#, 16#0F02#); -- VPR
		reg(16#0D#, 16#00EF#); -- VDW, 240 lines
		reg(16#0E#, 16#0004#); -- VCR
		reg(16#07#, 0);        -- BXR
		reg(16#08#, 0);        -- BYR
		reg(16#05#, 16#0080#); -- CR, background on
		-- settle for two frames, then one to measure
		wait until falling_edge(VS_N);
		wait until falling_edge(VS_N);
		measuring <= true;
		wait until falling_edge(VS_N);
		finished <= true;
		wait;
	end process;

	mon : process (CLK)
		variable L : line;
		variable prev_hs, prev_b : std_logic := '1';
		variable enable_delay, border_delay : integer := 0;
		variable write_now : boolean;
		variable writes, disp, clk_in_line, border_off, border_on, hbl_off, hbl_on, first_disp, first_write, lines : integer := 0;
		variable prev_hbl : std_logic := '1';
		variable hs : std_logic;
	begin
		if rising_edge(CLK) then
			hs := not HS_N;
			clk_in_line := clk_in_line + 1;
			-- linebuffer.v's writer (2 and 3 since 9 Nov 2026: with 3 and 4 the line buffer lost the first
			-- dot of every line, which this bench can't show, as it counts the VDC's colour and not the VCE's)
			write_now := false;
			if BORDER = '0' and prev_b = '1' then
				enable_delay := 2;
				border_off := clk_in_line;
			elsif BORDER = '1' and prev_b = '0' then
				border_delay := 3;
				border_on := clk_in_line;
			elsif CE_FS = '1' then
				if border_delay > 0 then border_delay := border_delay - 1; end if;
				if BORDER = '0' or border_delay > 0 then
					if enable_delay > 0 then enable_delay := enable_delay - 1;
					else write_now := true; end if;
				end if;
			end if;
			if HBL = '0' and prev_hbl = '1' then hbl_off := clk_in_line; end if;
			if HBL = '1' and prev_hbl = '0' then hbl_on := clk_in_line; end if;
			if write_now then
				writes := writes + 1;
				if first_write = 0 then first_write := clk_in_line; end if;
			end if;
			if CE_FS = '1' and VD(7 downto 0) = x"FF" then
				disp := disp + 1;
				if first_disp = 0 then first_disp := clk_in_line; end if;
			end if;
			-- a new line: the bank switch in linebuffer.v
			if hs = '1' and prev_hs = '0' then
				if measuring then
					write(L, NAME & " line " & integer'image(lines)
						& " clocks " & integer'image(clk_in_line)
						& " writes " & integer'image(writes)
						& " colour " & integer'image(disp)
						& " firstcolour " & integer'image(first_disp)
						& " firstwrite " & integer'image(first_write)
						& " borderoff " & integer'image(border_off)
						& " borderon " & integer'image(border_on)
						& " hbloff " & integer'image(hbl_off)
						& " hblon " & integer'image(hbl_on));
					writeline(output, L);
					lines := lines + 1;
				end if;
				writes := 0; disp := 0; clk_in_line := 0; first_disp := 0; first_write := 0;
				border_off := 0; border_on := 0; hbl_off := 0; hbl_on := 0;
			end if;
			prev_hs := hs; prev_b := BORDER; prev_hbl := HBL;
		end if;
	end process;
end architecture;
