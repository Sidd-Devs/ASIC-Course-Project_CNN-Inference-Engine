`timescale 1ns/1ps
/* ============================================================
   IEC - ENERGY-OPTIMIZED VERSION
   
   Optimizations applied:
   OPT-6: Gray-coded FSM states (reduces toggle on state register)
   OPT-7: Gated DRAM bus drivers (only drive when needed)
   OPT-8: Gated counter increments (warmup_cnt, iter_cnt, prefetch_cnt)
   OPT-9: Gated CU interface signals
   
   All optimizations preserve functional equivalence with original.
   ============================================================ */

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
    // OPT-6: Gray-coded FSM states
    // Binary:  IDLE=000 CONFIG=001 PREFETCH=010 COMPUTE=011 LAYER_SW=100 CLASSIFY=101 DONE=110
    // Gray:    IDLE=000 CONFIG=001 PREFETCH=011 COMPUTE=010 LAYER_SW=110 CLASSIFY=111 DONE=101
    // Gray coding minimizes bit transitions between sequential states,
    // reducing switching power on state register and decode logic.
    localparam logic [2:0] S_IDLE         = 3'b000;
    localparam logic [2:0] S_CONFIG       = 3'b001;
    localparam logic [2:0] S_PREFETCH     = 3'b011;
    localparam logic [2:0] S_COMPUTE      = 3'b010;
    localparam logic [2:0] S_LAYER_SWITCH = 3'b110;
    localparam logic [2:0] S_CLASSIFY     = 3'b111;
    localparam logic [2:0] S_DONE         = 3'b101;

    // KPU pipeline warmup
    localparam int WARMUP = 16 + N_PE + 4;
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
    logic [W_BITS-1:0]     warmup_cnt;
    wire                   warmup_done;
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
                    // OPT-8: Only increment warmup counter when not saturated
                    if (!warmup_done)
                        warmup_cnt <= warmup_cnt + 1'b1;

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

    // OPT-7: Gated DRAM bus drivers
    // Only drive KPU input/bias/weight buses when the respective data is needed.
    // When state is not PREFETCH/COMPUTE, force I bus to zero (prevents toggling).
    // When state is not CONFIG, force W and B buses to zero.
    wire i_bus_active = (state == S_PREFETCH || state == S_COMPUTE);
    wire w_bus_active = (state == S_CONFIG);

    genvar gi;
    generate
        for (gi = 0; gi < M; gi++) begin : I_BIAS_BUS
            // OPT-7a: Gate input bus - only drive when prefetching/computing
            assign kpu_I[gi*K    +: K] = i_bus_active ? dram_I_data : '0;
            // OPT-7b: Gate bias bus - only drive during config
            assign kpu_BIAS[gi*K +: K] = w_bus_active ? dram_B_data : '0;
        end
    endgenerate

    genvar gii, gjj;
    generate
        for (gii = 0; gii < M; gii++) begin : W_ROW
            for (gjj = 0; gjj < N_PE; gjj++) begin : W_COL
                // OPT-7c: Gate weight bus - only drive during config
                assign kpu_W[gii*N_PE*K + gjj*K +: K] = w_bus_active ? dram_W_data : '0;
            end
        end
    endgenerate

    assign dram_I_req     = (state == S_PREFETCH || state == S_COMPUTE);
    assign dram_W_req     = (state == S_CONFIG);
    assign dram_B_req     = (state == S_CONFIG);

    // OPT-9: Gate CU interface - only active during CLASSIFY state
    assign cu_AC_in       = (state == S_CLASSIFY) ? psum_reg[K-1:0] : '0;
    assign cu_valid       = (state == S_CLASSIFY) && (classify_cnt < r_N_classes);
    assign cu_l_is_FClast = (state == S_CLASSIFY);
    assign cu_N           = r_N_classes;

endmodule
