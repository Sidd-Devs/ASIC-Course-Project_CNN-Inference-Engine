`timescale 1ns/1ps
package pkg_IEC;
    parameter int K          = 16;
    parameter int M          = 9;
    parameter int N_PE       = 96;
    parameter int N_WIDTH    = 10;
    parameter int L_WIDTH    = 8;
    parameter int NL_WIDTH   = 16;
    parameter int COMP_WIDTH = 3;

    parameter logic [COMP_WIDTH-1:0] COMP_CONV    = 3'd0;
    parameter logic [COMP_WIDTH-1:0] COMP_FC      = 3'd1;
    parameter logic [COMP_WIDTH-1:0] COMP_MAXPOOL = 3'd2;
    parameter logic [COMP_WIDTH-1:0] COMP_AVGPOOL = 3'd3;
    parameter logic [COMP_WIDTH-1:0] COMP_RELU    = 3'd4;
    parameter logic [COMP_WIDTH-1:0] COMP_RELU6   = 3'd5;
endpackage

module IEC
import pkg_IEC::*;
(
    input  logic                   clk,
    input  logic                   rst,
    input  logic                   start,
    input  logic                   layer_config_valid,
    input  logic [L_WIDTH-1:0]     FClast,
    input  logic [N_WIDTH-1:0]     N_classes,
    input  logic [COMP_WIDTH-1:0]  layer_comp_type,
    input  logic [NL_WIDTH-1:0]    nl,
    input  logic [NL_WIDTH-1:0]    rl,
    input  logic [L_WIDTH-1:0]     layer_num,
    output logic                   done_interrupt,
    output logic                   layer_config_ack,
    output logic [N_WIDTH-1:0]     CN_DC_proc,
    output logic [2:0]             state_out,
    output logic [M*K-1:0]         kpu_BIAS,
    output logic [M*K-1:0]         kpu_I,
    output logic [M*N_PE*K-1:0]    kpu_W,
    input  logic signed [K+4-1:0]  kpu_AC_out,
    input  logic                   kpu_valid,
    output logic                   kpu_rst,
    output logic signed [K-1:0]    cu_AC_in,
    output logic                   cu_valid,
    output logic                   cu_l_is_FClast,
    output logic [N_WIDTH-1:0]     cu_N,
    input  logic [N_WIDTH-1:0]     cu_CN_DC,
    input  logic                   cu_result_valid,
    input  logic signed [K-1:0]    cu_AC_passthrough,
    input  logic                   cu_valid_passthrough,
    output logic                   cu_rst,
    input  logic signed [K-1:0]    dram_I_data,
    input  logic                   dram_I_valid,
    input  logic signed [K-1:0]    dram_W_data,
    input  logic                   dram_W_valid,
    input  logic signed [K-1:0]    dram_B_data,
    input  logic                   dram_B_valid,
    output logic                   dram_I_req,
    output logic                   dram_W_req,
    output logic                   dram_B_req
);
    localparam logic [2:0] S_IDLE         = 3'd0;
    localparam logic [2:0] S_CONFIG       = 3'd1;
    localparam logic [2:0] S_PREFETCH     = 3'd2;
    localparam logic [2:0] S_COMPUTE      = 3'd3;
    localparam logic [2:0] S_LAYER_SWITCH = 3'd4;
    localparam logic [2:0] S_CLASSIFY     = 3'd5;
    localparam logic [2:0] S_DONE         = 3'd6;

    // KPU pipeline warmup:
    // After kpu_rst deasserts, KPU needs Z (weight read) + N_PE-1 (Psum
    // chain) + 4 (MAC pipeline) cycles before conv_out is valid.
    localparam int WARMUP = 16 + N_PE + 4;   // Z=16 hardcoded (matches pkg_KPU::Z)
    localparam int W_BITS = $clog2(WARMUP + 1);

    logic [2:0]            state;
    assign state_out = state;

    logic [L_WIDTH-1:0]    r_FClast;
    logic [N_WIDTH-1:0]    r_N_classes;
    logic [COMP_WIDTH-1:0] r_comp_type;
    logic [NL_WIDTH-1:0]   r_nl;
    logic [NL_WIDTH-1:0]   r_rl;
    logic [L_WIDTH-1:0]    r_layer;
    logic [NL_WIDTH-1:0]   iter_cnt;
    logic [NL_WIDTH-1:0]   prefetch_cnt;
    logic signed [K+4-1:0] psum_reg;
    logic [N_WIDTH-1:0]    classify_cnt;
    logic [W_BITS-1:0]     warmup_cnt;    // counts cycles in COMPUTE
    wire                   warmup_done;   // conv_out valid after this
    assign warmup_done = (warmup_cnt >= W_BITS'(WARMUP));

    wire l_is_FClast = (r_layer == r_FClast);
    wire last_iter   = (iter_cnt == r_nl - 1'b1);

    always_ff @(posedge clk) begin
        if (rst) begin
            state            <= S_IDLE;
            iter_cnt         <= '0;
            prefetch_cnt     <= '0;
            psum_reg         <= '0;
            classify_cnt     <= '0;
            warmup_cnt       <= '0;
            done_interrupt   <= 1'b0;
            layer_config_ack <= 1'b0;
            CN_DC_proc       <= '0;
            kpu_rst          <= 1'b1;
            cu_rst           <= 1'b1;
        end else begin
            kpu_rst          <= 1'b0;
            cu_rst           <= 1'b0;
            layer_config_ack <= 1'b0;

            case (state)
                S_IDLE: begin
                    done_interrupt <= 1'b0;
                    classify_cnt   <= '0;
                    warmup_cnt     <= '0;
                    if (start) state <= S_CONFIG;
                end

                S_CONFIG: begin
                    if (layer_config_valid) begin
                        r_FClast         <= FClast;
                        r_N_classes      <= N_classes;
                        r_comp_type      <= layer_comp_type;
                        r_nl             <= nl;
                        r_rl             <= rl;
                        r_layer          <= layer_num;
                        iter_cnt         <= '0;
                        prefetch_cnt     <= '0;
                        classify_cnt     <= '0;
                        warmup_cnt       <= '0;
                        psum_reg         <= '0;
                        kpu_rst          <= 1'b1;
                        layer_config_ack <= 1'b1;
                        state            <= S_PREFETCH;
                    end
                end

                S_PREFETCH: begin
                    if (dram_I_valid) begin
                        prefetch_cnt <= prefetch_cnt + 1'b1;
                        if (prefetch_cnt >= r_rl - 1'b1)
                            state <= S_COMPUTE;
                    end
                end

                S_COMPUTE: begin
                    // Always increment warmup counter until saturated
                    if (!warmup_done)
                        warmup_cnt <= warmup_cnt + 1'b1;

                    // Only capture result and advance iter AFTER pipeline warm
                    if (kpu_valid && warmup_done) begin
                        psum_reg <= kpu_AC_out;
                        if (last_iter) begin
                            if (l_is_FClast) state <= S_CLASSIFY;
                            else             state <= S_LAYER_SWITCH;
                        end else
                            iter_cnt <= iter_cnt + 1'b1;
                    end
                end

                S_LAYER_SWITCH: begin
                    kpu_rst      <= 1'b1;
                    iter_cnt     <= '0;
                    prefetch_cnt <= '0;
                    warmup_cnt   <= '0;
                    psum_reg     <= '0;
                    state        <= S_CONFIG;
                end

                S_CLASSIFY: begin
                    if (classify_cnt < r_N_classes)
                        classify_cnt <= classify_cnt + 1'b1;
                    if (cu_result_valid) begin
                        CN_DC_proc <= cu_CN_DC;
                        state      <= S_DONE;
                    end
                end

                S_DONE: begin
                    done_interrupt <= 1'b1;
                    cu_rst         <= 1'b1;
                    classify_cnt   <= '0;
                    warmup_cnt     <= '0;
                    if (!start) state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    genvar gi;
    generate
        for (gi = 0; gi < M; gi++) begin : I_BIAS_BUS
            assign kpu_I[gi*K    +: K] = dram_I_data;
            assign kpu_BIAS[gi*K +: K] = dram_B_data;
        end
    endgenerate

    genvar gii, gjj;
    generate
        for (gii = 0; gii < M; gii++) begin : W_ROW
            for (gjj = 0; gjj < N_PE; gjj++) begin : W_COL
                assign kpu_W[gii*N_PE*K + gjj*K +: K] = dram_W_data;
            end
        end
    endgenerate

    assign dram_I_req     = (state == S_PREFETCH || state == S_COMPUTE);
    assign dram_W_req     = (state == S_CONFIG);
    assign dram_B_req     = (state == S_CONFIG);
    assign cu_AC_in       = psum_reg[K-1:0];
    assign cu_valid       = (state == S_CLASSIFY) && (classify_cnt < r_N_classes);
    assign cu_l_is_FClast = (state == S_CLASSIFY);
    assign cu_N           = r_N_classes;

endmodule