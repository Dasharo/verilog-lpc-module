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

module lpc_periph (clk_i, nrst_i, lframe_i, lad_bus, addr_hit_i, current_state_o,
                   din_i, lpc_data_in_o, lpc_data_out_o, lpc_addr_o, lpc_en_o,
                   io_rden_sm_o, io_wren_sm_o, TDATA, READY
);

    // Master Interface
    input  wire        clk_i; // LPC clock
    input  wire        nrst_i; // LPC rese (active low)

    // LPC Slave Interface
    input  wire        lframe_i; // LPC frame input (active low)
    inout  wire [ 3:0] lad_bus; // LPC data bus

    // Helper signals
    input  wire        addr_hit_i;
    output reg  [ 4:0] current_state_o;
    input  wire [ 7:0] din_i;
    output reg  [ 7:0] lpc_data_in_o;
    output wire [ 3:0] lpc_data_out_o;
    output wire [15:0] lpc_addr_o;
    output wire        lpc_en_o;
    output wire        io_rden_sm_o;
    output wire        io_wren_sm_o;
    output reg  [31:0] TDATA;
    output reg         READY;

    // Internal signals
    reg         sync_en;
    reg   [3:0] rd_addr_en;
    wire  [1:0] wr_data_en;
    wire  [1:0] rd_data_en;
    reg         tar_F;
    reg  [15:0] lpc_addr_o_reg;

    reg   [4:0] fsm_next_state;
    reg   [4:0] previous_state;

    reg   [1:0] cycle_type = 2'b00; //"00" none, "01" write, "11" read
    integer cycle_cnt = 0;
    reg  [31:0] dinAbuf = 32'b00000000000000000000000000000000;

    reg  [31:0] memoryLPC [0:2]; //memory array 2x32bit
    reg wasLframeLow = 1'b0;
    reg wasLpc_enHigh = 1'b0;
    reg newValuedata = 1'b0;

    assign lpc_addr_o = lpc_addr_o_reg;

    always @ (posedge clk_i or negedge nrst_i) begin    //save cycle type
        if (~nrst_i) cycle_type <= 2'b00;
        else if (clk_i) begin
            cycle_type <= 2'b00;
            if (io_rden_sm_o) begin
                cycle_type <= 2'b11; //read
            end;
            if (io_wren_sm_o) begin
               cycle_type <= 2'b01; //write
            end;
        end;
    end

    always @ (posedge clk_i) begin  //saving LPC protocol data 2 out databus
        if (lframe_i==1'b0) begin
            wasLframeLow = 1'b1;
            cycle_cnt = 0;
            wasLpc_enHigh = 1'b0;
        end
            if ((lpc_en_o) && (wasLframeLow)) begin
                wasLpc_enHigh = 1'b1;
            end
            if (wasLpc_enHigh) begin
                cycle_cnt = cycle_cnt + 1;
                if ((cycle_cnt > 1) && (cycle_cnt < 3)) begin
                    dinAbuf[31:28] <= 4'b0000;
                    dinAbuf[27:12] <= lpc_addr_o_reg;
                    dinAbuf[11:4] <= lpc_data_in_o;
                    dinAbuf[3:2] <= 2'b00;
                    dinAbuf[1:0] <= cycle_type;
                    if (dinAbuf==memoryLPC[0]) newValuedata = 1'b0;
                    else newValuedata = 1'b1;
                    TDATA <= dinAbuf;
                    memoryLPC[0] <= dinAbuf;
                end
                else if ( (cycle_cnt >=3) && (cycle_cnt < 5)) begin
                    if (newValuedata) READY <= 1'b1;
                    else READY <= 1'b0;
                end
                else if  (cycle_cnt >= 5) begin
                    READY <= 1'b0;
                    wasLpc_enHigh = 1'b0;
                    wasLframeLow = 1'b0;
                    cycle_cnt = 0;
            end
        end
    end

    always @ (posedge clk_i or negedge nrst_i) begin
        if (~nrst_i) current_state_o <= `LPC_ST_IDLE;
        else begin
            previous_state <= current_state_o;
            current_state_o <= fsm_next_state;
        end
    end

    always @(*) begin
        if (nrst_i == 1'b0) fsm_next_state <= `LPC_ST_IDLE;
        if (lframe_i == 1'b0) fsm_next_state <= `LPC_ST_IDLE;
        case(current_state_o)
            `LPC_ST_IDLE:
             begin
                 if (nrst_i == 1'b0) fsm_next_state <= `LPC_ST_IDLE;
                 else if ((lframe_i == 1'b0) && (lad_bus == 4'h0)) fsm_next_state <= `LPC_ST_START;
             end
             `LPC_ST_START:
              begin
                  if ((lframe_i == 1'b0) && (lad_bus == 4'h0)) fsm_next_state <= `LPC_ST_START;
                  else if ((lframe_i == 1'b1) && (lad_bus == 4'h0)) fsm_next_state <= `LPC_ST_CYCTYPE_RD;
                  else if ((lframe_i == 1'b1) && (lad_bus == 4'h2)) fsm_next_state <= `LPC_ST_CYCTYPE_WR;
              end
              `LPC_ST_CYCTYPE_RD:
               fsm_next_state <= `LPC_ST_ADDR_RD_CLK1;
              `LPC_ST_ADDR_RD_CLK1:
               fsm_next_state <= `LPC_ST_ADDR_RD_CLK2;
              `LPC_ST_ADDR_RD_CLK2:
               fsm_next_state <= `LPC_ST_ADDR_RD_CLK3;
              `LPC_ST_ADDR_RD_CLK3:
               fsm_next_state <= `LPC_ST_ADDR_RD_CLK4;
              `LPC_ST_ADDR_RD_CLK4:
               fsm_next_state <= `LPC_ST_TAR_RD_CLK1;
              `LPC_ST_TAR_RD_CLK1:
               fsm_next_state = `LPC_ST_TAR_RD_CLK2;
              `LPC_ST_TAR_RD_CLK2:
               begin
                   if (addr_hit_i == 1'b0) fsm_next_state = `LPC_ST_IDLE;
                   if (addr_hit_i == 1'b1) fsm_next_state = `LPC_ST_SYNC_RD;
               end
              `LPC_ST_SYNC_RD:
               fsm_next_state <= `LPC_ST_DATA_RD_CLK1;
              `LPC_ST_DATA_RD_CLK1:
               fsm_next_state <= `LPC_ST_DATA_RD_CLK2;
              `LPC_ST_DATA_RD_CLK2:
               fsm_next_state <= `LPC_ST_FINAL_TAR_CLK1;
              `LPC_ST_CYCTYPE_WR:
               fsm_next_state <= `LPC_ST_ADDR_WR_CLK1;
              `LPC_ST_ADDR_WR_CLK1:
               fsm_next_state <= `LPC_ST_ADDR_WR_CLK2;
              `LPC_ST_ADDR_WR_CLK2:
               fsm_next_state <= `LPC_ST_ADDR_WR_CLK3;
              `LPC_ST_ADDR_WR_CLK3:
               fsm_next_state <= `LPC_ST_ADDR_WR_CLK4;
              `LPC_ST_ADDR_WR_CLK4:
               fsm_next_state <= `LPC_ST_DATA_WR_CLK1;
              `LPC_ST_DATA_WR_CLK1:
               fsm_next_state <= `LPC_ST_DATA_WR_CLK2;
              `LPC_ST_DATA_WR_CLK2:
               fsm_next_state <= `LPC_ST_TAR_WR_CLK1;
              `LPC_ST_TAR_WR_CLK1:
               fsm_next_state <= `LPC_ST_TAR_WR_CLK2;
              `LPC_ST_TAR_WR_CLK2:
               begin
                   if (addr_hit_i == 1'b0) fsm_next_state <= `LPC_ST_IDLE;
                   if (addr_hit_i == 1'b1) fsm_next_state <= `LPC_ST_SYNC_WR;
               end
              `LPC_ST_SYNC_WR:
               fsm_next_state <= `LPC_ST_FINAL_TAR_CLK1;
              `LPC_ST_FINAL_TAR_CLK1:
               fsm_next_state <= `LPC_ST_FINAL_TAR_CLK2;
              default:
              begin
                  if (nrst_i == 1'b0) fsm_next_state <= `LPC_ST_IDLE;
                  if (lframe_i == 1'b0) fsm_next_state <= `LPC_ST_IDLE;
                  fsm_next_state <= `LPC_ST_IDLE;
              end
        endcase
    end

    assign rd_data_en = (fsm_next_state == `LPC_ST_DATA_RD_CLK1) ? 2'b01 :
                        (fsm_next_state == `LPC_ST_DATA_RD_CLK2) ? 2'b10 :
                        2'b00;

    assign lpc_data_out_o = (sync_en == 1'b1) ? 4'h0 :
                            (tar_F == 1'b1 ) ? 4'hF :
                            (lframe_i == 1'b0 ) ? 4'h0 :
                            (rd_data_en[0] == 1'b1) ? din_i[3:0] :
                            (rd_data_en[1] == 1'b1) ? din_i[7:4] :
                            4'h0;

    assign lad_bus = (current_state_o == `LPC_ST_SYNC_WR) ? 4'b0000 : 4'bzzzz;
    assign lad_bus = (rd_data_en[0]) ? lpc_data_out_o: 4'bzzzz;
    assign lad_bus = (rd_data_en[1]) ? lpc_data_out_o: 4'bzzzz;

    assign io_wren_sm_o = (fsm_next_state == `LPC_ST_TAR_WR_CLK1) ? 1'b1 :
                          (fsm_next_state == `LPC_ST_TAR_WR_CLK2) ? 1'b1 :
                          1'b0;

    always @ (posedge clk_i) begin
        if (wr_data_en[0]) lpc_data_in_o[3:0] <= lad_bus;
        if (wr_data_en[1]) lpc_data_in_o[7:4] <= lad_bus;
    end

    assign lpc_en_o = (sync_en == 1'b1 ) ? 1'h1 :
                      (tar_F == 1'b1 ) ? 1'h1 :
                      (lframe_i == 1'b0 ) ? 1'h0 :
                      (rd_data_en[0] == 1'b1) ? 1'b1 :
                      (rd_data_en[1] == 1'b1) ? 1'b1 :
                      1'h0;

    always @(*) begin
        tar_F <= 1'b0;
        case(fsm_next_state)
            `LPC_ST_SYNC_RD:
             sync_en <= 1'b1;
            `LPC_ST_SYNC_WR:
             sync_en <= 1'b1;
            `LPC_ST_FINAL_TAR_CLK1:
             tar_F <= 1'b1;
            `LPC_ST_ADDR_RD_CLK1:
             rd_addr_en <= 4'b1000;
            `LPC_ST_ADDR_RD_CLK2:
             rd_addr_en <= 4'b0100;
            `LPC_ST_ADDR_RD_CLK3:
             rd_addr_en <= 4'b0010;
            `LPC_ST_ADDR_RD_CLK4:
             rd_addr_en <= 4'b0001;
            `LPC_ST_ADDR_WR_CLK1:
             rd_addr_en <= 4'b1000;
            `LPC_ST_ADDR_WR_CLK2:
             rd_addr_en <= 4'b0100;
            `LPC_ST_ADDR_WR_CLK3:
             rd_addr_en <= 4'b0010;
            `LPC_ST_ADDR_WR_CLK4:
             rd_addr_en <= 4'b0001;
            default:
            begin
                rd_addr_en <= 4'b0000;
                tar_F <= 1'b0;
                sync_en <= 1'b0;
            end
        endcase
    end

    assign io_rden_sm_o = (fsm_next_state == `LPC_ST_TAR_RD_CLK1) ? 1'b1 :
                          (fsm_next_state == `LPC_ST_TAR_RD_CLK2) ? 1'b1 :
                          1'b0;

    assign wr_data_en = (fsm_next_state == `LPC_ST_DATA_WR_CLK1) ? 2'b01 :
                        (fsm_next_state == `LPC_ST_DATA_WR_CLK2) ? 2'b10 :
                        2'b00;


    always @ (posedge clk_i) begin
        if (rd_addr_en[3] == 1'b1) lpc_addr_o_reg[15:12] = lad_bus;
        else if (rd_addr_en[3] == 1'b1) lpc_addr_o_reg[15:12] = lpc_addr_o_reg[15:12];
        if (rd_addr_en[2] == 1'b1) lpc_addr_o_reg[11:8] = lad_bus;
        else if (rd_addr_en[2] == 1'b1) lpc_addr_o_reg[11:8] = lpc_addr_o_reg[11:8];
        if (rd_addr_en[1] == 1'b1) lpc_addr_o_reg[7:4] = lad_bus;
        else if (rd_addr_en[1] == 1'b1) lpc_addr_o_reg[7:4] = lpc_addr_o_reg[7:4];
        if (rd_addr_en[0] == 1'b1) lpc_addr_o_reg[3:0] = lad_bus;
        else if (rd_addr_en[0] == 1'b1) lpc_addr_o_reg[3:0] = lpc_addr_o_reg[3:0];
    end
endmodule
