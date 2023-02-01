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


`include "lpc_defines.v"

module lpc_host (clk_i, ctrl_addr_i, ctrl_data_i, ctrl_nrst_i, ctrl_lframe_i,
                 ctrl_rd_status_i, ctrl_wr_status_i, ctrl_memory_cycle_i,
                 ctrl_data_o, ctrl_ready_o, ctrl_host_state_o,
                 LPC_LAD, LPC_LCLK, LPC_LRESET, LPC_LFRAME
);

    input  wire        clk_i;

    // Control signals are used to drive the control the LPC host.
    // Control signals (input)
    input  wire [15:0] ctrl_addr_i;
    input  wire [ 7:0] ctrl_data_i;
    input  wire        ctrl_nrst_i;
    input  wire        ctrl_lframe_i;
    input  wire        ctrl_rd_status_i;
    input  wire        ctrl_wr_status_i;
    input  wire        ctrl_memory_cycle_i; // 1- means Memory cycle, 0 - means I/O cycle

    // Control signals (output)
    output reg  [ 7:0] ctrl_data_o;
    output reg         ctrl_ready_o;
    output wire [ 4:0] ctrl_host_state_o;

    // LPC Host Interface
    inout  wire [ 3:0] LPC_LAD;
    output wire        LPC_LCLK;
    output reg         LPC_LRESET;
    output reg         LPC_LFRAME;

    // LPC Host FSM state
    reg [4:0] fsm_host_state;

    // Intermediate signals
    reg       lad_en;
    reg [3:0] lad_out;
    reg [3:0] lad_reg;

    assign ctrl_host_state_o = fsm_host_state;

    assign LPC_LAD  = (lad_en) ? lad_out : 4'bZZZZ;
    assign LPC_LCLK = ~clk_i;

    // FSM - finite state machine : LPC Host
    always @ (posedge clk_i) begin
        lad_reg <= LPC_LAD;
        if (fsm_host_state == `LPC_ST_FORCE_RESET) begin
            if (~ctrl_nrst_i) begin
                LPC_LRESET  = 0;
                LPC_LFRAME  = 1;
                lad_en  = 0;
                lad_out = `LPC_START;
                ctrl_ready_o   = 0;
            end
        else begin
            LPC_LRESET  = 1;
            LPC_LFRAME  = 1;
            lad_en  = 0;
            lad_out = `LPC_START;
            ctrl_ready_o   = 0;
            fsm_host_state = `LPC_ST_IDLE;
        end
        end
        else if (fsm_host_state == `LPC_ST_IDLE) begin
            if (~ctrl_lframe_i) begin
            LPC_LFRAME  = 0;
            lad_en  = 1;
            lad_out = `LPC_START;
            ctrl_ready_o   = 0;
            fsm_host_state = `LPC_ST_START;
        end
        else LPC_LRESET = 1;
        end
        else if (fsm_host_state == `LPC_ST_START) begin
           if (~ctrl_memory_cycle_i) begin
                if (ctrl_lframe_i & ctrl_rd_status_i) begin
                    LPC_LFRAME  = 1;
                    lad_out = 4'b0000;
                    fsm_host_state = `LPC_ST_CYCTYPE_RD;
                end
                else if (ctrl_lframe_i & ctrl_wr_status_i) begin
                    LPC_LFRAME  = 1;
                    lad_out = 4'b0010;
                    fsm_host_state = `LPC_ST_CYCTYPE_WR;
                end
           end  if (ctrl_memory_cycle_i) begin
                if (ctrl_lframe_i & ctrl_rd_status_i) begin
                    LPC_LFRAME  = 1;
                    lad_out = 4'b0100;
                    fsm_host_state = `LPC_ST_CYCTYPE_MEMORY_RD;
                end
                else if (ctrl_lframe_i & ctrl_wr_status_i) begin
                    LPC_LFRAME  = 1;
                    lad_out = 4'b0110;
                    fsm_host_state = `LPC_ST_CYCTYPE_MEMORY_WR;
                end
           end
        end
        else if ((fsm_host_state == `LPC_ST_CYCTYPE_RD) || (fsm_host_state == `LPC_ST_CYCTYPE_MEMORY_RD)) begin
            lad_out = ctrl_addr_i[15:12];
            fsm_host_state = `LPC_ST_ADDR_RD_CLK1;
        end
        else if (fsm_host_state == `LPC_ST_ADDR_RD_CLK1) begin
            lad_out    = ctrl_addr_i[11: 8];
            fsm_host_state = `LPC_ST_ADDR_RD_CLK2;
        end
        else if (fsm_host_state == `LPC_ST_ADDR_RD_CLK2) begin
           lad_out    = ctrl_addr_i[ 7: 4];
           fsm_host_state = `LPC_ST_ADDR_RD_CLK3;
        end
        else if (fsm_host_state == `LPC_ST_ADDR_RD_CLK3) begin
            lad_out    = ctrl_addr_i[ 3: 0];
            fsm_host_state = `LPC_ST_ADDR_RD_CLK4;
        end
        else if (fsm_host_state == `LPC_ST_ADDR_RD_CLK4) begin
            lad_out    = 4'b1111;
            fsm_host_state = `LPC_ST_TAR_RD_CLK1;
        end
        else if (fsm_host_state == `LPC_ST_TAR_RD_CLK1) begin
            lad_en     = 0;
            fsm_host_state = `LPC_ST_TAR_RD_CLK2;
        end
        else if (fsm_host_state == `LPC_ST_TAR_RD_CLK2) begin
            fsm_host_state = `LPC_ST_SYNC_RD;
        end
        else if (fsm_host_state == `LPC_ST_SYNC_RD) begin
            ctrl_data_o[3:0] = LPC_LAD;
            fsm_host_state    = `LPC_ST_DATA_RD_CLK1;
            if (lad_reg == 4'b0000) fsm_host_state = `LPC_ST_DATA_RD_CLK1;
            else if ((lad_reg != 4'b0101) && (lad_reg != 4'b0110)) begin
                LPC_LRESET = 0;
                LPC_LFRAME = 1;
                lad_en = 0;
                lad_out = `LPC_START;
                ctrl_ready_o = 0;
                fsm_host_state = `LPC_ST_FORCE_RESET;
            end
        end
        else if (fsm_host_state == `LPC_ST_DATA_RD_CLK1) begin
            ctrl_data_o[7:4] = LPC_LAD;
            fsm_host_state = `LPC_ST_DATA_RD_CLK2;
        end
        else if (fsm_host_state == `LPC_ST_DATA_RD_CLK2) begin
            fsm_host_state = `LPC_ST_FINAL_TAR_CLK1;
        end
        else if ((fsm_host_state == `LPC_ST_CYCTYPE_WR) || (fsm_host_state == `LPC_ST_CYCTYPE_MEMORY_WR)) begin
            lad_out = ctrl_addr_i[15:12];
            fsm_host_state = `LPC_ST_ADDR_WR_CLK1;
        end
        else if (fsm_host_state ==  `LPC_ST_ADDR_WR_CLK1) begin
            lad_out = ctrl_addr_i[11: 8];
            fsm_host_state = `LPC_ST_ADDR_WR_CLK2;
        end
        else if (fsm_host_state == `LPC_ST_ADDR_WR_CLK2) begin
            lad_out = ctrl_addr_i[ 7: 4];
            fsm_host_state = `LPC_ST_ADDR_WR_CLK3;
        end
        else if (fsm_host_state == `LPC_ST_ADDR_WR_CLK3) begin
           lad_out = ctrl_addr_i[ 3: 0];
           fsm_host_state = `LPC_ST_ADDR_WR_CLK4;
        end
        else if (fsm_host_state == `LPC_ST_ADDR_WR_CLK4) begin
            lad_out = ctrl_data_i[3:0];
            fsm_host_state = `LPC_ST_DATA_WR_CLK1;
        end
        else if (fsm_host_state == `LPC_ST_DATA_WR_CLK1) begin
            lad_out = ctrl_data_i[7:4];
            fsm_host_state = `LPC_ST_DATA_WR_CLK2;
        end
        else if (fsm_host_state == `LPC_ST_DATA_WR_CLK2) begin
            lad_out = 4'b1111;
            fsm_host_state = `LPC_ST_TAR_WR_CLK1;
        end
        else if (fsm_host_state == `LPC_ST_TAR_WR_CLK1) begin
            lad_en = 0;
            fsm_host_state = `LPC_ST_TAR_WR_CLK2;
        end
        else if (fsm_host_state == `LPC_ST_TAR_WR_CLK2) begin
            fsm_host_state = `LPC_ST_SYNC_WR;
        end
        else if (fsm_host_state == `LPC_ST_SYNC_WR) begin
            if (lad_reg == 4'b0000) fsm_host_state = `LPC_ST_FINAL_TAR_CLK1;
            else if ((lad_reg != 4'b0101) && (lad_reg != 4'b0110)) begin
                LPC_LRESET = 0;
                LPC_LFRAME = 1;
                lad_en = 0;
                lad_out = `LPC_START;
                ctrl_ready_o = 0;
                fsm_host_state = `LPC_ST_FORCE_RESET;
            end
        end
        else if (fsm_host_state == `LPC_ST_FINAL_TAR_CLK1) begin
            if (lad_reg != 4'b1111) begin
                LPC_LRESET = 0;
                LPC_LFRAME = 1;
                lad_en = 0;
                lad_out = `LPC_START;
                ctrl_ready_o = 0;
                fsm_host_state = `LPC_ST_FORCE_RESET;
            end
            else begin
                ctrl_ready_o = 1;
                fsm_host_state = `LPC_ST_FINAL_TAR_CLK2;
            end
        end
        else if (fsm_host_state == `LPC_ST_FINAL_TAR_CLK2) begin
            fsm_host_state = `LPC_ST_IDLE;
        end
        else begin
            fsm_host_state = `LPC_ST_FORCE_RESET;
        end
    end
endmodule
