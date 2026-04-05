`timescale 1ns / 1ps
//==============================================================================
// Module  : instruction_fetch
// Project : RV32I Edge-AI Processor — Frontend IP
// Author  : Shreyas
// Target  : Vivado / Artix-7 / Zynq
//
// Description:
//   Stage 1 — Instruction Fetch.
//   Manages the Program Counter (PC), drives the instruction memory address,
//   and increments PC by 4 on every normal cycle.
//   When stall_i is asserted (by the Loop Control Unit during SCNN dispatch),
//   the PC is frozen — no new instruction is fetched.
//   Supports synchronous reset (active-high).
//
// Ports:
//   clk_i        — system clock
//   rst_i        — synchronous reset, active-high
//   stall_i      — freeze PC (asserted by LCU during AI accelerator execution)
//   branch_en_i  — branch/jump taken signal (from Execute stage, Phase 2)
//   branch_pc_i  — branch target address  (from Execute stage, Phase 2)
//   pc_o         — current PC driven to Decode stage
//   imem_addr_o  — address to Instruction Memory (byte-addressed)
//==============================================================================

module instruction_fetch (
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire        stall_i,
    input  wire        branch_en_i,
    input  wire [31:0] branch_pc_i,
    output reg  [31:0] pc_o,
    output wire [31:0] imem_addr_o
);

    // PC update logic
    // Priority: reset > stall > branch > normal increment
    always @(posedge clk_i) begin
        if (rst_i) begin
            pc_o <= 32'h0000_0000;          // boot vector
        end else if (!stall_i) begin
            if (branch_en_i)
                pc_o <= branch_pc_i;        // taken branch / JAL / JALR
            else
                pc_o <= pc_o + 32'd4;       // normal sequential fetch
        end
        // stall_i == 1 : pc_o holds — no change
    end

    // Instruction memory address is the current PC
    // (combinational — no pipeline register here; IMEM has 1-cycle read latency)
    assign imem_addr_o = pc_o;

endmodule
