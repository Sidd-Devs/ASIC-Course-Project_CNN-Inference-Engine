`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 15.03.2026 16:13:33
// Design Name: 
// Module Name: kpu
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
   KPU - Complete self-contained implementation
   ALL modules in one file to avoid Vivado picking up stale
   definitions from other files in the project.
   ============================================================ */

// ============================================================
// Package
// ============================================================
package pkg_KPU;
    parameter int M           = 9;
    parameter int M_Bit_Width = 4;
    parameter int N           = 96;
    parameter int N_Bit_Width = 7;
    parameter int K           = 16;
    parameter int Z           = 16;
    parameter int Z_Bit_Width = 4;
    parameter int A           = 128;
    parameter int A_Bit_Width = 7;
endpackage


// ============================================================
// KPC - LOAD/COMPUTE FSM
// LOAD  : Wr_Rr=2'b10 (WE=1,RE=0) for Z cycles - fills PE weight memories
// COMPUTE: Wr_Rr=2'b01 (WE=0,RE=1) - PE reads weights, sends stride requests
// ============================================================
module KPC
import pkg_KPU::*;
(
    input  logic        clk,
    input  logic        rst,
    input  logic [M-1:0] stride_req,      // packed: bit[i] from PE[i][0]
    output logic [1:0]  Wr_Rr,
    output logic [M-1:0] Next_Stride,     // packed: bit[i] to LM[i]
    output logic        Write_Selector,
    output logic        Read_Selector,
    output logic        load_done
);
    typedef enum logic { LOAD, COMPUTE } state_t;
    state_t                  state;
    logic [Z_Bit_Width-1:0]  load_cnt;

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= LOAD;
            load_cnt  <= '0;
            load_done <= 1'b0;
        end else begin
            case (state)
                LOAD: begin
                    if (load_cnt == Z_Bit_Width'(Z - 1)) begin
                        state     <= COMPUTE;
                        load_done <= 1'b1;
                    end else
                        load_cnt <= load_cnt + 1'b1;
                end
                COMPUTE: load_done <= 1'b1;
            endcase
        end
    end

    assign Wr_Rr          = (state == LOAD) ? 2'b10 : 2'b01;
    assign Write_Selector = (state == LOAD);
    assign Read_Selector  = (state == COMPUTE);

    genvar r;
    generate
        for (r = 0; r < M; r++) begin : NS_GEN
            assign Next_Stride[r] = (state == COMPUTE) ? stride_req[r] : 1'b0;
        end
    endgenerate
endmodule


// ============================================================
// Line_Memory
// Output is PACKED: O_packed[j*K +: K] = data item for column j
// ============================================================
module Line_Memory
import pkg_KPU::*;
(
    input  logic                   clk,
    input  logic                   rst,
    input  logic signed [K-1:0]    I,            // incoming feature map element
    input  logic                   Write_Selector,
    input  logic                   Read_Selector,
    input  logic                   Next_Stride,
    output logic [N*K-1:0]         O_packed      // N outputs packed: [j*K +: K] = col j
);
    logic signed [K-1:0]    mem       [0:A-1];
    logic [A_Bit_Width-1:0] wag_addr;
    logic [A_Bit_Width-1:0] read_base;

    // Initialise to avoid X in simulation
    integer ii;
    initial begin
        for (ii = 0; ii < A; ii = ii + 1)
            mem[ii] = '0;
    end

    // WAG - synchronous write
    always_ff @(posedge clk) begin
        if (rst) begin
            wag_addr <= '0;
        end else if (Write_Selector) begin
            mem[wag_addr] <= I;
            wag_addr      <= (wag_addr == A_Bit_Width'(A-1))
                             ? '0 : wag_addr + 1'b1;
        end
    end

    // RAG - advances read_base on each Next_Stride
    always_ff @(posedge clk) begin
        if (rst) read_base <= '0;
        else if (Read_Selector && Next_Stride)
            read_base <= (read_base == A_Bit_Width'(A-1))
                         ? '0 : read_base + 1'b1;
    end

    // Output buffer - N combinational reads, fully packed
    genvar p;
    generate
        for (p = 0; p < N; p++) begin : OUT_BUF
            assign O_packed[p*K +: K] = Read_Selector
                ? mem[(read_base + A_Bit_Width'(p)) % A]
                : '0;
        end
    endgenerate
endmodule


// ============================================================
// PE_core
// Single K-bit input I_sel (Ix mux done at KPU level).
// All MAC/MAX/MIN/SZD/AGU logic matches paper Fig.4.
// ============================================================
module PE_core
import pkg_KPU::*;
(
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    S_Ovd,
    input  logic signed [K-1:0]     I_sel,       // pre-selected feature input
    input  logic signed [K-1:0]     B_Psum,      // bias (col 0) or prev Psum
    input  logic [1:0]              Wr_Rr,       // [1]=WE  [0]=RE
    input  logic signed [K-1:0]     W,           // weight from external bus
    input  logic [2*Z_Bit_Width:0]  R6_r_Delta,  // {R6, r[3:0], Delta[3:0]}
    input  logic                    MAC_MAX,     // 1=MAC path, 0=MAX path
    output logic signed [K-1:0]     Psum,
    output logic                    Stride_Request
);
    // ---- Input register + SZD -----------------------------------------
    logic signed [K-1:0] input_reg;
    wire SZD_enb = S_Ovd ? 1'b0 : (input_reg <= 0);

    always_ff @(posedge clk) begin
        if (rst)                  input_reg <= '0;
        else if (Stride_Request)  input_reg <= I_sel;
    end

    wire signed [K-1:0] Null_Mux_Out = SZD_enb ? '0 : input_reg;

    // ---- Decode R6_r_Delta --------------------------------------------
    wire                    R6    = R6_r_Delta[2*Z_Bit_Width];
    wire [Z_Bit_Width-1:0]  r_val = R6_r_Delta[2*Z_Bit_Width-1 : Z_Bit_Width];
    wire [Z_Bit_Width-1:0]  Delta = R6_r_Delta[Z_Bit_Width-1:0];

    // ---- AGU_Write ----------------------------------------------------
    logic [Z_Bit_Width-1:0] WA;
    wire WE = Wr_Rr[1];

    always_ff @(posedge clk) begin
        if (rst)
            WA <= '0;
        else if (WE && (WA == Delta - 1'b1))
            WA <= '0;
        else if (WE)
            WA <= WA + 1'b1;
    end

    // ---- AGU_Read + IDM -----------------------------------------------
    logic [Z_Bit_Width-1:0] RA;
    wire IDM_out = (WA >= r_val);
    wire RE      = IDM_out && Wr_Rr[0];

    assign Stride_Request = RE && (RA == Delta - 1'b1);

    always_ff @(posedge clk) begin
        if (rst || Stride_Request)  RA <= '0;
        else if (RE)                RA <= RA + 1'b1;
    end

    // ---- Weight memory (async read, sync write) -----------------------
    logic signed [K-1:0] wmem [0:Z-1];
    integer wi;
    initial for (wi = 0; wi < Z; wi = wi + 1) wmem[wi] = '0;

    always_ff @(posedge clk)
        if (WE) wmem[WA] <= W;

    wire signed [K-1:0] Dout = RE ? wmem[RA] : '0;

    // ---- MAC ----------------------------------------------------------
    wire signed [K-1:0]   wg  = (~SZD_enb) ? Dout         : '0;
    wire signed [K-1:0]   ig  = (~SZD_enb) ? Null_Mux_Out : '0;
    wire signed [2*K-1:0] mp  = wg * ig;
    logic signed [K-1:0]  mpr;
    always_ff @(posedge clk) mpr <= mp[2*K-1:K];
    wire signed [K-1:0] Mac_Out = mpr + B_Psum;

    // ---- MIN (ReLU6 clip) --------------------------------------------
    wire signed [K-1:0] six     = 16'sd6;
    wire signed [K-1:0] Min_Out = (R6 && (Mac_Out > six)) ? six : Mac_Out;

    // ---- MAX (MaxPool) -----------------------------------------------
    wire signed [K-1:0] Max_Out =
        (Null_Mux_Out >= B_Psum) ? Null_Mux_Out : B_Psum;

    // ---- Output register ---------------------------------------------
    always_ff @(posedge clk)
        Psum <= MAC_MAX ? Min_Out : Max_Out;

endmodule


// ============================================================
// KPU_cluster - top level
// All internal buses are packed vectors.
// No unpacked array ports anywhere.
// ============================================================
module KPU_cluster
import pkg_KPU::*;
(
    input  logic                   clk,
    input  logic                   rst,
    // Packed input buses - caller packs: bus[i*K +: K] = row i value
    input  logic [M*K-1:0]         BIAS_Bus_packed,
    input  logic [M*K-1:0]         LM_INPUTS_packed,
    // Weights packed: [i*N*K + j*K +: K] = weight for PE[i][j]
    input  logic [M*N*K-1:0]       WEIGHTS_packed,
    output logic signed [K+4-1:0]  conv_out
);
    // ---- KPC ----------------------------------------------------------
    logic [1:0]   kpc_Wr_Rr;
    logic [M-1:0] kpc_Next_Stride;
    logic         kpc_Write_Sel, kpc_Read_Sel, load_done;
    logic [M-1:0] stride_req;

    KPC kpc_inst (
        .clk(clk), .rst(rst),
        .stride_req(stride_req),
        .Wr_Rr(kpc_Wr_Rr),
        .Next_Stride(kpc_Next_Stride),
        .Write_Selector(kpc_Write_Sel),
        .Read_Selector(kpc_Read_Sel),
        .load_done(load_done)
    );

    // ---- Line Memories ------------------------------------------------
    // feature_packed[r*N*K + j*K +: K] = LM[r].O[j]
    logic [M*N*K-1:0] feature_packed;

    genvar r;
    generate
        for (r = 0; r < M; r++) begin : LM_ROWS
            Line_Memory lm_inst (
                .clk(clk),
                .rst(rst),
                .I(LM_INPUTS_packed[r*K +: K]),
                .Write_Selector(kpc_Write_Sel),
                .Read_Selector(kpc_Read_Sel),
                .Next_Stride(kpc_Next_Stride[r]),
                .O_packed(feature_packed[r*N*K +: N*K])
            );
        end
    endgenerate

    // ---- PE array -----------------------------------------------------
    // psum_packed[i*N*K + j*K +: K] = Psum output of PE[i][j]
    logic [M*N*K-1:0] psum_packed;

    genvar i, j;
    generate
        for (i = 0; i < M; i++) begin : PE_ROW
            for (j = 0; j < N; j++) begin : PE_COL

                // Feature input for PE[i][j]: LM[i].O[j]
                wire signed [K-1:0] i_sel_w;
                assign i_sel_w = feature_packed[i*N*K + j*K +: K];

                // B_Psum: bias for col 0, previous Psum for cols 1..N-1
                wire signed [K-1:0] b_w;
                assign b_w = (j == 0)
                    ? BIAS_Bus_packed[i*K +: K]
                    : psum_packed[i*N*K + (j-1)*K +: K];

                // Stride_Request: col 0 drives stride_req[i]
                wire sr_w;
                if (j == 0)
                    assign stride_req[i] = sr_w;

                PE_core pe_inst (
                    .clk(clk), .rst(rst),
                    .S_Ovd(1'b1),
                    .I_sel(i_sel_w),
                    .B_Psum(b_w),
                    .Wr_Rr(kpc_Wr_Rr),
                    .W(WEIGHTS_packed[i*N*K + j*K +: K]),
                    .R6_r_Delta({1'b0, 4'd0, 4'd0}),
                    .MAC_MAX(1'b1),
                    .Stride_Request(sr_w),
                    .Psum(psum_packed[i*N*K + j*K +: K])
                );

            end
        end
    endgenerate

    // ---- Adder tree ---------------------------------------------------
    always_comb begin
        conv_out = '0;
        for (int k = 0; k < M; k++)
            conv_out = conv_out
                     + (K+4)'(signed'(psum_packed[k*N*K + (N-1)*K +: K]));
    end

endmodule
