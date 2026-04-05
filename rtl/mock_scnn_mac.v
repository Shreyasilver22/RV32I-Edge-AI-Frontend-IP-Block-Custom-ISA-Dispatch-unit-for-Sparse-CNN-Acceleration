`timescale 1ns / 1ps
//==============================================================================
// Module  : mock_scnn_mac
// Project : RV32I Edge-AI Processor — Frontend IP
// Author  : Shreyas
// Target  : Vivado / Artix-7 / Zynq
//
// Description:
//   Hackathon MVP — Mock Sparse CNN Multiply-Accumulate block.
//
//   This module is a SYNTHESIZABLE STUB that proves the dispatch mechanism:
//   when scnn_enable_i is asserted, it performs a simple 8×8 dot-product
//   over two input vectors (simulating one row of a matrix multiply).
//   It asserts scnn_done_o after a configurable number of clock cycles
//   (LATENCY_CYCLES parameter, default 8 to simulate pipeline depth).
//
//   In the SEC final project, this module is REPLACED 1:1 with the real
//   Systolic Array (same port names, same handshake protocol).
//
//   Handshake protocol (ready/valid inspired):
//     1. Dispatcher asserts scnn_enable_i + presents operands on data_a_i / data_b_i
//     2. MAC latches operands, begins accumulation, holds scnn_done_o LOW
//     3. After LATENCY_CYCLES, MAC asserts scnn_done_o + presents result on result_o
//     4. Dispatcher deasserts scnn_enable_i, MAC resets ready for next instruction
//
// Parameters:
//   DATA_WIDTH     — bit width of each operand element (default 8-bit int8)
//   VEC_LEN        — number of elements in the dot-product vector (default 8)
//   LATENCY_CYCLES — simulated compute latency in clock cycles (default 8)
//
// Ports:
//   clk_i          — system clock
//   rst_i          — synchronous reset, active-high
//   scnn_enable_i  — start signal from control unit
//   data_a_i       — flattened input vector A  [DATA_WIDTH*VEC_LEN-1 : 0]
//   data_b_i       — flattened weight vector B [DATA_WIDTH*VEC_LEN-1 : 0]
//   result_o       — 32-bit accumulation result
//   scnn_done_o    — HIGH for 1 cycle when result is valid
//==============================================================================

module mock_scnn_mac #(
    parameter DATA_WIDTH     = 8,
    parameter VEC_LEN        = 8,
    parameter LATENCY_CYCLES = 8
)(
    input  wire                              clk_i,
    input  wire                              rst_i,
    input  wire                              scnn_enable_i,
    input  wire [(DATA_WIDTH*VEC_LEN)-1 : 0] data_a_i,
    input  wire [(DATA_WIDTH*VEC_LEN)-1 : 0] data_b_i,
    output reg  [31:0]                        result_o,
    output reg                                scnn_done_o
);

    //--------------------------------------------------------------------------
    // Internal registers
    //--------------------------------------------------------------------------
    // Latency counter
    reg [$clog2(LATENCY_CYCLES+1)-1 : 0] lat_cnt;

    // Latch operands when enable fires
    reg [(DATA_WIDTH*VEC_LEN)-1 : 0] a_reg;
    reg [(DATA_WIDTH*VEC_LEN)-1 : 0] b_reg;

    // Running accumulator (wide enough for worst case: 8b × 8b × 8 = 21 bits)
    reg [31:0] acc;

    // State machine
    localparam IDLE    = 2'b00;
    localparam COMPUTE = 2'b01;
    localparam DONE    = 2'b10;
    reg [1:0] state;

    //--------------------------------------------------------------------------
    // Dot product computation (unrolled, synthesises to LUT chain in Vivado)
    // acc = Σ (a[i] × b[i]) for i in 0..VEC_LEN-1
    // Using signed multiplication to model int8 inference weights
    //--------------------------------------------------------------------------
    integer i;
    reg [31:0] dot_product;

    always @(*) begin
        dot_product = 32'd0;
        for (i = 0; i < VEC_LEN; i = i + 1) begin
            dot_product = dot_product +
                ($signed(a_reg[i*DATA_WIDTH +: DATA_WIDTH]) *
                 $signed(b_reg[i*DATA_WIDTH +: DATA_WIDTH]));
        end
    end

    //--------------------------------------------------------------------------
    // State machine + latency counter
    //--------------------------------------------------------------------------
    always @(posedge clk_i) begin
        if (rst_i) begin
            state       <= IDLE;
            lat_cnt     <= 0;
            result_o    <= 32'd0;
            scnn_done_o <= 1'b0;
            a_reg       <= 0;
            b_reg       <= 0;
            acc         <= 32'd0;
        end else begin
            scnn_done_o <= 1'b0; // default: done is a 1-cycle pulse

            case (state)
                //--------------------------------------------------------------
                IDLE: begin
                    if (scnn_enable_i) begin
                        a_reg   <= data_a_i;   // latch operands
                        b_reg   <= data_b_i;
                        lat_cnt <= 0;
                        acc     <= 32'd0;
                        state   <= COMPUTE;
                    end
                end

                //--------------------------------------------------------------
                COMPUTE: begin
                    // Simulate pipelined MAC: accumulate one element per cycle
                    // (in reality a systolic array would process all in parallel;
                    //  this models a simpler sequential accumulator for the MVP)
                    if (lat_cnt < LATENCY_CYCLES - 1) begin
                        lat_cnt <= lat_cnt + 1;
                        // Partial accumulation for waveform visibility
                        acc <= acc + ($signed(
                            a_reg[lat_cnt * DATA_WIDTH +: DATA_WIDTH]) *
                            $signed(b_reg[lat_cnt * DATA_WIDTH +: DATA_WIDTH]));
                    end else begin
                        // Final cycle — compute full dot product and latch result
                        result_o    <= dot_product;
                        scnn_done_o <= 1'b1;
                        state       <= DONE;
                    end
                end

                //--------------------------------------------------------------
                DONE: begin
                    // Hold result for one cycle, return to IDLE
                    // (control unit samples scnn_done_o and deasserts pc_stall)
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
