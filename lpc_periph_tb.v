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

module lpc_periph_tb();

    reg         addr_hit;
    reg         rd_flag;  //indicates that this is read cycle
    reg         wr_flag;  //indicates that this is write cycle
    reg         clk_i;    //input clock
    reg         nrst_i;   //asynchronous reset - active Low
    reg         lframe_i; //active low signal indicating new LPC frame
    reg  [15:0] host_addr_i = 16'h0000; //LPC host addres to input to the LPC host
    reg  [ 7:0] host_wr_i = 8'h00;
    reg  [ 7:0] periph_data_i = 8'h00;

    wire [ 7:0] periph_wr_o;
    wire [15:0] periph_addr_o; //LPC addres received by the LPC peripheral
    wire  [7:0] host_data_o;
    wire  [3:0] periph_rd_out;
    wire        host_ready;    //indicates that host is ready for next cycle

    wire        periph_rd_status;
    wire        periph_wr_status;      //status: current peripheral read operation
    wire  [4:0] current_periph_state;  //status: current peripheral state
    wire  [4:0] current_host_state;    //status: current host state
    wire        periph_en;             //status: peripheral is ready to new cycle

    wire        LCLK;           //Host LPC output clock
    wire        LRESET;         //Host LReset
    wire        LFRAME;         //Host LFRAME
    wire  [3:0] LAD = 4'bZZZZ; //Bi-directional (tri-state) LPC bus (multiplexed addres and data 4-bit chunks)

    wire [31:0] TDATABOu;   //32-bit LPC cycle data (16-bit address, 8-bit LPC data, type of cycle)
    reg         READYBOu;
    wire        READYNET;
    reg  [15:0] u_addr;    //auxiliary host addres
    reg   [7:0] u_data;    //auxiliary host data
    integer i, j;
    reg memory_cycle_sig;

    initial
    begin
        clk_i = 1'b1;
        READYBOu = 1'b0;
        forever
            #20 clk_i = ~clk_i;
    end

    initial
    begin
        // Initialize
        $dumpfile("lpc_periph_tb.vcd");
        $dumpvars(0,lpc_periph_tb);

        lframe_i = 1;
        addr_hit = 1;
        nrst_i = 1;
        rd_flag  = 0;
        wr_flag = 1;
        #40 nrst_i = 0;
        #250 nrst_i = 1;
        
        memory_cycle_sig = 0;

        // Perform write
        #40  lframe_i = 0;
        host_addr_i = 16'hF0F0;
        host_wr_i = 8'h5A;
        #40  lframe_i = 1;

        // Perform read
        #800 lframe_i = 0;
        periph_data_i = 8'hA5;
        rd_flag = 1;
        wr_flag = 0;
        #80  lframe_i = 1;

        // Perform read
        #800 lframe_i = 0;
        periph_data_i = 8'h88;
        rd_flag = 1;
        wr_flag = 0;
        #80  lframe_i = 1;

        // Perform read
        #800 lframe_i = 0;
        periph_data_i = 8'h88;
        rd_flag = 1;
        wr_flag = 0;
        #80  lframe_i = 1;

        // Perform read
        #800 lframe_i = 0;
        periph_data_i = 8'h88;
        rd_flag = 1;
        wr_flag = 0;
        #80  lframe_i = 1;

        addr_hit = 0;
        nrst_i = 1;
        u_addr = 0;
        u_data = 0;

        lframe_i = 1;
        addr_hit = 1;
        nrst_i = 1;
        rd_flag = 0;
        wr_flag = 1;
        #40 nrst_i = 0;
        #250 nrst_i = 1;

        #600 lframe_i = 1;

        for (i = 0; i <= 128; i = i + 1) begin
          for(j = 0; j < 2; j = j + 1) begin
            memory_cycle_sig = j; //Cycle type: Memory or I/O
            // Perform write
            #40  lframe_i  = 0;
            rd_flag = 0;
            wr_flag  = 1;
            host_addr_i = u_addr+i;
            host_wr_i  = u_data+i;
            #40 lframe_i = 1;
            #400 lframe_i = 0;

            // Perform read
            #800 lframe_i = 0;
            periph_data_i = 8'hBB+i;
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

    // LPC Host instantiation
    lpc_host lpc_host_inst(
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
    .LPC_LAD(LAD), .LPC_LCLK(LCLK), .LPC_LRESET(LRESET), .LPC_LFRAME(LFRAME),
    .ctrl_host_state_o(current_host_state)
    );

    // LPC Peripheral instantiation
    lpc_periph lpc_periph_inst(
    // LPC Interface
    .clk_i(LCLK),
    .nrst_i(LRESET),
    .lframe_i(LFRAME),
    .lad_bus(LAD),
    .addr_hit_i(addr_hit),
    .current_state_o(current_periph_state),
    .din_i(periph_data_i),
    .lpc_data_in_o(periph_wr_o),
    .lpc_data_out_o(periph_rd_out),
    .lpc_addr_o(periph_addr_o),
    .lpc_en_o(periph_en),
    .io_wren_sm_o(periph_wr_status),
    .io_rden_sm_o(periph_rd_status),
    //----------------------------------
    .TDATA(TDATABOu),
    .READY(READYNET)
    );

endmodule
