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
  reg         rd_flag;  // indicates that this is read cycle
  reg         wr_flag;  // indicates that this is write cycle
  reg         clk_i;    // input clock
  reg         nrst_i;   // asynchronous reset - active Low
  reg         lframe_i; // active low signal indicating new LPC frame
  reg  [15:0] host_addr_i = 16'h0000; // LPC host address to input to the LPC host
  reg  [ 7:0] host_wr_i = 8'h00;
  reg  [ 7:0] periph_data_i = 8'h00;

  wire  [7:0] host_data_o;
  wire        host_ready;    // indicates that host is ready for next cycle

  wire  [4:0] current_host_state;    // status: current host state

  wire        LCLK;           // Host LPC output clock
  wire        LRESET;         // Host LReset
  wire        LFRAME;         // Host LFRAME
  wire  [3:0] LAD = 4'bZZZZ;  // Bi-directional (tri-state) LPC bus (multiplexed address and data 4-bit chunks)

  wire [ 7:0] lpc_data_io;    // Data received (I/O Write) or to be sent (I/O Read) to host
  wire [15:0] lpc_addr_o;     // 16-bit LPC Peripheral Address
  wire        lpc_data_wr;    // Signal to data provider that lpc_data_io has valid write data
  reg         lpc_wr_done;    // Signal from data provider that lpc_data_io has been read
  reg         lpc_data_rd;    // Signal from data provider that lpc_data_io has data for read
  wire        lpc_data_req;   // Signal to data provider that is requested (@posedge) or
                              // has been read (@negedge)

  reg  [15:0] u_addr;         // auxiliary host address
  reg   [7:0] u_data;         // auxiliary host data
  integer i, j, cur_delay, delay;
  reg memory_cycle_sig;
  reg drive_lpc_data = 0;
  reg expect_reset = 1;

  // verilog_format: on

  initial begin
    clk_i = 1'b1;
    forever #20 clk_i = ~clk_i;
  end

  initial begin
    // Initialize
    $dumpfile("lpc_periph_tb.vcd");
    $dumpvars(0, lpc_periph_tb);
    $timeformat(-9, 0, " ns", 10);

    lframe_i    = 1;
    nrst_i      = 1;
    rd_flag     = 0;
    wr_flag     = 1;
    lpc_wr_done = 0;
    lpc_data_rd = 0;
    delay       = 0;
    #40 nrst_i  = 0;
    #250 nrst_i = 1;

    expect_reset = 0;

    memory_cycle_sig = 0;

    // Perform write
    #40 lframe_i = 0;
    $display("Performing write w/o delay");
    host_addr_i  = 16'hF0F0;
    host_wr_i    = 8'h5A;
    #40 lframe_i = 1;

    // Perform write with delay
    #600 delay   = 10;
    #40 lframe_i = 0;
    $display("Performing write with delay");
    host_addr_i  = 16'h9696;
    host_wr_i    = 8'hA5;
    #40 lframe_i = 1;

    // Perform read
    #1000 lframe_i = 0;
    $display("Performing read with delay");
    periph_data_i = 8'hA5;
    rd_flag = 1;
    wr_flag = 0;
    #80 lframe_i = 1;

    #1000 delay   = 0;
    #40 lframe_i  = 0;
    $display("Performing read w/o delay");
    periph_data_i = 8'hA5;
    rd_flag       = 1;
    wr_flag       = 0;
    #80 lframe_i  = 1;

    #1000 nrst_i   = 1;
    u_addr   = 0;
    u_data   = 0;

    nrst_i   = 1;
    rd_flag  = 0;
    wr_flag  = 1;
    expect_reset = 1;
    #40 nrst_i = 0;
    #250 nrst_i = 1;
    expect_reset = 0;

    #600 lframe_i = 1;

    for (i = 0; i <= 8; i = i + 1) begin
      for (j = 0; j < 2; j = j + 1) begin
        memory_cycle_sig = j;  //Cycle type: Memory or I/O
        // Perform write
        #200 lframe_i = 0;
        rd_flag = 0;
        wr_flag = 1;
        host_addr_i = u_addr + i;
        host_wr_i = u_data + i;
        #200 lframe_i = 1;
        #800 lframe_i = 0;

        // Perform read
        #800 lframe_i = 0;
        periph_data_i = 8'hBB + i;
        rd_flag = 1;
        wr_flag = 0;
        #80 lframe_i = 1;

        #250 nrst_i = 1;
        #400 lframe_i = 1;
      end
    end

    #8000;
    //------------------------------
    $stop;
    $finish;
  end

  assign lpc_data_io = lpc_data_rd ? periph_data_i : 8'hzz;

  // Simulate response to read and write requests with optional delay
  always @(posedge clk_i) begin
    if (lpc_data_wr == 1) begin
      cur_delay = cur_delay + 1;
      if (cur_delay > delay) begin
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

  // LPC Host instantiation
  lpc_host lpc_host_inst (
      .clk_i(clk_i),
      // Input from GPIO
      .ctrl_addr_i(host_addr_i),
      .ctrl_data_i(host_wr_i),
      .ctrl_nrst_i(nrst_i),
      .ctrl_lframe_i(lframe_i),
      .ctrl_rd_status_i(rd_flag),
      .ctrl_wr_status_i(wr_flag),
      .ctrl_memory_cycle_i(memory_cycle_sig),
      // Output to GPIO
      .ctrl_data_o(host_data_o),
      .ctrl_ready_o(host_ready),
      // LPC Host Interface
      .LPC_LAD(LAD),
      .LPC_LCLK(LCLK),
      .LPC_LRESET(LRESET),
      .LPC_LFRAME(LFRAME),
      .ctrl_host_state_o(current_host_state)
  );

  // LPC Peripheral instantiation
  lpc_periph lpc_periph_inst (
      // LPC Interface
      .clk_i(LCLK),
      .nrst_i(LRESET),
      .lframe_i(LFRAME),
      .lad_bus(LAD),
      .lpc_data_io(lpc_data_io),
      .lpc_addr_o(lpc_addr_o),
      .lpc_data_wr(lpc_data_wr),
      .lpc_wr_done(lpc_wr_done),
      .lpc_data_rd(lpc_data_rd),
      .lpc_data_req(lpc_data_req)
  );

endmodule
