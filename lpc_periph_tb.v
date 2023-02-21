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

  task lpc_addr (input [15:0] addr);
    begin
      @(negedge LCLK) LAD_reg = addr[15:12];  // ADDR
      @(negedge LCLK) LAD_reg = addr[11:8];
      @(negedge LCLK) LAD_reg = addr[7:4];
      @(negedge LCLK) LAD_reg = addr[3:0];
    end
  endtask

  task lpc_tar_h2p_sync (input rsp_expected);
    begin
      @(negedge LCLK) LAD_reg = 4'hF;         // TAR1
      @(negedge LCLK) drive_lad = 0;
      @(posedge LCLK) if (LAD !== 4'hz)       // TAR2
        $display("### LAD driven on TAR2 @ %t", $realtime);
      // Forked threads would hit previous posedge, skip it manually
      @(negedge LCLK);
      fork : fs                               // SYNC
        begin
          @(posedge LCLK) begin
            if (LRESET && rsp_expected) begin
              if (LAD !== `LPC_SYNC_READY && LAD !== `LPC_SYNC_LWAIT)
                $display("### Unexpected LAD on SYNC (%b) @ %t", LAD, $realtime);
            end else if (LRESET == 0 && LAD !== 4'hz)
              $display("### LAD driven during reset on SYNC (%b) @ %t", LAD, $realtime);
            else if (rsp_expected == 0 && LAD !== 4'hz)
              $display("### LAD driven for bad START/CYCDIR on SYNC (%b) @ %t", LAD, $realtime);
            else if (rsp_expected == 0 && LAD === 4'hz)
              disable fs;
          end
        end
        begin
          @(posedge LCLK && LAD === `LPC_SYNC_READY && LRESET && rsp_expected) disable fs;
        end
      join
    end
  endtask

  task lpc_tar_p2h (input rsp_expected);
    begin
      @(posedge LCLK)                         // TAR1
      if (LRESET == 0 && LAD !== 4'hz)
        $display("### LAD driven on TAR1 during reset (%b) @ %t", LAD, $realtime);
      else if (rsp_expected == 0 && LAD !== 4'hz)
        $display("### LAD driven on TAR1 for bad START/CYCDIR (%b) @ %t", LAD, $realtime);
      else if (LRESET && rsp_expected && LAD === 4'hz)
        $display("### LAD not driven on TAR1 @ %t", $realtime);
      else if (LRESET && rsp_expected && LAD !== 4'hF)
        $display("### Unexpected LAD on TAR1 (%b) @ %t", LAD, $realtime);
      @(posedge LCLK)                         // TAR2
      if (LRESET == 1 && LAD !== 4'hz)
        $display("### LAD driven on TAR2 @ %t", $realtime);
      // Task should end on negedge, but because it also starts on negedge we end after posedge
      // here to make back-to-back invocations possible
    end
  endtask

  task lpc_data_read (input rsp_expected, output [3:0] data);
    begin
      @(posedge LCLK)                         // DATA
      if ((LAD[0] === 1'bx || LAD[1] === 1'bx || LAD[2] === 1'bx || LAD[3] === 1'bx ||
           LAD[0] === 1'bz || LAD[1] === 1'bz || LAD[2] === 1'bz || LAD[3] === 1'bz) &&
          LRESET && rsp_expected)
        $display("### Unexpected LAD on DATA (%b) @ %t", LAD, $realtime);
      else if (LRESET == 0 && LAD !== 4'hz)
        $display("### LAD driven on DATA during reset (%b) @ %t", LAD, $realtime);
      else if (rsp_expected == 0 && LAD !== 4'hz)
        $display("### LAD driven on DATA for bad START/CYCDIR (%b) @ %t", LAD, $realtime);
      else data = LAD;
    end
  endtask

  task lpc_write (input [3:0] start, input [3:0] cycdir, input [15:0] addr, input [7:0] data);
    reg rsp_expected;
    begin
      @(negedge LCLK);
      drive_lad = 1;
      LFRAME = 0;
      LAD_reg = start;                          // START
      @(posedge LCLK)
        if ((LAD === `LPC_START) && (cycdir === `LPC_IO_WRITE))
          rsp_expected = 1;
        else
          rsp_expected = 0;
      @(negedge LCLK) LFRAME = 1;
      LAD_reg = cycdir;                         // CYCTYPE + DIR
      lpc_addr (addr);                          // ADDR
      @(negedge LCLK) LAD_reg = data[7:4];      // DATA
      @(negedge LCLK) LAD_reg = data[3:0];
      lpc_tar_h2p_sync (rsp_expected);          // TAR, SYNC
      lpc_tar_p2h (rsp_expected);               // TAR
    end
  endtask

  task lpc_read (input [3:0] start, input [3:0] cycdir, input [15:0] addr, output [7:0] data);
    reg rsp_expected;
    begin
      @(negedge LCLK);
      drive_lad = 1;
      LFRAME = 0;
      LAD_reg = start;                          // START
      @(posedge LCLK)
        if ((LAD === `LPC_START) && (cycdir === `LPC_IO_READ))
          rsp_expected = 1;
        else
          rsp_expected = 0;
      @(negedge LCLK) LFRAME = 1;
      LAD_reg = cycdir;                         // CYCTYPE + DIR
      lpc_addr (addr);                          // ADDR
      lpc_tar_h2p_sync (rsp_expected);          // TAR, SYNC
      lpc_data_read (rsp_expected, data[3:0]);  // DATA1
      lpc_data_read (rsp_expected, data[7:4]);  // DATA2
      lpc_tar_p2h (rsp_expected);               // TAR
    end
  endtask

  task tpm_write (input [15:0] addr, input [7:0] data);
    lpc_write (`LPC_START, `LPC_IO_WRITE, addr, data);
  endtask

  task tpm_read (input [15:0] addr, output [7:0] data);
    lpc_read (`LPC_START, `LPC_IO_READ, addr, data);
  endtask

  task lpc_abort_after_n_cycles (input integer n);
    begin
      repeat(n+1) @(negedge LCLK);
      LFRAME = 0;
      //
      // From specification:
      //
      // "To ensure that the abort will be seen, the host must keep LFRAME# active for at least
      // four consecutive clocks and drive LAD[3:0] to ‘1111b’ no later than the 4th clock after
      // LFRAME# goes active." - 3 clocks here, one later.
      //
      repeat(3) @(negedge LCLK);
      LAD_reg = `LPC_STOP;
      drive_lad = 1;
      @(negedge LCLK);
      // "The host must drive LFRAME# inactive (high) for at least 1 clock after an abort."
      LFRAME = 1;
      drive_lad = 0;
      // Test LAD after signal is stable. Note that final cycle is enforced by next lpc_{read,write}
      #1 if (LAD !== 4'hz)
        $display("### Device drives LAD after abort cycle @ %t", $realtime - 1);
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
          @(negedge LCLK);  // tpm_write ends on posedge
          // Order of execution between two forked branches is undefined so delay by one timestep
          #1 $display("### Write completed but it shouldn't @ %t", $realtime);
          disable rw;
        end
        begin
          @(negedge LCLK);  // tpm_write starts at negedge, so should we
          #i LRESET <= 0;
          #(((timeout + delay) * 40) - i);
          disable rw;
        end
      join
      LRESET <= 1;
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
          @(negedge LCLK);  // tpm_read ends on posedge
          // Order of execution between two forked branches is undefined so delay by one timestep
          #1 $display("### Read completed but it shouldn't @ %t", $realtime);
          disable rr;
        end
        begin
          @(negedge LCLK);  // tpm_read starts at negedge, so should we
          #i LRESET <= 0;
          #(((timeout + delay) * 40) - i);
          disable rr;
        end
      join
      LRESET <= 1;
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
          @(negedge LCLK);  // tpm_write ends on posedge
          // Order of execution between two forked branches is undefined so delay by one timestep
          #1 $display("### Write completed but it shouldn't @ %t", $realtime - 1);
          disable rwd;
        end
        begin
          @(negedge LCLK);  // tpm_write starts at negedge, so should we
          #i LRESET <= 0;
          #(((timeout + delay) * 40) - i);
          disable rwd;
        end
      join
      LRESET <= 1;
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
          @(negedge LCLK);  // tpm_read ends on posedge
          // Order of execution between two forked branches is undefined so delay by one timestep
          #1 $display("### Read completed but it shouldn't @ %t", $realtime);
          disable rrd;
        end
        begin
          @(negedge LCLK);  // tpm_write starts at negedge, so should we
          #i LRESET <= 0;
          #(((timeout + delay) * 40) - i);
          disable rrd;
        end
      join
      LRESET <= 1;
      #40;
    end

    expect_reset = 0;
    delay = 0;
    #1000

    $display("Testing non-TPM transactions");

    periph_data   = 8'h66;
    expected_data = 8'h99;
    lpc_read (4'h0, `LPC_IO_READ, 16'hF36C, expected_data);
    if (periph_data !== 8'h66 || expected_data != 8'hzz)
      $display("### Non-TPM read returned data");
    #40;

    periph_data   = 8'hAA;
    expected_data = 8'hCC;
    lpc_read (`LPC_START, 4'b0101, 16'hF36C, expected_data);
    if (periph_data !== 8'hAA || expected_data != 8'hzz)
      $display("### TPM non-read returned data");
    #40;

    periph_data   = 8'h33;
    expected_data = 8'h99;
    lpc_write (4'h0, `LPC_IO_WRITE, 16'hF36C, expected_data);
    if (periph_data !== 8'h33)
      $display("### Non-TPM write finished");
    #40;

    periph_data   = 8'hAA;
    expected_data = 8'hCC;
    lpc_write (`LPC_START, 4'b0110, 16'hF36C, expected_data);
    if (periph_data !== 8'hAA)
      $display("### TPM non-write finished");
    #40;

    periph_data   = 8'h57;
    expected_data = 8'h75;
    lpc_read (4'h0, 4'b1000, 16'hF36C, expected_data);
    if (periph_data !== 8'h57 || expected_data != 8'hzz)
      $display("### Non-TPM non-read returned data");
    #40;

    periph_data   = 8'hAA;
    expected_data = 8'hCC;
    lpc_write (4'h7, 4'b1110, 16'hF36C, expected_data);
    if (periph_data !== 8'hAA)
      $display("### Non-TPM non-write finished");
    #40;

    $display("Testing extended LFRAME# timings - write");

    // Extended LFRAME# write w/o delay
    LAD_reg = `LPC_START;
    drive_lad = 1;
    LFRAME = 0;
    expected_data = 8'h81;
    #100 tpm_write (16'h3461, expected_data);
    if (periph_data != expected_data)
      $display("### Write failed, expected %2h, got %2h", expected_data, periph_data);

    #40;
    // Extended LFRAME# write with delay
    delay = 17;
    LAD_reg = `LPC_START;
    drive_lad = 1;
    LFRAME = 0;
    expected_data = 8'h79;
    #100 tpm_write (16'h4682, expected_data);
    if (periph_data != expected_data)
      $display("### Write failed, expected %2h, got %2h", expected_data, periph_data);

    #40;
    delay = 0;
    // Extended LFRAME# with changing LAD
    LAD_reg = `LPC_START;
    drive_lad = 1;
    LFRAME = 0;
    expected_data = 8'h48;
    #40 LAD_reg = 4'h1;
    #30 LAD_reg = 4'h3;
    #50 LAD_reg = 4'h7;
    #20 LAD_reg = 4'hF;
    #10 LAD_reg = 4'h3;
    #15 LAD_reg = 4'h1;
    tpm_write (16'h3461, expected_data);
    if (periph_data != expected_data)
      $display("### Write failed, expected %2h, got %2h", expected_data, periph_data);

    #40;
    LAD_reg = 4'h1;
    drive_lad = 1;
    LFRAME = 0;
    expected_data = 8'h48;
    #40 LAD_reg = 4'h1;
    #30 LAD_reg = 4'h3;
    #15 LAD_reg = 4'h7;
    tpm_write (16'h3461, expected_data);
    if (periph_data != expected_data)
      $display("### Write failed, expected %2h, got %2h", expected_data, periph_data);

    #40;
    LAD_reg = 4'h1;
    drive_lad = 1;
    LFRAME = 0;
    expected_data = 8'h94;
    #40 LAD_reg = 4'h1;
    #30 LAD_reg = 4'h3;
    #15 LAD_reg = 4'h7;
    lpc_write (4'hz, `LPC_IO_WRITE, 16'h5474, expected_data);
    if (periph_data == expected_data)
      $display("### Write completed without valid START");

    #40;
    LAD_reg = 4'h1;
    drive_lad = 1;
    LFRAME = 0;
    expected_data = 8'h94;
    #40 LAD_reg = 4'h1;
    #30 LAD_reg = 4'h3;
    #15 LAD_reg = 4'h7;
    lpc_write (4'h1, `LPC_IO_WRITE, 16'h7428, expected_data);
    if (periph_data == expected_data)
      $display("### Write completed without valid START");

    #40;
    LAD_reg = 4'h1;
    drive_lad = 1;
    LFRAME = 0;
    expected_data = 8'h94;
    #40 LAD_reg = 4'h1;
    #30 LAD_reg = `LPC_START;
    #55 LAD_reg = 4'h7;
    lpc_write (4'h1, `LPC_IO_WRITE, 16'h5974, expected_data);
    if (periph_data == expected_data)
      $display("### Write completed without valid START");

    // Short but proper LPC_START
    fork
      begin
        @(negedge LCLK);
        #15 LAD_reg = `LPC_START;
        #10 LAD_reg = 4'h7;
      end
      begin
        expected_data = 8'h17;
        lpc_write (4'hz, `LPC_IO_WRITE, 16'h7413, expected_data);
        if (periph_data != expected_data)
          $display("### Write failed, expected %2h, got %2h", expected_data, periph_data);
      end
    join

    // Bad START surrounded by proper LPC_STARTs
    fork
      begin
        @(negedge LCLK);
        #1  LAD_reg = `LPC_START;
        #14 LAD_reg = 4'h3;
        #10 LAD_reg = `LPC_START;
      end
      begin
        expected_data = 8'h59;
        lpc_write (4'hz, `LPC_IO_WRITE, 16'h7413, expected_data);
        if (periph_data == expected_data)
          $display("### Write completed without valid START");
      end
    join

    $display("Testing extended LFRAME# timings - read");

    #40;
    // Extended LFRAME# read with delay
    LAD_reg = `LPC_START;
    drive_lad = 1;
    LFRAME = 0;
    periph_data = 8'h45;
    #100 tpm_read (16'h1337, expected_data);
    if (periph_data != expected_data)
      $display("### Read failed, expected %2h, got %2h", periph_data, expected_data);

    #40;
    // Extended LFRAME# read w/o delay
    delay = 0;
    LAD_reg = `LPC_START;
    drive_lad = 1;
    LFRAME = 0;
    periph_data = 8'h7E;
    #100 tpm_read (16'h7331, expected_data);
    if (periph_data != expected_data)
      $display("### Read failed, expected %2h, got %2h", periph_data, expected_data);

    #40;
    delay = 0;
    // Extended LFRAME# with changing LAD
    LAD_reg = `LPC_START;
    drive_lad = 1;
    LFRAME = 0;
    expected_data = 8'h48;
    #40 LAD_reg = 4'h1;
    #30 LAD_reg = 4'h3;
    #50 LAD_reg = 4'h7;
    #20 LAD_reg = 4'hF;
    #10 LAD_reg = 4'h3;
    #15 LAD_reg = 4'h1;
    periph_data = 8'h7E;
    tpm_read (16'h7331, expected_data);
    if (periph_data != expected_data)
      $display("### Read failed, expected %2h, got %2h", periph_data, expected_data);

    #40;
    LAD_reg = 4'h1;
    drive_lad = 1;
    LFRAME = 0;
    expected_data = 8'h48;
    #40 LAD_reg = 4'h1;
    #30 LAD_reg = 4'h3;
    #15 LAD_reg = 4'h7;
    periph_data = 8'h7E;
    tpm_read (16'h7331, expected_data);
    if (periph_data != expected_data)
      $display("### Read failed, expected %2h, got %2h", periph_data, expected_data);

    #40;
    LAD_reg = 4'h1;
    drive_lad = 1;
    LFRAME = 0;
    expected_data = 8'h94;
    #40 LAD_reg = 4'h1;
    #30 LAD_reg = 4'h3;
    #15 LAD_reg = 4'h7;
    periph_data = 8'h3E;
    lpc_read (4'hz, `LPC_IO_READ, 16'h7331, expected_data);
    if (periph_data == expected_data)
      $display("### Read completed without valid START");

    #40;
    LAD_reg = 4'h1;
    drive_lad = 1;
    LFRAME = 0;
    expected_data = 8'h94;
    #40 LAD_reg = 4'h1;
    #30 LAD_reg = 4'h3;
    #15 LAD_reg = 4'h7;
    periph_data = 8'h34;
    lpc_read (4'h3, `LPC_IO_READ, 16'h7428, expected_data);
    if (periph_data == expected_data)
      $display("### Read completed without valid START");

    #40;
    LAD_reg = 4'h1;
    drive_lad = 1;
    LFRAME = 0;
    expected_data = 8'h94;
    #40 LAD_reg = 4'h1;
    #30 LAD_reg = `LPC_START;
    #55 LAD_reg = 4'h7;
    periph_data = 8'h82;
    lpc_read (4'hz, `LPC_IO_READ, 16'h7157, expected_data);
    if (periph_data == expected_data)
      $display("### Read completed without valid START");

    // Short but proper LPC_START
    fork
      begin
        @(negedge LCLK);
        #15 LAD_reg = `LPC_START;
        #10 LAD_reg = 4'h7;
      end
      begin
        expected_data = 8'h17;
        periph_data = 8'h9F;
        lpc_read (4'hz, `LPC_IO_READ, 16'h7431, expected_data);
        if (periph_data != expected_data)
          $display("### Read failed, expected %2h, got %2h", periph_data, expected_data);
      end
    join

    // Bad START surrounded by proper LPC_STARTs
    fork
      begin
        @(negedge LCLK);
        #1  LAD_reg = `LPC_START;
        #14 LAD_reg = 4'h3;
        #10 LAD_reg = `LPC_START;
      end
      begin
        expected_data = 8'h59;
        periph_data = 8'h76;
        lpc_read (4'hz, `LPC_IO_READ, 16'h7331, expected_data);
        if (periph_data == expected_data)
          $display("### Read completed without valid START");
        end
    join

    #500;
    //
    // Abort mechanism - excerpt from specification:
    //
    // "An abort will typically occur on SYNC time-outs (when a peripheral is driving SYNC longer
    // than allowed), on cycles where there is no response (which will occur if the host is
    // programmed incorrectly), or if a device drives a reserved SYNC value."
    //
    // Reserved SYNC value should be caught by lpc_{read,write}, so only two cases are left. Both
    // of them occur at the same point in transmission - during SYNC. For write this starts after
    // 10th cycle, for read - 8th cycle, and continues for 'delay' cycles.
    //
    $display("Testing abort mechanism - write");
    delay = 10;
    fork : abort1
      begin
        lpc_abort_after_n_cycles (12);
        disable abort1;
      end
      begin
        expected_data = 8'h75;
        tpm_write (16'h130F, expected_data);
        // 'disable abort1' above should happen before lpc_write finishes
        $display("### Write not aborted @ %t", $realtime);
      end
    join
    // Device should be able to accept next command immediately
    delay = 0;
    expected_data = 8'h92;
    tpm_write (16'h8278, expected_data);
    if (periph_data != expected_data)
      $display("### Write failed, expected %2h, got %2h", expected_data, periph_data);


    // Same as before, but for non-TPM cycle (covers "no response" case)
    delay = 10;
    fork : abort2
      begin
        lpc_abort_after_n_cycles (12);
        disable abort2;
      end
      begin
        expected_data = 8'h50;
        lpc_write (4'h0, `LPC_IO_WRITE, 16'h0F38, expected_data);
        // Due to 'rsp_expected' lpc_write finishes earlier than for TPM cycle, add delay here
        #(delay * 40) $display("### Write not aborted @ %t", $realtime);
      end
    join
    delay = 0;
    expected_data = 8'h2B;
    tpm_write (16'h78CE, expected_data);
    if (periph_data != expected_data)
      $display("### Write failed, expected %2h, got %2h", expected_data, periph_data);

    #50;

    $display("Testing abort mechanism - read");
    delay = 10;
    fork : abort3
      begin
        lpc_abort_after_n_cycles (10);
        disable abort3;
      end
      begin
        periph_data = 8'hCA;
        tpm_read (16'hFFAD, expected_data);
        // 'disable abort1' above should happen before lpc_read finishes
        $display("### Read not aborted @ %t", $realtime);
      end
    join
    // Device should be able to accept next command immediately
    delay = 0;
    periph_data = 8'hAC;
    tpm_read (16'h00DB, expected_data);
    if (periph_data != expected_data)
      $display("### Read failed, expected %2h, got %2h", periph_data, expected_data);


    // Same as before, but for non-TPM cycle (covers "no response" case)
    delay = 10;
    fork : abort4
      begin
        lpc_abort_after_n_cycles (10);
        disable abort4;
      end
      begin
        periph_data = 8'hFE;
        lpc_read (4'h0, `LPC_IO_READ, 16'h38A5, expected_data);
        // Due to 'rsp_expected' lpc_read finishes earlier than for TPM cycle, add delay here
        #(delay * 40) $display("### Read not aborted @ %t", $realtime);
      end
    join
    delay = 0;
    periph_data = 8'hB2;
    tpm_read (16'hDB30, expected_data);
    if (periph_data != expected_data)
      $display("### Read failed, expected %2h, got %2h", periph_data, expected_data);

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
      // lpc_data_wr is signalled on negedge between DATA2 and TAR1, so we should add 2 cycles.
      // lpc_wr_done is detected on negedge, during which final SYNC begins being driven, so we
      // subtract 1 cycle, which gives total of +1 cycle.
      if (cur_delay > delay + 1) begin
        periph_data = lpc_data_io;
        cur_delay = 0;
        lpc_wr_done = 1;
      end
    end else if (lpc_data_req == 0 && lpc_data_wr == 0) begin
      lpc_wr_done = 0;
      cur_delay = 0;
    end

    if (lpc_data_req == 1) begin
      cur_delay = cur_delay + 1;
      // lpc_data_req is signalled on negedge between ADDR4 and TAR1, so we should add 2 cycles.
      // lpc_data_rd is detected on negedge, during which final SYNC begins being driven, so we
      // subtract 1 cycle, which gives total of +1 cycle.
      if (cur_delay > delay + 1) begin
        cur_delay = 0;
        lpc_data_rd = 1;
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

  always @(LAD, lpc_data_io) begin : multidrive_test
    reg [3:0] old_LAD;
    realtime t;
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
          $display("### Multiple LAD drivers (%b -> %b) @ %t", old_LAD, LAD, t);
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
