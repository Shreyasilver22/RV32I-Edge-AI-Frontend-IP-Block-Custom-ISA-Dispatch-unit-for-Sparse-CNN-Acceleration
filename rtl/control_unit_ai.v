`timescale 1ns / 1ps
//==============================================================================
// Module  : control_unit_ai
// Project : RV32I Edge-AI Processor — Frontend IP
// Author  : Shreyas
// Target  : Vivado / Artix-7 / Zynq
//
// Description:
//   Stage 2 — Control Unit + Loop Control Unit (LCU).
//
//   Generates all datapath control signals for the RV32I pipeline.
//   The KEY addition over a vanilla RISC-V control unit is the AI dispatch path:
//
//     When opcode == 7'b0001011 (custom-0, our SCNN instruction):
//       1. scnn_enable_o   → HIGH  (wakes the AI accelerator)
//       2. pc_stall_o      → HIGH  (freezes the PC via LCU)
//       3. alu_src_o       → don't-care (ALU bypassed)
//       4. reg_write_o     → LOW   (suppressed until accelerator finishes)
//
//     scnn_done_i from the accelerator clears the stall after matrix op completes.
//
//   All other outputs follow standard RV32I control encoding.
//
// Ports:
//   opcode_i       — [6:0]  from Decode stage
//   funct3_i       — [2:0]  from Decode stage
//   funct7_i       — [6:0]  from Decode stage
//   scnn_done_i    — accelerator signals completion (1 = done, go back to normal)
//   -- Datapath controls --
//   reg_write_o    — write enable to register file
//   alu_src_o      — 0=register, 1=immediate
//   mem_write_o    — data memory write enable
//   mem_read_o     — data memory read enable
//   mem_to_reg_o   — 0=ALU result to reg, 1=memory data to reg
//   branch_o       — branch instruction flag
//   jump_o         — unconditional jump (JAL/JALR)
//   alu_op_o       — [3:0] ALU operation selector (to Execute stage)
//   -- AI dispatch --
//   scnn_enable_o  — HIGH = route to SCNN accelerator
//   pc_stall_o     — HIGH = freeze PC (LCU output)
//
// ALU op encoding (alu_op_o):
//   4'b0000 = ADD      4'b0001 = SUB
//   4'b0010 = AND      4'b0011 = OR
//   4'b0100 = XOR      4'b0101 = SLT
//   4'b0110 = SLTU     4'b0111 = SLL
//   4'b1000 = SRL      4'b1001 = SRA
//   4'b1111 = NOP/pass-through
//==============================================================================

module control_unit_ai (
    input  wire [6:0] opcode_i,
    input  wire [2:0] funct3_i,
    input  wire [6:0] funct7_i,
    input  wire       scnn_done_i,

    output reg        reg_write_o,
    output reg        alu_src_o,
    output reg        mem_write_o,
    output reg        mem_read_o,
    output reg        mem_to_reg_o,
    output reg        branch_o,
    output reg        jump_o,
    output reg [3:0]  alu_op_o,
    output reg        scnn_enable_o,
    output reg        pc_stall_o
);

    //--------------------------------------------------------------------------
    // Opcode constants
    //--------------------------------------------------------------------------
    localparam OP_LOAD    = 7'b000_0011;
    localparam OP_STORE   = 7'b010_0011;
    localparam OP_BRANCH  = 7'b110_0011;
    localparam OP_JAL     = 7'b110_1111;
    localparam OP_JALR    = 7'b110_0111;
    localparam OP_LUI     = 7'b011_0111;
    localparam OP_AUIPC   = 7'b001_0111;
    localparam OP_IMM     = 7'b001_0011;
    localparam OP_REG     = 7'b011_0011;
    localparam OP_CUSTOM0 = 7'b000_1011;  // ← SCNN dispatch

    //--------------------------------------------------------------------------
    // ALU op helper: decode funct3/funct7 for R-type and I-type
    //--------------------------------------------------------------------------
    function [3:0] alu_op_from_funct;
        input [2:0] f3;
        input [6:0] f7;
        input       is_imm;  // 1 for I-type (no funct7 SUB/SRA distinction)
        begin
            case (f3)
                3'b000: alu_op_from_funct = (f7[5] && !is_imm) ? 4'b0001 : 4'b0000; // SUB / ADD
                3'b001: alu_op_from_funct = 4'b0111; // SLL
                3'b010: alu_op_from_funct = 4'b0101; // SLT
                3'b011: alu_op_from_funct = 4'b0110; // SLTU
                3'b100: alu_op_from_funct = 4'b0100; // XOR
                3'b101: alu_op_from_funct = f7[5] ? 4'b1001 : 4'b1000; // SRA / SRL
                3'b110: alu_op_from_funct = 4'b0011; // OR
                3'b111: alu_op_from_funct = 4'b0010; // AND
                default: alu_op_from_funct = 4'b0000;
            endcase
        end
    endfunction

    //--------------------------------------------------------------------------
    // Main control decode (combinational)
    //--------------------------------------------------------------------------
    always @(*) begin
        // Safe defaults — all signals deasserted
        reg_write_o   = 1'b0;
        alu_src_o     = 1'b0;
        mem_write_o   = 1'b0;
        mem_read_o    = 1'b0;
        mem_to_reg_o  = 1'b0;
        branch_o      = 1'b0;
        jump_o        = 1'b0;
        alu_op_o      = 4'b0000;
        scnn_enable_o = 1'b0;
        pc_stall_o    = 1'b0;

        case (opcode_i)

            //------------------------------------------------------------------
            // R-type: register-register arithmetic/logic
            //------------------------------------------------------------------
            OP_REG: begin
                reg_write_o = 1'b1;
                alu_src_o   = 1'b0;
                alu_op_o    = alu_op_from_funct(funct3_i, funct7_i, 1'b0);
            end

            //------------------------------------------------------------------
            // I-type: immediate arithmetic/logic
            //------------------------------------------------------------------
            OP_IMM: begin
                reg_write_o = 1'b1;
                alu_src_o   = 1'b1;
                alu_op_o    = alu_op_from_funct(funct3_i, funct7_i, 1'b1);
            end

            //------------------------------------------------------------------
            // Load: LW, LH, LB, LHU, LBU
            //------------------------------------------------------------------
            OP_LOAD: begin
                reg_write_o  = 1'b1;
                alu_src_o    = 1'b1;
                mem_read_o   = 1'b1;
                mem_to_reg_o = 1'b1;
                alu_op_o     = 4'b0000; // ADD for address calc
            end

            //------------------------------------------------------------------
            // Store: SW, SH, SB
            //------------------------------------------------------------------
            OP_STORE: begin
                alu_src_o   = 1'b1;
                mem_write_o = 1'b1;
                alu_op_o    = 4'b0000; // ADD for address calc
            end

            //------------------------------------------------------------------
            // Branch: BEQ, BNE, BLT, BGE, BLTU, BGEU
            //------------------------------------------------------------------
            OP_BRANCH: begin
                branch_o  = 1'b1;
                alu_op_o  = 4'b0001; // SUB for comparison
            end

            //------------------------------------------------------------------
            // JAL — unconditional jump, write PC+4 to rd
            //------------------------------------------------------------------
            OP_JAL: begin
                reg_write_o = 1'b1;
                jump_o      = 1'b1;
                alu_op_o    = 4'b0000;
            end

            //------------------------------------------------------------------
            // JALR — indirect jump
            //------------------------------------------------------------------
            OP_JALR: begin
                reg_write_o = 1'b1;
                alu_src_o   = 1'b1;
                jump_o      = 1'b1;
                alu_op_o    = 4'b0000; // ADD rs1+imm for target
            end

            //------------------------------------------------------------------
            // LUI — load upper immediate
            //------------------------------------------------------------------
            OP_LUI: begin
                reg_write_o = 1'b1;
                alu_src_o   = 1'b1;
                alu_op_o    = 4'b1111; // pass-through immediate
            end

            //------------------------------------------------------------------
            // AUIPC — add upper immediate to PC
            //------------------------------------------------------------------
            OP_AUIPC: begin
                reg_write_o = 1'b1;
                alu_src_o   = 1'b1;
                alu_op_o    = 4'b0000; // ADD pc+imm
            end

            //------------------------------------------------------------------
            // CUSTOM-0 — SCNN Dispatch
            //   Assert scnn_enable to wake the accelerator.
            //   Assert pc_stall to freeze the pipeline via LCU.
            //   Hold stall until scnn_done_i clears it.
            //   reg_write deferred — will be re-asserted by accelerator handshake
            //   in the full SEC integration; for MVP we assert after done.
            //------------------------------------------------------------------
            OP_CUSTOM0: begin
                scnn_enable_o = 1'b1;
                pc_stall_o    = !scnn_done_i; // stall until accelerator says done
                reg_write_o   = scnn_done_i;  // write result back only when done
                alu_src_o     = 1'b1;         // pass base address via immediate
                alu_op_o      = 4'b0000;      // address = rs1 + imm
            end

            default: begin
                // NOP / unrecognised — all outputs stay at safe defaults
            end

        endcase
    end

endmodule
