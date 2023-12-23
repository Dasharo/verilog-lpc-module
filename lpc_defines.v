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

// verilog_format: off  // verible-verilog-format messes up comments alignment
`define LPC_START           4'b0101
`define LPC_STOP            4'b1111

`define LPC_IO_READ         4'b0000     // LPC I/O (or TPM I/O) read cycle
`define LPC_IO_WRITE        4'b0010     // LPC I/O (or TPM I/O) write cycle

`define LPC_SYNC_READY      4'b0000     // LPC Sync Ready
`define LPC_SYNC_SWAIT      4'b0101     // LPC Sync Short Wait (up to 8 cycles)
`define LPC_SYNC_LWAIT      4'b0110     // LPC Sync Long Wait (no limit)
`define LPC_SYNC_ERROR      4'b1010     // LPC Sync Error

// FSM states definitions, uses variation of Gray code (except resets and aborts)
`define LPC_ST_IDLE              5'h00  // LPC Idle state
`define LPC_ST_START             5'h01  // LPC Start state
`define LPC_ST_CYCTYPE_RD        5'h03  // LPC Cycle Type state (read)
`define LPC_ST_ADDR_RD_CLK1      5'h02  // LPC Address state (read, 1st cycle)
`define LPC_ST_ADDR_RD_CLK2      5'h06  // LPC Address state (read, 2nd cycle)
`define LPC_ST_ADDR_RD_CLK3      5'h07  // LPC Address state (read, 3rd cycle)
`define LPC_ST_ADDR_RD_CLK4      5'h05  // LPC Address state (read, 4th cycle)
`define LPC_ST_TAR_RD_CLK1       5'h04  // LPC Turnaround (read, 1st cycle)
`define LPC_ST_TAR_RD_CLK2       5'h0C  // LPC Turnaround (read, 2nd cycle)
`define LPC_ST_SYNC_RD           5'h0D  // LPC Sync State (read, may be multiple cycles for wait-states)
`define LPC_ST_DATA_RD_CLK1      5'h09  // LPC Data state (read, 1st cycle)
`define LPC_ST_DATA_RD_CLK2      5'h08  // LPC Data state (read, 2nd cycle)
`define LPC_ST_CYCTYPE_WR        5'h11  // LPC Cycle Type state (write)
`define LPC_ST_ADDR_WR_CLK1      5'h13  // LPC Address state (write, 1st cycle)
`define LPC_ST_ADDR_WR_CLK2      5'h12  // LPC Address state (write, 2nd cycle)
`define LPC_ST_ADDR_WR_CLK3      5'h16  // LPC Address state (write, 3rd cycle)
`define LPC_ST_ADDR_WR_CLK4      5'h17  // LPC Address state (write, 4th cycle)
`define LPC_ST_DATA_WR_CLK1      5'h15  // LPC Data state (write, 1st cycle)
`define LPC_ST_DATA_WR_CLK2      5'h14  // LPC Data state (write, 2nd cycle)
`define LPC_ST_TAR_WR_CLK1       5'h1C  // LPC Turnaround (write, 1st cycle)
`define LPC_ST_TAR_WR_CLK2       5'h18  // LPC Turnaround (write, 2nd cycle)
`define LPC_ST_SYNC_WR           5'h10  // LPC Sync State (write, may be multiple cycles for wait-states)

`define LPC_SERIRQ_CONT_MODE     1'b0
`define LPC_SERIRQ_QUIET_MODE    1'b1
// verilog_format: on
