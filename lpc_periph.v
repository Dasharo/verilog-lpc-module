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
    lpc_data_io,
    lpc_addr_o,
    lpc_data_wr,
    lpc_wr_done,
    lpc_data_rd,
    lpc_data_req,
    irq_num,
    interrupt
);
  // verilog_format: off  // verible-verilog-format messes up comments alignment
  // LPC interface
  input  wire        clk_i;        // LPC clock
  input  wire        nrst_i;       // LPC reset (active low)
  input  wire        lframe_i;     // LPC frame input (active low)
  inout  wire [ 3:0] lad_bus;      // LPC data bus
  inout  wire        serirq;       // LPC SERIRQ signal

  // Interface to data provider
  inout  wire [ 7:0] lpc_data_io;  // Data received (I/O Write) or to be sent (I/O Read) to host
  output wire [15:0] lpc_addr_o;   // 16-bit LPC Peripheral Address
  output wire        lpc_data_wr;  // Signal to data provider that lpc_data_io has valid write data
  input  wire        lpc_wr_done;  // Signal from data provider that lpc_data_io has been read
  input  wire        lpc_data_rd;  // Signal from data provider that lpc_data_io has data for read
  output wire        lpc_data_req; // Signal to data provider that is requested (@posedge) or
                                   // has been read (@negedge)
  input  wire [ 3:0] irq_num;      // IRQ number, copy of TPM_INT_VECTOR_x.sirqVec
  input  wire        interrupt;    // Whether interrupt should be signaled to host, active high

  // Internal signals
  reg [ 4:0] prev_state_o;         // Previous peripheral state (FSM)
  reg [ 4:0] fsm_next_state;       // State: next state of FSM
  reg [ 7:0] lpc_data_reg_w = 0;   // Copy of lpc_data_io's data (LPC -> data provider)
  reg [ 7:0] lpc_data_reg_r = 0;   // Copy of lpc_data_io's data (data provider -> LPC)
  reg [15:0] lpc_addr_reg = 0;     // Driver of lpc_addr_o
  reg        waiting_on_write = 0; // LPC interface is waiting for data to be acked by data provider
  reg        waiting_on_read = 0;  // LPC interface is waiting for data sent from data provider
  reg        driving_data = 0;     // Data on interface to data provider is driven by LPC module
  reg [ 3:0] irq_num_reg = 0;      // IRQ number, latched on SERIRQ start frame
  reg        serirq_count_en = 0;  // Are we between SERIRQ start (exclusive) and stop (inclusive)?
  reg        serirq_reg = 1;       // Value driven on SERIRQ, if enabled
  reg        driving_serirq = 0;   // Enable signal for driving SERIRQ by LPC module
  reg        serirq_mode = 0;      // SERIRQ mode: Continuous (0) or Quiet (1)

  // verilog_format: on

  always @(negedge nrst_i or posedge clk_i) begin : serirq_drive
    integer    serirq_counter;
    if (~nrst_i) begin
      serirq_counter <= 0;
      serirq_reg     <= 1;
      driving_serirq <= 0;
    end else begin
      // Even if full SERIRQ is used (32 frames, 3 clocks each), TPM will never need to use anything
      // after IRQ15, which ends after 47th clock. Leaving few cycles extra to catch any off-by-one
      // errors in simulation more easily.
      if (serirq_count_en && serirq_counter < 50)
        serirq_counter <= serirq_counter + 1;
      else if (~serirq_count_en)
        serirq_counter <= 0;

      // Initialize SERIRQ cycle if interrupt is requested and we're in Quiet mode
      if (interrupt && serirq_mode == `LPC_SERIRQ_QUIET_MODE &&
          ~serirq_count_en && serirq !== 1'b0) begin
        serirq_reg     <= 0;
        driving_serirq <= 1;
      end
      // The only time when 'driving_serirq' is set and 'serirq_count_en' isn't is after above, use
      // this as a signal to stop driving SERIRQ.
      if (~serirq_count_en && driving_serirq)
        driving_serirq <= 0;

      // Notice this is the only time we check 'interrupt'. We need to do recovery/turn-around
      // cycles even if 'interrupt' was deasserted in the meantime by data provider.
      if (serirq_count_en && serirq_counter == irq_num_reg * 3 && interrupt) begin
        serirq_reg     <= 0; // Sample phase, Active low
        driving_serirq <= 1;
      end
      if (serirq_counter == irq_num_reg * 3 + 1 && driving_serirq) begin
        serirq_reg     <= 1; // Recovery
      end
      if (serirq_counter == irq_num_reg * 3 + 2) begin
        driving_serirq <= 0; // Turn-around
      end
    end
  end

  always @(negedge nrst_i or negedge clk_i) begin : serirq_sample
    // Start frame consists of 4 to 8 clocks of low SERIRQ, 5th bit is for catching transition. In
    // simulation this register may be shown in red, but it shouldn't contain any 'x' bits, only
    // '0', '1' and 'z' are valid. On hardware all 'z's will become '1's because of pull-up.
    reg [4:0] serirq_hist;
    if (~nrst_i) begin
      serirq_hist     <= 5'b11111;
      serirq_count_en <= 0;
      serirq_mode     <= `LPC_SERIRQ_CONT_MODE;
    end else begin
      // We're using non-blocking assignment, on top of it we're comparing history against a state
      // in which transition to high (idle) SERIRQ already happened. Because of that, IRQn slot
      // starts on (3*n)th clock cycle, instead of (3*n + 2), as described in specification.
      serirq_hist <= {serirq_hist[3:0], serirq};

      // Switch to Continuous mode every time SERIRQ is low, i.e. in the following cases:
      // - Start frame, driven by host or a peripheral (first clock in Quiet mode; may be us)
      // - Sample phase of any IRQ (ours or not)
      // - Stop frame, driven by host
      //
      // All of those happen before we parse Stop frame pulse width, so proper mode is set/restored
      // during turn-around phase of Stop frame.
      //
      // By doing so we ensure that we won't initiate SERIRQ cycle during recovery/turn-around phase
      // of Start frame, when SERIRQ is already high but 'serirq_count_en' was not yet set.
      if (serirq === 0)
        serirq_mode     <= `LPC_SERIRQ_CONT_MODE;

      if (serirq_hist === 5'b00001) begin
        // Start frame -> latch IRQ number so it won't change in the middle of SERIRQ cycle
        irq_num_reg     <= irq_num;
        serirq_count_en <= 1;
      end else if (serirq_hist[3:0] === 4'b0001) begin
        // 3-clocks Stop frame -> stay in Continuous mode
        serirq_count_en <= 0;
      end else if (serirq_hist[2:0] === 3'b001) begin
        // 2-clocks Stop frame -> switch to Quiet mode
        serirq_mode     <= `LPC_SERIRQ_QUIET_MODE;
        serirq_count_en <= 0;
      end
    end
  end

  always @(negedge nrst_i or negedge clk_i) begin
    if (~nrst_i) begin
      prev_state_o     <= `LPC_ST_IDLE;
      driving_data     <= 1'b0;
      waiting_on_write <= 1'b0;
      waiting_on_read  <= 1'b0;
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
          lpc_data_reg_w[3:0] <= lad_bus;
          fsm_next_state      <= `LPC_ST_DATA_WR_CLK1;
        end
        `LPC_ST_DATA_WR_CLK1: begin
          lpc_data_reg_w[7:4] <= lad_bus;
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

  assign serirq = driving_serirq ? serirq_reg : 1'bz;

  assign lpc_addr_o   = lpc_addr_reg;
  assign lpc_data_io  = (driving_data == 1'b1 && waiting_on_write == 1'b1) ? lpc_data_reg_w : 8'hzz;
  assign lpc_data_wr  = waiting_on_write;
  assign lpc_data_req = waiting_on_read;
endmodule
