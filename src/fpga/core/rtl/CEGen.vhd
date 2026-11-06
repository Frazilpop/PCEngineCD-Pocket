LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;

ENTITY CEGen IS
	PORT
	(
		CLK       : in  STD_LOGIC;
		RST_N     : in  STD_LOGIC;

		IN_CLK    : in  integer;
		OUT_CLK   : in  integer;

		CE        : out STD_LOGIC;

		-- A save state (docs/SAVESTATES.md): SS_HOLD stops it; its 28 bits out at SS_Q, and
		-- in from SS_D at SS_WE. The sum is a signal for this, where MiSTer's is a variable.
		SS_HOLD   : in  STD_LOGIC := '0';
		SS_Q      : out STD_LOGIC_VECTOR(27 downto 0);
		SS_D      : in  STD_LOGIC_VECTOR(27 downto 0) := (others => '0');
		SS_WE     : in  STD_LOGIC := '0'
	);
END CEGen;

ARCHITECTURE SYN OF CEGen IS
	signal CLK_SUM : unsigned(26 downto 0);
	signal CE_R    : STD_LOGIC;
BEGIN
	process( RST_N, CLK )
	variable NEXT_SUM : unsigned(26 downto 0);
	begin
		if RST_N = '0' then
			CLK_SUM <= (others => '0');
			CE_R <= '0';
		elsif rising_edge(CLK) then
			if SS_HOLD = '0' then
				CE_R <= '0';
				NEXT_SUM := CLK_SUM + to_unsigned(OUT_CLK, 27);
				if NEXT_SUM >= to_unsigned(IN_CLK, 27) then
					NEXT_SUM := NEXT_SUM - to_unsigned(IN_CLK, 27);
					CE_R <= '1';
				end if;
				CLK_SUM <= NEXT_SUM;
			end if;
			if SS_WE = '1' then
				CE_R <= SS_D(27);
				CLK_SUM <= unsigned(SS_D(26 downto 0));
			end if;
		end if;
	end process;
	CE <= CE_R;
	SS_Q <= CE_R & std_logic_vector(CLK_SUM);
END SYN;