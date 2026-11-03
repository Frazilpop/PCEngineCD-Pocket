-- The Altera memories of rtl/dpram.vhd and rtl/cd/*_FIFO.vhd as plain VHDL, for
-- GHDL's translation of the chips to Verilog (tools/sim.sh). The entities and
-- ports are theirs; they behave as the wizard's settings say:
--   dpram: the address and write registered, the output not, so a read gives the
--     word a clock later; reading where the same port writes gives the new data.
--     An image from mem_init_file, which the build has made plain hex beside it
--     (mif2hex in tools/sim.sh).
--   the FIFOs: scfifo in show-ahead, q the oldest word with no read asked for,
--     writes refused when full and reads when empty. The pointers wrap at
--     lpm_numwords, as CDSUBC_FIFO's 490 needs.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity dpram is
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8;
		mem_init_file : string := " ";
		disable_value : std_logic := '1'
	);
	port (
		clock     : in  std_logic;
		address_a : in  std_logic_vector(addr_width-1 downto 0);
		data_a    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
		enable_a  : in  std_logic := '1';
		wren_a    : in  std_logic := '0';
		q_a       : out std_logic_vector(data_width-1 downto 0);
		cs_a      : in  std_logic := '1';
		address_b : in  std_logic_vector(addr_width-1 downto 0) := (others => '0');
		data_b    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
		enable_b  : in  std_logic := '1';
		wren_b    : in  std_logic := '0';
		q_b       : out std_logic_vector(data_width-1 downto 0);
		cs_b      : in  std_logic := '1'
	);
end entity;

architecture sim of dpram is
	type mem_t is array(0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);

	impure function image return mem_t is
		file f : text;
		variable l : line;
		variable v : mem_t := (others => (others => '0'));
		variable c : character;
		variable d : integer;
		variable w : unsigned(31 downto 0);
	begin
		if mem_init_file'length < 2 then
			return v;
		end if;
		file_open(f, mem_init_file & ".hex", read_mode);
		for i in v'range loop
			exit when endfile(f);
			readline(f, l);
			w := (others => '0');
			for k in 1 to l'length loop
				read(l, c);
				if c >= 'a' then d := character'pos(c) - character'pos('a') + 10;
				else d := character'pos(c) - character'pos('0');
				end if;
				w := w(27 downto 0) & to_unsigned(d, 4);
			end loop;
			v(i) := std_logic_vector(w(data_width-1 downto 0));
		end loop;
		file_close(f);
		return v;
	end function;

	signal mem : mem_t := image;
	signal q0 : std_logic_vector(data_width-1 downto 0) := (others => '0');
	signal q1 : std_logic_vector(data_width-1 downto 0) := (others => '0');
begin
	q_a <= q0 when cs_a = '1' else (others => disable_value);
	q_b <= q1 when cs_b = '1' else (others => disable_value);

	process(clock) begin
		if rising_edge(clock) then
			if enable_a = '1' then
				if wren_a = '1' and cs_a = '1' then
					mem(to_integer(unsigned(address_a))) <= data_a;
					q0 <= data_a;
				else
					q0 <= mem(to_integer(unsigned(address_a)));
				end if;
			end if;
			if enable_b = '1' then
				if wren_b = '1' and cs_b = '1' then
					mem(to_integer(unsigned(address_b))) <= data_b;
					q1 <= data_b;
				else
					q1 <= mem(to_integer(unsigned(address_b)));
				end if;
			end if;
		end if;
	end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sim_fifo is
	generic (
		words  : integer;
		abits  : integer;
		dbits  : integer;
		afull  : integer
	);
	port (
		clock : in std_logic;
		clear : in std_logic;
		data  : in std_logic_vector(dbits-1 downto 0);
		wrreq : in std_logic;
		rdreq : in std_logic;
		almost_full : out std_logic;
		empty : out std_logic;
		full  : out std_logic;
		q     : out std_logic_vector(dbits-1 downto 0)
	);
end entity;

architecture sim of sim_fifo is
	type mem_t is array(0 to words-1) of std_logic_vector(dbits-1 downto 0);
	signal mem : mem_t := (others => (others => '0'));
	signal wa, ra : integer range 0 to words-1 := 0;
	signal count : integer range 0 to words := 0;
	signal do_rd, do_wr : boolean;
begin
	empty <= '1' when count = 0 else '0';
	full  <= '1' when count = words else '0';
	almost_full <= '1' when count >= afull else '0';
	q <= mem(ra);
	do_rd <= rdreq = '1' and count /= 0;
	do_wr <= wrreq = '1' and count /= words;

	process(clock) begin
		if rising_edge(clock) then
			if clear = '1' then
				wa <= 0;
				ra <= 0;
				count <= 0;
			else
				if do_wr then
					mem(wa) <= data;
					if wa = words-1 then wa <= 0; else wa <= wa + 1; end if;
				end if;
				if do_rd then
					if ra = words-1 then ra <= 0; else ra <= ra + 1; end if;
				end if;
				if do_wr and not do_rd then count <= count + 1;
				elsif do_rd and not do_wr then count <= count - 1;
				end if;
			end if;
		end if;
	end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;

entity CDDA_FIFO is
	port (
		clock : in std_logic;
		data  : in std_logic_vector(31 downto 0);
		rdreq : in std_logic;
		sclr  : in std_logic;
		wrreq : in std_logic;
		almost_full : out std_logic;
		empty : out std_logic;
		full  : out std_logic;
		q     : out std_logic_vector(31 downto 0)
	);
end entity;

architecture sim of CDDA_FIFO is
begin
	f : entity work.sim_fifo generic map (1024, 10, 32, 980)
		port map (clock, sclr, data, wrreq, rdreq, almost_full, empty, full, q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;

entity SCSI_FIFO is
	port (
		aclr  : in std_logic;
		clock : in std_logic;
		data  : in std_logic_vector(7 downto 0);
		rdreq : in std_logic;
		wrreq : in std_logic;
		almost_full : out std_logic;
		empty : out std_logic;
		full  : out std_logic;
		q     : out std_logic_vector(7 downto 0)
	);
end entity;

architecture sim of SCSI_FIFO is
begin
	-- aclr is the chip's reset, held for many clocks, so a clear on the clock does
	f : entity work.sim_fifo generic map (4096, 12, 8, 4000)
		port map (clock, aclr, data, wrreq, rdreq, almost_full, empty, full, q);
end architecture;

library ieee;
use ieee.std_logic_1164.all;

entity CDSUBC_FIFO is
	port (
		clock : in std_logic;
		data  : in std_logic_vector(7 downto 0);
		rdreq : in std_logic;
		sclr  : in std_logic;
		wrreq : in std_logic;
		empty : out std_logic;
		full  : out std_logic;
		q     : out std_logic_vector(7 downto 0)
	);
end entity;

architecture sim of CDSUBC_FIFO is
	signal unused : std_logic;
begin
	f : entity work.sim_fifo generic map (490, 9, 8, 490)
		port map (clock, sclr, data, wrreq, rdreq, unused, empty, full, q);
end architecture;
