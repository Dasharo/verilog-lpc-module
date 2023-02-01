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

module lpc_periph (
    clk_i,
    nrst_i,
    lframe_i,
    lad_bus,
    prev_state_o,
    lpc_addr_o
);
  // verilog_format: off  // verible-verilog-format messes up comments alignment
  // LPC interface
  input  wire        clk_i;        // LPC clock
  input  wire        nrst_i;       // LPC reset (active low)
  input  wire        lframe_i;     // LPC frame input (active low)
  inout  wire [ 3:0] lad_bus;      // LPC data bus

  // Helper signals
  output reg  [ 4:0] prev_state_o; // Previous peripheral state (FSM)
  inout  wire [ 7:0] lpc_data_io;  // Data received (I/O Write) or to be sent (I/O Read) to host
  output wire [15:0] lpc_addr_o;   // 16-bit LPC Peripheral Address

  // Internal signals
  reg  [15:0] lpc_addr_o_reg;      // 16-bit internal LPC address register

  reg   [4:0] fsm_next_state;      // State: next state of FSM

  // verilog_format: on

  assign lpc_addr_o = lpc_addr_o_reg;

  always @(negedge clk_i or negedge nrst_i or posedge lframe_i) begin
    if (~nrst_i) begin
      prev_state_o <= `LPC_ST_IDLE;
      // TODO: clear everything, stop driving LAD
    end else begin
      prev_state_o <= fsm_next_state;
    end
  end

  always @(posedge clk_i) begin
    if (nrst_i == 1'b0) fsm_next_state <= `LPC_ST_IDLE;
    if (lframe_i == 1'b0) fsm_next_state <= `LPC_ST_IDLE;
    case (prev_state_o)
      `LPC_ST_IDLE: begin
        if ((lframe_i == 1'b0) && (lad_bus == `LPC_START)) fsm_next_state <= `LPC_ST_START;
        else fsm_next_state <= `LPC_ST_IDLE;
      end
      `LPC_ST_START: begin
        if ((lframe_i == 1'b0) && (lad_bus == `LPC_START)) fsm_next_state <= `LPC_ST_START;
        else if ((lframe_i == 1'b1) && (lad_bus == `LPC_IO_READ))
          fsm_next_state <= `LPC_ST_CYCTYPE_RD;
        else if ((lframe_i == 1'b1) && (lad_bus == `LPC_IO_WRITE))
          fsm_next_state <= `LPC_ST_CYCTYPE_WR;
        else fsm_next_state <= `LPC_ST_IDLE;
      end
      // Read
      `LPC_ST_CYCTYPE_RD:     fsm_next_state <= `LPC_ST_ADDR_RD_CLK1;
      `LPC_ST_ADDR_RD_CLK1:   fsm_next_state <= `LPC_ST_ADDR_RD_CLK2;
      `LPC_ST_ADDR_RD_CLK2:   fsm_next_state <= `LPC_ST_ADDR_RD_CLK3;
      `LPC_ST_ADDR_RD_CLK3:   fsm_next_state <= `LPC_ST_ADDR_RD_CLK4;
      `LPC_ST_ADDR_RD_CLK4:   fsm_next_state <= `LPC_ST_TAR_RD_CLK1;
      `LPC_ST_TAR_RD_CLK1:    fsm_next_state <= `LPC_ST_TAR_RD_CLK2;
      `LPC_ST_TAR_RD_CLK2:    fsm_next_state <= `LPC_ST_SYNC_RD;
      `LPC_ST_SYNC_RD:        fsm_next_state <= `LPC_ST_DATA_RD_CLK1;
      `LPC_ST_DATA_RD_CLK1:   fsm_next_state <= `LPC_ST_DATA_RD_CLK2;
      `LPC_ST_DATA_RD_CLK2:   fsm_next_state <= `LPC_ST_FINAL_TAR_CLK1;
      // Write
      `LPC_ST_CYCTYPE_WR:     fsm_next_state <= `LPC_ST_ADDR_WR_CLK1;
      `LPC_ST_ADDR_WR_CLK1:   fsm_next_state <= `LPC_ST_ADDR_WR_CLK2;
      `LPC_ST_ADDR_WR_CLK2:   fsm_next_state <= `LPC_ST_ADDR_WR_CLK3;
      `LPC_ST_ADDR_WR_CLK3:   fsm_next_state <= `LPC_ST_ADDR_WR_CLK4;
      `LPC_ST_ADDR_WR_CLK4:   fsm_next_state <= `LPC_ST_DATA_WR_CLK1;
      `LPC_ST_DATA_WR_CLK1:   fsm_next_state <= `LPC_ST_DATA_WR_CLK2;
      `LPC_ST_DATA_WR_CLK2:   fsm_next_state <= `LPC_ST_TAR_WR_CLK1;
      `LPC_ST_TAR_WR_CLK1:    fsm_next_state <= `LPC_ST_TAR_WR_CLK2;
      `LPC_ST_TAR_WR_CLK2:    fsm_next_state <= `LPC_ST_SYNC_WR;
      `LPC_ST_SYNC_WR:        fsm_next_state <= `LPC_ST_FINAL_TAR_CLK1;
      `LPC_ST_FINAL_TAR_CLK1: fsm_next_state <= `LPC_ST_FINAL_TAR_CLK2;
      default:                fsm_next_state <= `LPC_ST_IDLE;
    endcase
  end

  /*
     * All LAD driving by peripheral should begin at negedge clk_i, because of
     * that states are shifted backwards by one.
     */
  // SYNC
  assign lad_bus = (prev_state_o == `LPC_ST_TAR_WR_CLK2 ||
                    prev_state_o == `LPC_ST_TAR_RD_CLK2) ? 4'b0000 : 4'bzzzz;
  // TAR
  assign lad_bus = (prev_state_o == `LPC_ST_SYNC_WR ||
                    prev_state_o == `LPC_ST_DATA_RD_CLK2) ? 4'b1111 : 4'bzzzz;
  assign lad_bus = (prev_state_o == `LPC_ST_SYNC_RD) ? lpc_data_io[3:0] : 4'bzzzz;
  assign lad_bus = (prev_state_o == `LPC_ST_DATA_RD_CLK1) ? lpc_data_io[7:4] : 4'bzzzz;

endmodule
