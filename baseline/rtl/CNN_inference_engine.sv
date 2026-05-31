`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 15.03.2026 17:58:31
// Design Name: 
// Module Name: CNN_inference_engine
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

/* ============================================================
   CNN_Inference_Engine - Full Integration (Paper Fig.1)
   
   Connects IEC + KPU_cluster + CU into complete inference engine.
   
   Signal routing (paper Fig.1):
     Processor ? IEC ? KPU
                 IEC ? CU
                 IEC ? DRAM
   
   All three sub-modules use separate packages but consistent
   parameters: K=16, M=9, N_PE=6, N_WIDTH=10.
   ============================================================ */

module CNN_Inference_Engine
import pkg_IEC::*;
(
    input  logic                   clk,
    input  logic                   rst,

    // Processor interface
    input  logic                   start,
    input  logic                   layer_config_valid,
    output logic                   layer_config_ack,
    input  logic [L_WIDTH-1:0]     FClast,
    input  logic [N_WIDTH-1:0]     N_classes,
    input  logic [COMP_WIDTH-1:0]  layer_comp_type,
    input  logic [NL_WIDTH-1:0]    nl,
    input  logic [NL_WIDTH-1:0]    rl,
    input  logic [L_WIDTH-1:0]     layer_num,
    output logic                   done_interrupt,
    output logic [N_WIDTH-1:0]     CN_DC_out,
    output logic [2:0]             state_out,       // IEC state for monitoring

    // DRAM interface
    input  logic signed [K-1:0]    dram_I_data,
    input  logic                   dram_I_valid,
    output logic                   dram_I_req,
    input  logic signed [K-1:0]    dram_W_data,
    input  logic                   dram_W_valid,
    output logic                   dram_W_req,
    input  logic signed [K-1:0]    dram_B_data,
    input  logic                   dram_B_valid,
    output logic                   dram_B_req
);

    // ---- IEC ? KPU wires ----------------------------------------
    wire [M*K-1:0]         kpu_BIAS;
    wire [M*K-1:0]         kpu_I;
    wire [M*N_PE*K-1:0]    kpu_W;
    wire                   kpu_rst;

    // ---- KPU ? IEC wires ----------------------------------------
    wire signed [K+4-1:0]  kpu_AC_out;
    wire                   kpu_valid;

    // ---- IEC ? CU wires -----------------------------------------
    wire signed [K-1:0]    cu_AC_in;
    wire                   cu_valid;
    wire                   cu_l_is_FClast;
    wire [N_WIDTH-1:0]     cu_N;
    wire                   cu_rst;

    // ---- CU ? IEC wires -----------------------------------------
    wire [N_WIDTH-1:0]     cu_CN_DC;
    wire                   cu_result_valid;
    wire signed [K-1:0]    cu_AC_passthrough;
    wire                   cu_valid_passthrough;

    // ---- IEC instantiation --------------------------------------
    IEC iec_inst (
        .clk                 (clk),
        .rst                 (rst),
        .start               (start),
        .layer_config_valid  (layer_config_valid),
        .FClast              (FClast),
        .N_classes           (N_classes),
        .layer_comp_type     (layer_comp_type),
        .nl                  (nl),
        .rl                  (rl),
        .layer_num           (layer_num),
        .done_interrupt      (done_interrupt),
        .layer_config_ack    (layer_config_ack),
        .CN_DC_proc          (CN_DC_out),
        .state_out           (state_out),
        .kpu_BIAS            (kpu_BIAS),
        .kpu_I               (kpu_I),
        .kpu_W               (kpu_W),
        .kpu_AC_out          (kpu_AC_out),
        .kpu_valid           (kpu_valid),
        .kpu_rst             (kpu_rst),
        .cu_AC_in            (cu_AC_in),
        .cu_valid            (cu_valid),
        .cu_l_is_FClast      (cu_l_is_FClast),
        .cu_N                (cu_N),
        .cu_CN_DC            (cu_CN_DC),
        .cu_result_valid     (cu_result_valid),
        .cu_AC_passthrough   (cu_AC_passthrough),
        .cu_valid_passthrough(cu_valid_passthrough),
        .cu_rst              (cu_rst),
        .dram_I_data         (dram_I_data),
        .dram_I_valid        (dram_I_valid),
        .dram_W_data         (dram_W_data),
        .dram_W_valid        (dram_W_valid),
        .dram_B_data         (dram_B_data),
        .dram_B_valid        (dram_B_valid),
        .dram_I_req          (dram_I_req),
        .dram_W_req          (dram_W_req),
        .dram_B_req          (dram_B_req)
    );

    // ---- KPU instantiation --------------------------------------
    KPU_cluster kpu_inst (
        .clk             (clk),
        .rst             (kpu_rst),
        .BIAS_Bus_packed (kpu_BIAS),
        .LM_INPUTS_packed(kpu_I),
        .WEIGHTS_packed  (kpu_W),
        .conv_out        (kpu_AC_out)
    );

    // KPU valid: KPU_cluster produces output continuously once running.
    // IEC needs a valid pulse to latch each result.
    // The KPU KPC state machine signals computation via stride_req.
    // For integration, we generate a valid signal from the KPU's
    // load_done flag (KPC enters COMPUTE after LOAD).
    assign kpu_valid = kpu_inst.load_done;

    // ---- CU instantiation ---------------------------------------
    CU cu_inst (
        .clk         (clk),
        .rst         (cu_rst),
        .AC_Psum_in  (cu_AC_in),
        .valid_in    (cu_valid),
        .l_is_FClast (cu_l_is_FClast),
        .N           (cu_N),
        .AC_out      (cu_AC_passthrough),
        .valid_out   (cu_valid_passthrough),
        .CN_DC_out   (cu_CN_DC),
        .result_valid(cu_result_valid)
    );

endmodule