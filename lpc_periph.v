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
    lpc_data_io,
    lpc_addr_o,
    lpc_data_wr,
    lpc_wr_done,
    lpc_data_rd,
    lpc_data_req
);
  // verilog_format: off  // verible-verilog-format messes up comments alignment
  // LPC interface
  input  wire        clk_i;        // LPC clock
  input  wire        nrst_i;       // LPC reset (active low)
  input  wire        lframe_i;     // LPC frame input (active low)
  inout  wire [ 3:0] lad_bus;      // LPC data bus

  // Interface to data provider
  inout  wire [ 7:0] lpc_data_io;  // Data received (I/O Write) or to be sent (I/O Read) to host
  output wire [15:0] lpc_addr_o;   // 16-bit LPC Peripheral Address
  output wire        lpc_data_wr;  // Signal to data provider that lpc_data_io has valid write data
  input  wire        lpc_wr_done;  // Signal from data provider that lpc_data_io has been read
  input  wire        lpc_data_rd;  // Signal from data provider that lpc_data_io has data for read
  output wire        lpc_data_req; // Signal to data provider that is requested (@posedge) or
                                   // has been read (@negedge)

  // Internal signals
  reg [ 4:0] prev_state_o;         // Previous peripheral state (FSM)
  reg [ 4:0] fsm_next_state;       // State: next state of FSM
  reg [ 7:0] lpc_data_reg_w = 0;   // Copy of lpc_data_io's data (LPC -> data provider)
  reg [ 7:0] lpc_data_reg_r = 0;   // Copy of lpc_data_io's data (data provider -> LPC)
  reg [15:0] lpc_addr_reg = 0;     // Driver of lpc_addr_o
  reg        waiting_on_write = 0;
  reg        waiting_on_read = 0;
  reg        driving_data = 0;

  // verilog_format: on

  always @(negedge nrst_i or negedge clk_i) begin
    if (~nrst_i) begin
      prev_state_o     <= `LPC_ST_IDLE;
      driving_data     <= 1'b0;
      waiting_on_write <= 1'b0;
      waiting_on_read  <= 1'b0;
      // TODO: clear everything, stop driving LAD
    end else begin
      case (fsm_next_state)
        `LPC_ST_IDLE: begin
          waiting_on_write <= 1'b0;
          waiting_on_read  <= 1'b0;
          prev_state_o     <= fsm_next_state;
        end
        // Read
        `LPC_ST_ADDR_RD_CLK4: begin
          waiting_on_read  <= 1'b1;
          prev_state_o     <= fsm_next_state;
        end
        `LPC_ST_TAR_RD_CLK2: begin
          // Avoid sync wait if it isn't required
          if (lpc_data_rd == 1'b1) begin
            lpc_data_reg_r  <= lpc_data_io;
            waiting_on_read <= 1'b0;
          end
          prev_state_o <= fsm_next_state;
        end
        `LPC_ST_SYNC_RD: begin
          // FIXME: testbench shows x's in LAD exactly at this point, maybe use Gray codes for FSM?
          if (lpc_data_rd == 1'b1) begin
            lpc_data_reg_r   <= lpc_data_io;
            waiting_on_read  <= 1'b0;
          end
          if (waiting_on_read == 1'b0) prev_state_o <= fsm_next_state;
        end
        // Write
        `LPC_ST_DATA_WR_CLK2: begin
          waiting_on_write <= 1'b1;
          prev_state_o     <= fsm_next_state;
        end
        `LPC_ST_TAR_WR_CLK2: begin
          if (lpc_wr_done == 1'b1) begin
            waiting_on_write <= 1'b0;
          end
          prev_state_o <= fsm_next_state;
        end
        `LPC_ST_SYNC_WR: begin
          if (lpc_wr_done == 1'b1 && driving_data == 1'b0) waiting_on_write <= 1'b0;
          if (waiting_on_write == 1'b0) prev_state_o <= fsm_next_state;
        end
        default: prev_state_o <= fsm_next_state;
      endcase
    end
  end

  always @(posedge clk_i) begin
    if (nrst_i == 1'b0) fsm_next_state <= `LPC_ST_IDLE;
    else begin
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
        `LPC_ST_CYCTYPE_RD: begin
          lpc_addr_reg[15:12] <= lad_bus;
          fsm_next_state      <= `LPC_ST_ADDR_RD_CLK1;
        end
        `LPC_ST_ADDR_RD_CLK1: begin
          lpc_addr_reg[11:8] <= lad_bus;
          fsm_next_state     <= `LPC_ST_ADDR_RD_CLK2;
        end
        `LPC_ST_ADDR_RD_CLK2: begin
          lpc_addr_reg[7:4] <= lad_bus;
          fsm_next_state    <= `LPC_ST_ADDR_RD_CLK3;
        end
        `LPC_ST_ADDR_RD_CLK3: begin
          lpc_addr_reg[3:0] <= lad_bus;
          fsm_next_state    <= `LPC_ST_ADDR_RD_CLK4;
        end
        `LPC_ST_ADDR_RD_CLK4:   fsm_next_state <= `LPC_ST_TAR_RD_CLK1;
        `LPC_ST_TAR_RD_CLK1:    fsm_next_state <= `LPC_ST_TAR_RD_CLK2;
        `LPC_ST_TAR_RD_CLK2: begin
          if (lframe_i == 0) begin
            driving_data  <= 1'b0;
            fsm_next_state  <= `LPC_ST_IDLE;
          end else
            fsm_next_state <= `LPC_ST_SYNC_RD;
        end
        `LPC_ST_SYNC_RD:        fsm_next_state <= `LPC_ST_DATA_RD_CLK1;
        `LPC_ST_DATA_RD_CLK1:   fsm_next_state <= `LPC_ST_DATA_RD_CLK2;
        `LPC_ST_DATA_RD_CLK2:   fsm_next_state <= `LPC_ST_FINAL_TAR_CLK1;
        // Write
        `LPC_ST_CYCTYPE_WR: begin
          lpc_addr_reg[15:12] <= lad_bus;
          fsm_next_state      <= `LPC_ST_ADDR_WR_CLK1;
        end
        `LPC_ST_ADDR_WR_CLK1: begin
          lpc_addr_reg[11:8] <= lad_bus;
          fsm_next_state     <= `LPC_ST_ADDR_WR_CLK2;
        end
        `LPC_ST_ADDR_WR_CLK2: begin
          lpc_addr_reg[7:4] <= lad_bus;
          fsm_next_state    <= `LPC_ST_ADDR_WR_CLK3;
        end
        `LPC_ST_ADDR_WR_CLK3: begin
          lpc_addr_reg[3:0] <= lad_bus;
          fsm_next_state    <= `LPC_ST_ADDR_WR_CLK4;
        end
        `LPC_ST_ADDR_WR_CLK4: begin
          lpc_data_reg_w[7:4] <= lad_bus;
          fsm_next_state      <= `LPC_ST_DATA_WR_CLK1;
        end
        `LPC_ST_DATA_WR_CLK1: begin
          lpc_data_reg_w[3:0] <= lad_bus;
          driving_data        <= 1'b1;
          fsm_next_state      <= `LPC_ST_DATA_WR_CLK2;
        end
        `LPC_ST_DATA_WR_CLK2:   fsm_next_state <= `LPC_ST_TAR_WR_CLK1;
        `LPC_ST_TAR_WR_CLK1: begin
          // Avoid sync wait if it isn't required
          if (lpc_wr_done == 1'b1) begin
            driving_data   <= 1'b0;
          end
          fsm_next_state <= `LPC_ST_TAR_WR_CLK2;
        end
        `LPC_ST_TAR_WR_CLK2: begin
          if (lframe_i == 0) begin
            driving_data   <= 1'b0;
            fsm_next_state <= `LPC_ST_IDLE;
          end else if (lpc_wr_done == 1'b1) begin
            driving_data   <= 1'b0;
            fsm_next_state <= `LPC_ST_SYNC_WR;
          end else
            fsm_next_state <= `LPC_ST_SYNC_WR;
        end
        `LPC_ST_SYNC_WR: begin
          driving_data   <= 1'b0;
          fsm_next_state <= `LPC_ST_FINAL_TAR_CLK1;
        end
        `LPC_ST_FINAL_TAR_CLK1: fsm_next_state <= `LPC_ST_IDLE;
        default:                fsm_next_state <= `LPC_ST_IDLE;
      endcase
    end
  end

  /*
   * All LAD driving by peripheral should begin at negedge clk_i, because of
   * that states are shifted backwards by one.
   */
  // SYNC - either long wait or ready, depending on availability of data
  assign lad_bus = (prev_state_o == `LPC_ST_TAR_WR_CLK2 || prev_state_o == `LPC_ST_TAR_RD_CLK2) ?
                   ((waiting_on_write || waiting_on_read) ? `LPC_SYNC_LWAIT : `LPC_SYNC_READY)
                   : 4'bzzzz;
  // TAR
  assign lad_bus = (prev_state_o == `LPC_ST_SYNC_WR ||
                    prev_state_o == `LPC_ST_DATA_RD_CLK2) ? 4'b1111 : 4'bzzzz;
  assign lad_bus = (prev_state_o == `LPC_ST_SYNC_RD) ? lpc_data_reg_r[3:0] : 4'bzzzz;
  assign lad_bus = (prev_state_o == `LPC_ST_DATA_RD_CLK1) ? lpc_data_reg_r[7:4] : 4'bzzzz;

  assign lpc_addr_o   = lpc_addr_reg;
  assign lpc_data_io  = (driving_data == 1'b1 && waiting_on_write == 1'b1) ? lpc_data_reg_w : 8'hzz;
  assign lpc_data_wr  = waiting_on_write;
  assign lpc_data_req = waiting_on_read;
endmodule
