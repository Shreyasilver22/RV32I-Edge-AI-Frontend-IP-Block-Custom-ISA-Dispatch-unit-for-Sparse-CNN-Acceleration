`timescale 1ns / 1ps
//==============================================================================
// Module  : decode_parser_immgen
// Project : RV32I Edge-AI Processor — Frontend IP
// Author  : Shreyas
// Target  : Vivado / Artix-7 / Zynq
//
// Description:
//   Stage 2 — Instruction Decode + Immediate Generator.
//   Slices the 32-bit RV32I instruction word into its constituent fields and
//   sign-extends the immediate value according to the instruction format.
//
//   Supported RV32I formats:
//     R-type  — register-register ops (ADD, SUB, AND, OR, …)
//     I-type  — register-immediate + loads + JALR
//     S-type  — stores
//     B-type  — conditional branches
//     U-type  — LUI, AUIPC
//     J-type  — JAL
//     CUSTOM  — opcode 7'b0001011 (custom-0 space) = SCNN dispatch
//
//   The immediate generator always produces a 32-bit sign-extended value.
//   The control unit (separate module) decides which immediate to actually use.
//
// Ports:
//   instr_i     — 32-bit instruction from IMEM
//   opcode_o    — bits [6:0]
//   rd_o        — destination register  [11:7]
//   funct3_o    — function code         [14:12]
//   rs1_o       — source register 1     [19:15]
//   rs2_o       — source register 2     [24:20]
//   funct7_o    — function code         [31:25]
//   imm_o       — sign-extended immediate (format selected by opcode)
//   is_custom_o — HIGH when opcode == CUSTOM_0 (triggers SCNN dispatch)
//==============================================================================

module decode_parser_immgen (
    input  wire [31:0] instr_i,

    output wire [6:0]  opcode_o,
    output wire [4:0]  rd_o,
    output wire [2:0]  funct3_o,
    output wire [4:0]  rs1_o,
    output wire [4:0]  rs2_o,
    output wire [6:0]  funct7_o,
    output reg  [31:0] imm_o,
    output wire        is_custom_o
);

    //--------------------------------------------------------------------------
    // Standard RV32I opcode definitions
    //--------------------------------------------------------------------------
    localparam OP_LOAD    = 7'b000_0011;  // LB, LH, LW, LBU, LHU  (I-type)
    localparam OP_STORE   = 7'b010_0011;  // SB, SH, SW             (S-type)
    localparam OP_BRANCH  = 7'b110_0011;  // BEQ, BNE, BLT …        (B-type)
    localparam OP_JAL     = 7'b110_1111;  // JAL                     (J-type)
    localparam OP_JALR    = 7'b110_0111;  // JALR                    (I-type)
    localparam OP_LUI     = 7'b011_0111;  // LUI                     (U-type)
    localparam OP_AUIPC   = 7'b001_0111;  // AUIPC                   (U-type)
    localparam OP_IMM     = 7'b001_0011;  // ADDI, SLTI, …           (I-type)
    localparam OP_REG     = 7'b011_0011;  // ADD, SUB, AND, …        (R-type)
    localparam OP_CUSTOM0 = 7'b000_1011;  // SCNN dispatch           (custom-0)

    //--------------------------------------------------------------------------
    // Field extraction (purely combinational)
    //--------------------------------------------------------------------------
    assign opcode_o = instr_i[6:0];
    assign rd_o     = instr_i[11:7];
    assign funct3_o = instr_i[14:12];
    assign rs1_o    = instr_i[19:15];
    assign rs2_o    = instr_i[24:20];
    assign funct7_o = instr_i[31:25];

    // Custom instruction flag
    assign is_custom_o = (instr_i[6:0] == OP_CUSTOM0);

    //--------------------------------------------------------------------------
    // Immediate generator — sign-extension per RV32I spec
    //--------------------------------------------------------------------------
    always @(*) begin
        case (instr_i[6:0])

            OP_IMM,
            OP_LOAD,
            OP_JALR:  // I-type: imm[11:0] sign-extended
                imm_o = {{20{instr_i[31]}}, instr_i[31:20]};

            OP_STORE: // S-type: imm[11:5|4:0] sign-extended
                imm_o = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};

            OP_BRANCH: // B-type: imm[12|10:5|4:1|11] × 2
                imm_o = {{19{instr_i[31]}}, instr_i[31],
                          instr_i[7], instr_i[30:25], instr_i[11:8], 1'b0};

            OP_LUI,
            OP_AUIPC: // U-type: imm[31:12] << 12
                imm_o = {instr_i[31:12], 12'b0};

            OP_JAL:   // J-type: imm[20|10:1|11|19:12] × 2
                imm_o = {{11{instr_i[31]}}, instr_i[31],
                          instr_i[19:12], instr_i[20], instr_i[30:21], 1'b0};

            OP_CUSTOM0: // custom-0: treat as I-type immediate (rs1 + imm → matrix base addr)
                imm_o = {{20{instr_i[31]}}, instr_i[31:20]};

            default:  // R-type, unrecognised — immediate unused
                imm_o = 32'b0;
        endcase
    end

endmodule
