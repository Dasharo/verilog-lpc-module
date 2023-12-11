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
    serirq,
    lpc_data_i,
    lpc_data_o,
    lpc_addr_o,
    lpc_data_wr,
    lpc_wr_done,
    lpc_data_rd,
    lpc_data_req,
    irq_num,
    interrupt
);
  // verilog_format: off  // verible-verilog-format messes up comments alignment
  //# {{LPC interface}}
  input  wire        clk_i;        // LPC clock
  input  wire        nrst_i;       // LPC reset (active low)
  input  wire        lframe_i;     // LPC frame input (active low)
  inout  wire [ 3:0] lad_bus;      // LPC data bus
  inout  wire        serirq;       // LPC SERIRQ signal

  //# {{Interface to data provider}}
  input  wire [ 7:0] lpc_data_i;   // Data to be sent (I/O Read) to host
  output reg  [ 7:0] lpc_data_o;   // Data received (I/O Write) from host
  output reg  [15:0] lpc_addr_o;   // 16-bit LPC Peripheral Address
  output             lpc_data_wr;  // Signal to data provider that lpc_data_o has valid write data
  input  wire        lpc_wr_done;  // Signal from data provider that lpc_data_o has been read
  input  wire        lpc_data_rd;  // Signal from data provider that lpc_data_i has data for read
  output             lpc_data_req; // Signal to data provider that is requested (@posedge) or
                                   // has been read (@negedge) from lpc_data_i
  input  wire [ 3:0] irq_num;      // IRQ number, copy of TPM_INT_VECTOR_x.sirqVec
  input  wire        interrupt;    // Whether interrupt should be signaled to host, active high

  // Internal signals
  reg [ 4:0] prev_state_o = `LPC_ST_IDLE;         // Previous peripheral state (FSM)
  reg [ 4:0] fsm_next_state;       // State: next state of FSM
  reg [ 7:0] lpc_data_reg = 0;     // Copy of lpc_data_i data (data provider -> LPC)
  reg        lpc_data_wr = 1'b0;
  reg        waiting_on_write = 0; // Same as above, but driven on complementary edge
  reg        lpc_data_req = 0;     // LPC interface is waiting for data sent from data provider
  reg [ 3:0] irq_num_reg = 0;      // IRQ number, latched on SERIRQ start frame
  reg        serirq_count_en = 0;  // Are we between SERIRQ start (exclusive) and stop (inclusive)?
  reg        serirq_reg = 1;       // Value driven on SERIRQ, if enabled
  reg        driving_serirq = 0;   // Enable signal for driving SERIRQ by LPC module
  reg        serirq_mode = 0;      // SERIRQ mode: Continuous (0) or Quiet (1)
  reg [ 3:0] lad_r = 0;
  reg        driving_lad = 0;

  // verilog_format: on

  always @* begin
    fsm_next_state = prev_state_o;

    case (prev_state_o)
      `LPC_ST_IDLE: begin
          if ((lframe_i == 1'b0) && (lad_bus == `LPC_START))
            fsm_next_state = `LPC_ST_START;
        end
        `LPC_ST_START: begin
          if ((lframe_i == 1'b0) && (lad_bus == `LPC_START)) fsm_next_state = `LPC_ST_START;
          else if ((lframe_i == 1'b1) && (lad_bus == `LPC_IO_READ))
            fsm_next_state = `LPC_ST_ADDR_RD_CLK1;
          else if ((lframe_i == 1'b1) && (lad_bus == `LPC_IO_WRITE))
            fsm_next_state = `LPC_ST_CYCTYPE_WR;
          else fsm_next_state = `LPC_ST_IDLE;
        end
        // Read
        `LPC_ST_ADDR_RD_CLK1: fsm_next_state = `LPC_ST_ADDR_RD_CLK2;
        `LPC_ST_ADDR_RD_CLK2: fsm_next_state = `LPC_ST_ADDR_RD_CLK3;
        `LPC_ST_ADDR_RD_CLK3: fsm_next_state = `LPC_ST_ADDR_RD_CLK4;
        `LPC_ST_ADDR_RD_CLK4: fsm_next_state = `LPC_ST_TAR_RD_CLK1;
        `LPC_ST_TAR_RD_CLK1:  fsm_next_state = `LPC_ST_TAR_RD_CLK2;
        `LPC_ST_TAR_RD_CLK2:  fsm_next_state = `LPC_ST_SYNC_RD;
        `LPC_ST_SYNC_RD: begin
          if (lpc_data_rd == 1'b1)
            fsm_next_state = `LPC_ST_DATA_RD_CLK1;
        end
        `LPC_ST_DATA_RD_CLK1: fsm_next_state = `LPC_ST_DATA_RD_CLK2;
        `LPC_ST_DATA_RD_CLK2: fsm_next_state = `LPC_ST_FINAL_TAR_CLK1;
        `LPC_ST_FINAL_TAR_CLK1: fsm_next_state = `LPC_ST_FINAL_TAR_CLK2;
        `LPC_ST_FINAL_TAR_CLK2: fsm_next_state = `LPC_ST_IDLE;
    endcase
  end

  always @(negedge clk_i) begin
      prev_state_o <= fsm_next_state;

      case (fsm_next_state)
        `LPC_ST_ADDR_RD_CLK1: lpc_addr_o[15:12] <= lad_bus;
        `LPC_ST_ADDR_RD_CLK2: lpc_addr_o[11:8]  <= lad_bus;
        `LPC_ST_ADDR_RD_CLK3: lpc_addr_o[7:4]   <= lad_bus;
        `LPC_ST_ADDR_RD_CLK4: lpc_addr_o[3:0]   <= lad_bus;
      endcase
  end

  always @(posedge clk_i) begin
    driving_lad <= 1'b0;
    lpc_data_req <= 1'b0;

    case (prev_state_o)
      `LPC_ST_TAR_RD_CLK2: lpc_data_req <= 1'b1;
      `LPC_ST_SYNC_RD: begin
        if (lpc_data_rd == 1'b1) begin
          lad_r <= `LPC_SYNC_READY;
          lpc_data_reg <= lpc_data_i;
        end else begin
          lpc_data_req <= 1'b1;
          lad_r <= `LPC_SYNC_LWAIT;
        end

        driving_lad <= 1'b1;
      end
      `LPC_ST_DATA_RD_CLK1: begin
        lad_r <= lpc_data_reg[3:0];
        driving_lad <= 1'b1;
      end
      `LPC_ST_DATA_RD_CLK2: begin
        lad_r <= lpc_data_reg[7:4];
        driving_lad <= 1'b1;
      end
      `LPC_ST_FINAL_TAR_CLK1: begin
        lad_r <= 4'b1111;
        driving_lad <= 1'b1;
      end
    endcase
  end

  assign lad_bus = driving_lad ? lad_r : 4'bzzzz;

  assign serirq = driving_serirq ? serirq_reg : 1'bz;
endmodule
