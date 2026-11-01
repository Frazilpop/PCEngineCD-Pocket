-- The VCE and VDC joined as pce_top.vhd does since 0.4.0.
library IEEE;
use IEEE.std_logic_1164.all;

entity dut is
	port (
		CLK, RESET_N, CPU_CE : in std_logic;
		VDC_A : in std_logic_vector(1 downto 0);
		VDC_DI : in std_logic_vector(7 downto 0);
		VDC_CS_N, VDC_WR_N : in std_logic;
		VCE_A : in std_logic_vector(2 downto 0);
		VCE_DI : in std_logic_vector(7 downto 0);
		VCE_CE_N, VCE_WR_N : in std_logic;
		CE_FS, BORDER, HS_N, VS_N, HBL : out std_logic;
		VD : out std_logic_vector(8 downto 0)
	);
end entity;

architecture sim of dut is
	signal clken, clken_f, hs_f, hs_r, vs_f, vs_r, border_i : std_logic;
	signal vd_i : std_logic_vector(8 downto 0);
begin
	VD <= vd_i;
	BORDER <= border_i;
	vce : entity work.huc6260 port map (
		CLK => CLK, RESET_N => RESET_N, A => VCE_A, CE_N => VCE_CE_N, WR_N => VCE_WR_N, RD_N => '1', DI => VCE_DI,
		COLNO => vd_i, CLKEN => clken, CLKEN_F => clken_f,
		HSYNC_F => hs_f, HSYNC_R => hs_r, VSYNC_F => vs_f, VSYNC_R => vs_r,
		CLKEN_FS => CE_FS, RVBL => '0',
		GRID_EN => "00", BORDER_EN => '0', BORDER => border_i, GRID => "00",
		VS_N => VS_N, HS_N => HS_N, HBL => HBL);
	vdc : entity work.HUC6270 port map (
		CLK => CLK, RST_N => RESET_N, CLR_MEM => '0', CPU_CE => CPU_CE, BYTEWORD => '1', A => VDC_A,
		DI => "00000000" & VDC_DI, CS_N => VDC_CS_N, WR_N => VDC_WR_N, RD_N => '1',
		DCK_CE => clken, DCK_CE_F => clken_f,
		HSYNC_F => hs_f, HSYNC_R => hs_r, VSYNC_F => vs_f, VSYNC_R => vs_r,
		VD => vd_i, BORDER => border_i, RAM_DI => x"FFFF", BG_EN => '1', SPR_EN => '1');
end architecture;
