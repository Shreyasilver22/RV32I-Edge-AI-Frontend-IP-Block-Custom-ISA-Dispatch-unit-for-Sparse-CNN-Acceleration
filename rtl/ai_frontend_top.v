`timescale 1ns / 1ps
//==============================================================================
// Module  : ai_frontend_top
// Project : RV32I Edge-AI Processor — Frontend IP
// Author  : Shreyas
// Target  : Vivado / Artix-7 / Zynq
//
// Description:
//   Top-level wrapper for the Hackathon MVP Frontend IP Block.
//   Integrates:
//     1. instruction_fetch      — PC logic, IMEM address
//     2. decode_parser_immgen   — field extraction + immediate generation
//     3. control_unit_ai        — datapath controls + SCNN dispatch
//     4. mock_scnn_mac          — dummy AI accelerator (dot-product stub)
//
//   Internal instruction memory (IMEM) is a 256×32-bit ROM initialized
//   from INSTR_FILE parameter (default: "imem_init.mem").
//   This makes the design fully self-contained for simulation and
//   Vivado synthesis without external memory controllers.
//
//   The AI accelerator data ports are exposed at the top level so the
//   testbench (and, in Phase 2, Kirti's SRAM buffer) can inject operands.
//
// Parameters:
//   IMEM_DEPTH   — number of 32-bit instruction slots (default 256)
//   INSTR_FILE   — path to $readmemh initialization file
//   DATA_WIDTH   — MAC operand element width (default 8)
//   VEC_LEN      — MAC dot-product vector length (default 8)
//   MAC_LATENCY  — mock MAC latency in cycles (default 8)
//
// Key observable signals (connect to ILA / testbench probes):
//   pc_o           — current program counter
//   instr_o        — instruction word at current PC
//   opcode_o       — decoded opcode field
//   scnn_enable_o  — HIGH when SCNN dispatch is active  ← MAIN DEMO SIGNAL
//   pc_stall_o     — HIGH while pipeline is frozen
//   scnn_done_o    — pulse when accelerator result is ready
//   mac_result_o   — 32-bit dot-product result
//==============================================================================

module ai_frontend_top #(
    parameter IMEM_DEPTH  = 256,
    parameter INSTR_FILE  = "imem_init.mem",
    parameter DATA_WIDTH  = 8,
    parameter VEC_LEN     = 8,
    parameter MAC_LATENCY = 8
)(
    input  wire        clk_i,
    input  wire        rst_i,

    // Branch/Jump inputs (from Execute stage in Phase 2; tie LOW for MVP)
    input  wire        branch_en_i,
    input  wire [31:0] branch_pc_i,

    // AI accelerator operand inputs
    // (from Kirti's SRAM buffer in Phase 2; driven by testbench for MVP)
    input  wire [(DATA_WIDTH*VEC_LEN)-1 : 0] mac_data_a_i,
    input  wire [(DATA_WIDTH*VEC_LEN)-1 : 0] mac_data_b_i,

    // Observable outputs (connect to Vivado ILA probes or testbench)
    output wire [31:0] pc_o,
    output wire [31:0] instr_o,
    output wire [6:0]  opcode_o,
    output wire [4:0]  rd_o,
    output wire [2:0]  funct3_o,
    output wire [4:0]  rs1_o,
    output wire [4:0]  rs2_o,
    output wire [6:0]  funct7_o,
    output wire [31:0] imm_o,
    output wire        is_custom_o,

    // Control signals
    output wire        reg_write_o,
    output wire        alu_src_o,
    output wire        mem_write_o,
    output wire        mem_read_o,
    output wire        mem_to_reg_o,
    output wire        branch_o,
    output wire        jump_o,
    output wire [3:0]  alu_op_o,

    // AI dispatch signals — primary demo outputs
    output wire        scnn_enable_o,
    output wire        pc_stall_o,
    output wire        scnn_done_o,
    output wire [31:0] mac_result_o
);

    //--------------------------------------------------------------------------
    // Internal instruction memory (ROM)
    // Synthesises as BRAM or distributed RAM in Vivado
    //--------------------------------------------------------------------------
    reg [31:0] imem [0 : IMEM_DEPTH-1];

    initial begin
        $readmemh(INSTR_FILE, imem);
    end

    // Internal wires
    wire [31:0] imem_addr;
    wire [31:0] imem_data;

    // Synchronous read (matches Vivado BRAM inference; 1-cycle latency)
    // For simulation accuracy the testbench clock period must be > combinational delay
    reg [31:0] imem_data_reg;
    always @(posedge clk_i) begin
        imem_data_reg <= imem[imem_addr[31:2]]; // word-addressed (ignore [1:0])
    end
    assign imem_data = imem_data_reg;
    assign instr_o   = imem_data;

    //--------------------------------------------------------------------------
    // Stage 1 — Instruction Fetch
    //--------------------------------------------------------------------------
    instruction_fetch u_if (
        .clk_i       (clk_i),
        .rst_i       (rst_i),
        .stall_i     (pc_stall_o),      // from control unit LCU
        .branch_en_i (branch_en_i),
        .branch_pc_i (branch_pc_i),
        .pc_o        (pc_o),
        .imem_addr_o (imem_addr)
    );

    //--------------------------------------------------------------------------
    // Stage 2a — Decode + Immediate Generator
    //--------------------------------------------------------------------------
    decode_parser_immgen u_decode (
        .instr_i     (imem_data),
        .opcode_o    (opcode_o),
        .rd_o        (rd_o),
        .funct3_o    (funct3_o),
        .rs1_o       (rs1_o),
        .rs2_o       (rs2_o),
        .funct7_o    (funct7_o),
        .imm_o       (imm_o),
        .is_custom_o (is_custom_o)
    );

    //--------------------------------------------------------------------------
    // Stage 2b — Control Unit + LCU
    //--------------------------------------------------------------------------
    control_unit_ai u_ctrl (
        .opcode_i      (opcode_o),
        .funct3_i      (funct3_o),
        .funct7_i      (funct7_o),
        .scnn_done_i   (scnn_done_o),   // feedback from MAC
        .reg_write_o   (reg_write_o),
        .alu_src_o     (alu_src_o),
        .mem_write_o   (mem_write_o),
        .mem_read_o    (mem_read_o),
        .mem_to_reg_o  (mem_to_reg_o),
        .branch_o      (branch_o),
        .jump_o        (jump_o),
        .alu_op_o      (alu_op_o),
        .scnn_enable_o (scnn_enable_o),
        .pc_stall_o    (pc_stall_o)
    );

    //--------------------------------------------------------------------------
    // Mock SCNN MAC — AI Accelerator Stub
    //--------------------------------------------------------------------------
    mock_scnn_mac #(
        .DATA_WIDTH     (DATA_WIDTH),
        .VEC_LEN        (VEC_LEN),
        .LATENCY_CYCLES (MAC_LATENCY)
    ) u_mac (
        .clk_i         (clk_i),
        .rst_i         (rst_i),
        .scnn_enable_i (scnn_enable_o),
        .data_a_i      (mac_data_a_i),
        .data_b_i      (mac_data_b_i),
        .result_o      (mac_result_o),
        .scnn_done_o   (scnn_done_o)
    );

endmodule
