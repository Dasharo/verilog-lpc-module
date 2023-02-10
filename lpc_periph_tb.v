// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Copyright (C) 2008 Howard M. Harte <hharte@opencores.org>
// Copyright (C) 2021 LPN Plant
//
// This source file may be used and distributed without
// restriction provided that this copyright statement is not
// removed from the file and that any derivative work contains
// the original copyright notice and the associated disclaimer.
//
// This source file is free software; you can redistribute it
// and/or modify it under the terms of the GNU Lesser General
// Public License as published by the Free Software Foundation;
// either version 2.1 of the License, or (at your option) any
// later version.
//
// This source is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE.  See the GNU Lesser General Public License for more
// details.
//
// You should have received a copy of the GNU Lesser General
// Public License along with this source; if not, download it
// from http://www.opencores.org/lgpl.shtml

`timescale 1 ns / 1 ps

`include "lpc_defines.v"

module lpc_periph_tb ();

  // verilog_format: off  // verible-verilog-format messes up comments alignment
  reg  [ 7:0] periph_data   = 8'h00;
  reg  [ 7:0] expected_data = 8'h00;

  reg         LCLK;           // Host LPC output clock
  reg         LRESET;         // Host LReset
  reg         LFRAME;         // Host LFRAME
  wire  [3:0] LAD;            // Bi-directional (tri-state) LPC bus (multiplexed address and data 4-bit chunks)

  wire [ 7:0] lpc_data_io;    // Data received (I/O Write) or to be sent (I/O Read) to host
  wire [15:0] lpc_addr_o;     // 16-bit LPC Peripheral Address
  wire        lpc_data_wr;    // Signal to data provider that lpc_data_io has valid write data
  reg         lpc_wr_done;    // Signal from data provider that lpc_data_io has been read
  reg         lpc_data_rd;    // Signal from data provider that lpc_data_io has data for read
  wire        lpc_data_req;   // Signal to data provider that is requested (@posedge) or
                              // has been read (@negedge)

  integer cur_delay, delay, i;
  reg   [3:0] LAD_reg = 4'h0;
  reg drive_lpc_data = 0;
  reg expect_reset = 1;
  reg drive_lad = 0;
  // TPM read/write w/o delay takes 13 clock cycles. Add 1 for final interval, sub 1 for TAR.
  parameter timeout = 13;

  // verilog_format: on

  task lpc_write (input [3:0] start, input [3:0] cycdir, input [15:0] addr, input [7:0] data);
    reg rsp_expected;
    begin
      if ((start === `LPC_START) && (cycdir === `LPC_IO_WRITE))
        rsp_expected = 1;
      else
        rsp_expected = 0;

      @(negedge LCLK);
      drive_lad = 1;
      LFRAME = 0;
      LAD_reg = start;                        // START
      @(negedge LCLK) LFRAME = 1;
      LAD_reg = cycdir;                       // CYCTYPE + DIR
      @(negedge LCLK) LAD_reg = addr[15:12];  // ADDR
      @(negedge LCLK) LAD_reg = addr[11:8];
      @(negedge LCLK) LAD_reg = addr[7:4];
      @(negedge LCLK) LAD_reg = addr[3:0];
      @(negedge LCLK) LAD_reg = data[7:4];    // DATA
      @(negedge LCLK) LAD_reg = data[3:0];
      @(negedge LCLK) LAD_reg = 4'hF;         // TAR1
      @(negedge LCLK) drive_lad = 0;
      @(posedge LCLK) if (LAD !== 4'hz)       // TAR2
        $display("### LAD driven on TAR2 @ %t", $realtime);
      // Forked threads would hit previous posedge, skip it manually
      @(negedge LCLK);
      fork : ws                               // SYNC
        begin
          @(posedge LCLK) begin
            if (LRESET && rsp_expected) begin
              if (LAD !== `LPC_SYNC_READY && LAD !== `LPC_SYNC_LWAIT)
                $display("### Unexpected LAD on SYNC (%b) @ %t", LAD, $realtime);
            end else if (LRESET === 0 && LAD !== 4'hz)
              $display("### LAD driven during reset on SYNC (%b) @ %t", LAD, $realtime);
            else if (rsp_expected == 0 && LAD !== 4'hz)
              $display("### LAD driven for bad START/CYCDIR on SYNC (%b) @ %t", LAD, $realtime);
          end
        end
        begin
          @(posedge LCLK && LAD === `LPC_SYNC_READY && LRESET && rsp_expected) disable ws;
        end
      join
      @(posedge LCLK)                         // TAR1
      if (LRESET == 0 && LAD !== 4'hz)
        $display("### LAD driven on TAR1 during reset (%b) @ %t", LAD, $realtime);
      else if (rsp_expected == 0 && LAD !== 4'hz)
        $display("### LAD driven on TAR1 for bad START/CYCDIR (%b) @ %t", LAD, $realtime);
      else if (LRESET && rsp_expected && LAD === 4'hz)
        $display("### LAD not driven on TAR1 @ %t", $realtime);
      else if (LRESET && rsp_expected && LAD !== 4'hF)
        $display("### Unexpected LAD on TAR1 (%b) @ %t", LAD, $realtime);
      @(posedge LCLK) if (LAD !== 4'hz)       // TAR2
        $display("### LAD driven on TAR2 @ %t", $realtime);
      // Task should end on negedge, but because it also starts on negedge we end after posedge
      // here to make back-to-back invocations possible
    end
  endtask

  task lpc_read (input [3:0] start, input [3:0] cycdir, input [15:0] addr, output [7:0] data);
    reg rsp_expected;
    begin
      if ((start === `LPC_START) && (cycdir === `LPC_IO_READ))
        rsp_expected = 1;
      else
        rsp_expected = 0;

      @(negedge LCLK);
      drive_lad = 1;
      LFRAME = 0;
      LAD_reg = start;                        // START
      @(negedge LCLK) LFRAME = 1;
      LAD_reg = cycdir;                       // CYCTYPE + DIR
      @(negedge LCLK) LAD_reg = addr[15:12];  // ADDR
      @(negedge LCLK) LAD_reg = addr[11:8];
      @(negedge LCLK) LAD_reg = addr[7:4];
      @(negedge LCLK) LAD_reg = addr[3:0];
      @(negedge LCLK) LAD_reg = 4'hF;         // TAR1
      @(negedge LCLK) drive_lad = 0;
      @(posedge LCLK) if (LAD !== 4'hz)       // TAR2
        $display("### LAD driven on TAR2 @ %t", $realtime);
      // Forked threads would hit previous posedge, skip it manually
      @(negedge LCLK);
      fork : rs                               // SYNC
        begin
          @(posedge LCLK) begin
            if (LRESET && rsp_expected) begin
              if (LAD !== `LPC_SYNC_READY && LAD !== `LPC_SYNC_LWAIT)
                $display("### Unexpected LAD on SYNC (%b) @ %t", LAD, $realtime);
            end else if (LRESET === 0 && LAD !== 4'hz)
              $display("### LAD driven during reset on SYNC (%b) @ %t", LAD, $realtime);
            else if (rsp_expected == 0 && LAD !== 4'hz)
              $display("### LAD driven for bad START/CYCDIR on SYNC (%b) @ %t", LAD, $realtime);
          end
        end
        begin
          @(posedge LCLK && LAD === `LPC_SYNC_READY && LRESET && rsp_expected) disable rs;
        end
      join
      @(posedge LCLK) data[3:0] = LAD;        // DATA1
      if ((LAD[0] === 1'bx || LAD[1] === 1'bx || LAD[2] === 1'bx || LAD[3] === 1'bx ||
           LAD[0] === 1'bz || LAD[1] === 1'bz || LAD[2] === 1'bz || LAD[3] === 1'bz) &&
          LRESET && rsp_expected)
        $display("### Unexpected LAD on DATA1 (%b) @ %t", LAD, $realtime);
      else if (LRESET == 0 && LAD !== 4'hz)
        $display("### LAD driven on DATA1 during reset (%b) @ %t", LAD, $realtime);
      else if (rsp_expected == 0 && LAD !== 4'hz)
        $display("### LAD driven on DATA1 for bad START/CYCDIR (%b) @ %t", LAD, $realtime);
      @(posedge LCLK) data[7:4] = LAD;
      if ((LAD[0] === 1'bx || LAD[1] === 1'bx || LAD[2] === 1'bx || LAD[3] === 1'bx ||
           LAD[0] === 1'bz || LAD[1] === 1'bz || LAD[2] === 1'bz || LAD[3] === 1'bz) &&
          LRESET && rsp_expected)
        $display("### Unexpected LAD on DATA2 (%b) @ %t", LAD, $realtime);
      else if (LRESET == 0 && LAD !== 4'hz)
        $display("### LAD driven on DATA2 during reset (%b) @ %t", LAD, $realtime);
      else if (rsp_expected == 0 && LAD !== 4'hz)
        $display("### LAD driven on DATA2 for bad START/CYCDIR (%b) @ %t", LAD, $realtime);
      @(posedge LCLK)                         // TAR1
      if (LRESET == 0 && LAD !== 4'hz)
        $display("### LAD driven on TAR1 during reset (%b) @ %t", LAD, $realtime);
      else if (rsp_expected == 0 && LAD !== 4'hz)
        $display("### LAD driven on TAR1 for bad START/CYCDIR (%b) @ %t", LAD, $realtime);
      else if (LRESET && rsp_expected && LAD === 4'hz)
        $display("### LAD not driven on TAR1 @ %t", $realtime);
      else if (LRESET && rsp_expected && LAD !== 4'hF)
        $display("### Unexpected LAD on TAR1 (%b) @ %t", LAD, $realtime);
      @(posedge LCLK) if (LAD !== 4'hz)       // TAR2
        $display("### LAD driven on TAR2 @ %t", $realtime);
      // Task should end on negedge, but because it also starts on negedge we end after posedge
      // here to make back-to-back invocations possible
    end
  endtask

  task tpm_write (input [15:0] addr, input [7:0] data);
    lpc_write (`LPC_START, `LPC_IO_WRITE, addr, data);
  endtask

  task tpm_read (input [15:0] addr, output [7:0] data);
    lpc_read (`LPC_START, `LPC_IO_READ, addr, data);
  endtask

  initial begin
    LCLK = 1'b1;
    forever #20 LCLK = ~LCLK;
  end

  initial begin
    // Initialize
    $dumpfile("lpc_periph_tb.vcd");
    $dumpvars(0, lpc_periph_tb);
    $timeformat(-9, 0, " ns", 10);

    lpc_wr_done  = 0;
    lpc_data_rd  = 0;
    delay        = 0;
    LFRAME       = 1;
    #40 LRESET   = 0;
    #250 LRESET  = 1;
    expect_reset = 0;

    // Perform write
    $display("Performing TPM write w/o delay");
    expected_data = 8'h3C;
    tpm_write (16'hC44C, expected_data);
    if (periph_data != expected_data)
      $display("### Write failed, expected %2h, got %2h", expected_data, periph_data);

    // Perform write with delay
    delay = 10;
    expected_data = 8'h42;
    $display("Performing TPM write with delay");
    tpm_write (16'h9C39, expected_data);
    if (periph_data != expected_data)
      $display("### Write failed, expected %2h, got %2h", expected_data, periph_data);

    // Perform read with delay
    periph_data = 8'hA5;
    $display("Performing TPM read with delay");
    tpm_read (16'hFF00, expected_data);
    if (periph_data != expected_data)
      $display("### Read failed, expected %2h, got %2h", periph_data, expected_data);

    // Perform read without delay
    delay = 0;
    periph_data = 8'h7E;
    $display("Performing TPM read w/o delay");
    tpm_read (16'hFF00, expected_data);
    if (periph_data != expected_data)
      $display("### Read failed, expected %2h, got %2h", periph_data, expected_data);

    #1000

    // Test reset signals at various points of communication
    expect_reset = 1;
    $display("Testing reset behaviour - TPM write w/o delay");
    delay = 0;
    for (i = 0; i <= (timeout + delay) * 40; i = i + 19) begin
      expected_data = 8'h3C;
      fork : rw
        begin
          tpm_write (16'hFFFF, expected_data);
          $display("Write completed but it shouldn't @ %t", $realtime);
          disable rw;
        end
        begin
          #i LRESET = 0;
          #(((timeout + delay) * 40) - i);
          disable rw;
        end
      join
      LRESET = 1;
      #40;
    end

    #1000

    $display("Testing reset behaviour - TPM read w/o delay");
    delay = 0;
    for (i = 0; i <= (timeout + delay) * 40; i = i + 19) begin
      periph_data = 8'hA3;
      fork : rr
        begin
          tpm_read (16'h1423, expected_data);
          $display("Read completed but it shouldn't @ %t", $realtime);
          disable rr;
        end
        begin
          #i LRESET = 0;
          #(((timeout + delay) * 40) - i);
          disable rr;
        end
      join
      LRESET = 1;
      #40;
    end

    #1000

    $display("Testing reset behaviour - TPM write with delay");
    delay = 5;
    for (i = 0; i <= (timeout + delay) * 40; i = i + 19) begin
      expected_data = 8'h3C;
      fork : rwd
        begin
          tpm_write (16'hFFFF, expected_data);
          $display("Write completed but it shouldn't @ %t", $realtime);
          disable rwd;
        end
        begin
          #i LRESET = 0;
          #(((timeout + delay) * 40) - i);
          disable rwd;
        end
      join
      LRESET = 1;
      #40;
    end

    #1000

    $display("Testing reset behaviour - TPM read with delay");
    delay = 5;
    for (i = 0; i <= (timeout + delay) * 40; i = i + 19) begin
      periph_data = 8'hA3;
      fork : rrd
        begin
          tpm_read (16'h1423, expected_data);
          $display("Read completed but it shouldn't @ %t", $realtime);
          disable rrd;
        end
        begin
          #i LRESET = 0;
          #(((timeout + delay) * 40) - i);
          disable rrd;
        end
      join
      LRESET = 1;
      #40;
    end

    expect_reset = 0;

    // TODO: test other cycle types and start nibbles

    // TODO: test extended LFRAME# timings (with changing LAD)

    #1000;
    //------------------------------
    $stop;
    $finish;
  end

  assign lpc_data_io = lpc_data_rd ? periph_data : 8'hzz;
  assign LAD = drive_lad ? LAD_reg : 4'hz;

  // Simulate response to read and write requests with optional delay
  always @(posedge LCLK) begin
    if (lpc_data_wr == 1) begin
      cur_delay = cur_delay + 1;
      if (cur_delay > delay) begin
        periph_data = lpc_data_io;
        lpc_wr_done = 1;
        cur_delay = 0;
      end
    end else if (lpc_data_req == 0 && lpc_data_wr == 0) begin
      lpc_wr_done = 0;
      cur_delay = 0;
    end

    if (lpc_data_req == 1) begin
      cur_delay = cur_delay + 1;
      if (cur_delay > delay) begin
        lpc_data_rd = 1;
        cur_delay = 0;
      end
    end else if (lpc_data_wr == 0 && lpc_data_req == 0) begin
      lpc_data_rd = 0;
      cur_delay = 0;
    end
  end

  // Checks for unexpected states
  always @(negedge LRESET) begin
    if (expect_reset == 0)
      $display("### Unexpected LRESET deassertion @ %t", $realtime);
  end

  reg [3:0] old_LAD;
  realtime t;

  always @(LAD, lpc_data_io) begin
    // Skip initial state
    if ($realtime != 0) begin
      // Each bit must be tested individually, otherwise states like x1x1 wouldn't be caught
      if (LAD[0] === 1'bx || LAD[1] === 1'bx || LAD[2] === 1'bx || LAD[3] === 1'bx) begin
        // FIXME: when peripheral begins driving DATA1, x's appear on LAD in place of 1's in DATA1.
        // This doesn't happen on any other transition, even though there are other 0->1 transitions
        // when LAD is driven by peripheral. $strobe shows proper DATA1. As a workaround for getting
        // false positives, compare current LAD with next time step - OR of those two should equal
        // new signal and should not contain any x's, while AND should equal old signal (with x's).
        old_LAD = LAD;
        t = $realtime;
        #1;
        if (((old_LAD | LAD) !== LAD) || ((old_LAD & LAD) !== old_LAD) ||
            (LAD[0] === 1'bx || LAD[1] === 1'bx || LAD[2] === 1'bx || LAD[3] === 1'bx))
          $display("### Multiple LAD drivers (%b) LCLK = %b @ %t", LAD, LCLK, t);
      end
      if (lpc_data_io[0] === 1'bx || lpc_data_io[1] === 1'bx || lpc_data_io[2] === 1'bx ||
          lpc_data_io[3] === 1'bx || lpc_data_io[4] === 1'bx || lpc_data_io[5] === 1'bx ||
          lpc_data_io[6] === 1'bx || lpc_data_io[7] === 1'bx)
        $display("### Multiple lpc_data_io drivers (%b) @ %t", lpc_data_io, $realtime);
    end
  end

  // LPC Peripheral instantiation
  lpc_periph lpc_periph_inst (
      // LPC Interface
      .clk_i(LCLK),
      .nrst_i(LRESET),
      .lframe_i(LFRAME),
      .lad_bus(LAD),
      // Data provider interface
      .lpc_data_io(lpc_data_io),
      .lpc_addr_o(lpc_addr_o),
      .lpc_data_wr(lpc_data_wr),
      .lpc_wr_done(lpc_wr_done),
      .lpc_data_rd(lpc_data_rd),
      .lpc_data_req(lpc_data_req)
  );

endmodule
