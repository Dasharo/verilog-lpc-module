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

  integer cur_delay, delay;
  reg   [3:0] LAD_reg = 4'h0;
  reg drive_lpc_data = 0;
  reg expect_reset = 1;
  reg drive_lad = 0;

  // verilog_format: on

  task tpm_write (input [15:0] addr, input [7:0] data);
    begin
      @(negedge LCLK);
      drive_lad = 1;
      LFRAME = 0;
      LAD_reg = 4'h5;             // START
      #40 LFRAME = 1;
      LAD_reg = 4'h2;             // CYCTYPE + DIR
      #40 LAD_reg = addr[15:12];  // ADDR
      #40 LAD_reg = addr[11:8];
      #40 LAD_reg = addr[7:4];
      #40 LAD_reg = addr[3:0];
      #40 LAD_reg = data[7:4];    // DATA
      #40 LAD_reg = data[3:0];
      #40 LAD_reg = 4'hF;         // TAR
      #40 drive_lad = 0;
      #40;                        // SYNC
      #20 @(posedge LCLK && LAD == 4'h0);
      @(negedge LCLK);            // TAR
      #80;                        // 2 cycles - from start of TAR1 to end of TAR2
    end
  endtask

  task tpm_read (input [15:0] addr, output [7:0] data);
    begin
      @(negedge LCLK);
      drive_lad = 1;
      LFRAME = 0;
      LAD_reg = 4'h5;             // START
      #40 LFRAME = 1;
      LAD_reg = 4'h0;             // CYCTYPE + DIR
      #40 LAD_reg = addr[15:12];  // ADDR
      #40 LAD_reg = addr[11:8];
      #40 LAD_reg = addr[7:4];
      #40 LAD_reg = addr[3:0];
      #40 LAD_reg = 4'hF;         // TAR
      #40 drive_lad = 0;
      #40;                        // SYNC
      #20 @(posedge LCLK && LAD == 4'h0);
      #40 data[3:0] = LAD;        // DATA
      #40 data[7:4] = LAD;
      #20 @(negedge LCLK);        // TAR
      #80;
    end
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
      $display("Write failed, expected %2h, got %2h", expected_data, periph_data);

    // Perform write with delay
    delay = 10;
    expected_data = 8'h42;
    $display("Performing TPM write with delay");
    tpm_write (16'h9C39, expected_data);
    if (periph_data != expected_data)
      $display("Write failed, expected %2h, got %2h", expected_data, periph_data);

    // Perform read with delay
    periph_data = 8'hA5;
    $display("Performing TPM read with delay");
    tpm_read (16'hFF00, expected_data);
    if (periph_data != expected_data)
      $display("Read failed, expected %2h, got %2h", periph_data, expected_data);

    // Perform read without delay
    delay = 0;
    periph_data = 8'h7E;
    $display("Performing TPM read w/o delay");
    tpm_read (16'hFF00, expected_data);
    if (periph_data != expected_data)
      $display("Read failed, expected %2h, got %2h", periph_data, expected_data);

    // TODO: test reset signal
    // TODO: test other cycle types and start nibbles
    // TODO: test extended LFRAME# timings (with changing LAD)

    #100;
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

  always @(negedge LRESET) begin
    if (expect_reset == 0)
      $display("Unexpected LRESET deassertion @ %t", $realtime);
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
