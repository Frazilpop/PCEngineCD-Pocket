// core_bridge_cmd.v's watchdog on its own, against a stand-in Pocket (tools/bridge-test.sh).
// Built with SIM_PORT, so its waits are 10 ms to take a command up, 40 ms to finish, 1 ms
// between; the real ones are 1 s, 3 s and 10 ms. The times printed are the simulator's.
`timescale 1ns/1ps
// the data table isn't used here
module mf_datatable(input [9:0] address_a, input [9:0] address_b, input clock_a, input clock_b,
  input [31:0] data_a, input [31:0] data_b, input rden_a, input rden_b, input wren_a, input wren_b,
  output reg [31:0] q_a, output reg [31:0] q_b);
endmodule

module tb;
  // MODE: 0 answers every command; 1 leaves the first data slot command (slot 100's name, the
  // firmware's first) in the mailbox; 2 takes it up and never finishes it; 3 never answers
  // Ready to Run
  parameter MODE = 0;
  reg clk = 0; always #6.734 clk = ~clk;
  reg [31:0] addr = 0, wdata = 0; reg rd = 0, wr = 0; wire [31:0] rdata;
  reg setup_done = 0, t_read = 0, t_getname = 0;
  wire ack, done; wire [15:0] err; wire [7:0] wdc;
  core_bridge_cmd dut(.clk(clk), .clk_sys(clk), .bridge_endian_little(1'b0), .bridge_addr(addr), .bridge_rd(rd),
    .bridge_rd_data(rdata), .bridge_wr(wr), .bridge_wr_data(wdata), .status_boot_done(1'b1), .status_setup_done(setup_done),
    .status_running(1'b1), .dataslot_requestread_ack(1'b1), .dataslot_requestread_ok(1'b1), .dataslot_requestwrite_ack(1'b1),
    .dataslot_requestwrite_ok(1'b1), .savestate_supported(1'b0), .savestate_addr(0), .savestate_size(0), .savestate_maxloadsize(0),
    .savestate_start_ack(1'b0), .savestate_start_busy(1'b0), .savestate_start_ok(1'b0), .savestate_start_err(1'b0),
    .savestate_load_ack(1'b0), .savestate_load_busy(1'b0), .savestate_load_ok(1'b0), .savestate_load_err(1'b0),
    .target_dataslot_read(t_read), .target_dataslot_write(1'b0), .target_dataslot_enableLBA48(1'b0), .target_dataslot_flush(1'b0),
    .target_dataslot_Get_filename(t_getname), .target_dataslot_Open_file(1'b0), .target_dataslot_ack(ack), .target_dataslot_done(done),
    .target_dataslot_err(err), .target_dataslot_id(16'd100), .target_dataslot_slotoffset(0), .target_dataslot_slotoffsetLBA48(0),
    .target_dataslot_bridgeaddr(32'h12345678), .target_dataslot_length(512), .datatable_addr(0), .datatable_wren(1'b0),
    .datatable_rden(1'b0), .datatable_data(0), .target_wd_count(wdc));

  task automatic bus_rd(input [31:0] a, output [31:0] d);
    @(posedge clk) begin addr <= a; rd <= 1; end
    @(posedge clk) rd <= 0;
    repeat (3) @(posedge clk);
    d = rdata;
  endtask
  task automatic bus_wr(input [31:0] a, input [31:0] d);
    @(posedge clk) begin addr <= a; wdata <= d; wr <= 1; end
    @(posedge clk) wr <= 0;
    repeat (3) @(posedge clk);
  endtask

  // the Pocket: polls the target mailbox every 2 us; a new 'cm' is one seen after anything else
  integer seen = 0, answered = 0; reg [31:0] m, p20, p24; reg was_cm = 0; integer busy_left = -1; reg hung = 0;
  initial begin
    forever begin
      repeat (150) @(posedge clk);
      bus_rd(32'hF8001000, m);
      if (busy_left > 0) busy_left = busy_left - 1;
      else if (busy_left == 0) begin
        busy_left = -1;
        bus_wr(32'hF8001000, 32'h6F6B0000); answered = answered + 1;
      end
      if (m[31:16] == 16'h636D && !was_cm) begin
        seen = seen + 1;
        bus_rd(32'hF8001020, p20); bus_rd(32'hF8001024, p24);
        $display("%0t ms: the Pocket sees cm %04h (id %0d, %08h), the %0d", $realtime/1e6, m[15:0], p20[15:0], p24, seen);
        if (MODE == 1 && seen == 2) ;                                   // left in the mailbox
        else if (MODE == 3 && m[15:0] == 16'h0140) ;                    // never answered
        else if (MODE == 2 && seen == 2) bus_wr(32'hF8001000, {16'h6275, m[15:0]});   // taken up, never finished
        else begin bus_wr(32'hF8001000, {16'h6275, m[15:0]}); busy_left = 20; end
      end
      was_cm = (m[31:16] == 16'h636D);
    end
  end

  realtime t0;
  initial begin
    repeat (20) @(posedge clk);
    setup_done = 1;                      // 0x0140 first, as at a start
    repeat (2000) @(posedge clk);
    t0 = $realtime;
    t_getname = 1; repeat (4) @(posedge clk); t_getname = 0;   // the firmware's first: slot 100's name
    fork
      begin wait (done); $display("PASS name: done after %0.1f ms, err %0h, asked again %0d", ($realtime-t0)/1e6, err, wdc); end
      begin #200ms; $display("FAIL name: never done (asked again %0d)", wdc); $finish; end
    join_any
    disable fork;
    repeat (100) @(posedge clk);
    t0 = $realtime;
    t_read = 1; repeat (4) @(posedge clk); t_read = 0;          // then a read, answered at once
    fork
      begin wait (!done); wait (done); $display("PASS read: done after %0.2f ms, asked again %0d", ($realtime-t0)/1e6, wdc); end
      begin #200ms; $display("FAIL read: never done"); $finish; end
    join_any
    $display("the Pocket saw %0d commands", seen);
    $finish;
  end
endmodule
