/* ============================================================
   Classify Unit (CU) - ENERGY-OPTIMIZED VERSION

   Optimizations applied:
   OPT-10: Gate ACSU registers when en=0 (clock gating enable)
   OPT-11: Gate CNG counter when en=0 (clock gating enable)
   OPT-12: Operand isolation on DSR MUX outputs

   NOTE: CU is only ~0.086% of total hardware, so energy savings
   here are minimal. Included for completeness and to demonstrate
   systematic optimization approach.
   ============================================================ */

package pkg_CU;
    parameter int K       = 16;
    parameter int N_WIDTH = 10;
endpackage


/* ------------------------------------------------------------
   CNG - Class Number Generator (already clock-gated via 'en')
   ------------------------------------------------------------ */
module CNG
import pkg_CU::*;
(
    input  logic               clk,
    input  logic               rst,
    input  logic               en,      // OPT-11: Clock gate enable
    output logic [N_WIDTH-1:0] CN
);
    // Synthesis will insert ICG cell because 'en' gates the update
    always_ff @(posedge clk) begin
        if (rst) CN <= '0;
        else if (en) CN <= CN + 1'b1;
        // else: hold - Genus inserts clock gate here
    end
endmodule


/* ------------------------------------------------------------
   ACSU - Activation Searching Unit
   OPT-10: Clock-gated update of ACMax and CN_DC_r
   ------------------------------------------------------------ */
module ACSU
import pkg_CU::*;
(
    input  logic                 clk,
    input  logic                 rst,
    input  logic                 en,
    input  logic                 AC_valid,
    input  logic signed [K-1:0]  ACi,
    input  logic [N_WIDTH-1:0]   CNi,
    output logic [N_WIDTH-1:0]   CN_DC
);
    logic signed [K-1:0]  ACMax;
    logic [N_WIDTH-1:0]   CN_DC_r;

    wire signed [K-1:0] cmp    = ACi - ACMax;
    wire                update = en && AC_valid && !cmp[K-1];

    // OPT-10: 'update' acts as clock-gating enable
    // Registers only toggle when a new maximum is found
    always_ff @(posedge clk) begin
        if (rst) begin
            ACMax   <= '0;
            CN_DC_r <= '0;
        end else if (update) begin
            ACMax   <= ACi;
            CN_DC_r <= CNi;
        end
        // else: hold - Genus will insert clock gate here
    end

    assign CN_DC = CN_DC_r;
endmodule


/* ------------------------------------------------------------
   CUC - Classify Unit Controller (unchanged - already minimal)
   ------------------------------------------------------------ */
module CUC
import pkg_CU::*;
(
    input  logic               clk,
    input  logic               rst,
    input  logic               l_is_FClast,
    input  logic               AC_valid,
    input  logic [N_WIDTH-1:0] CN_count,
    input  logic [N_WIDTH-1:0] N,
    output logic               acsu_cng_en,
    output logic               class_done
);
    wire cn_reached = l_is_FClast && (N != '0) && (CN_count == N);

    always_ff @(posedge clk) begin
        if (rst)         class_done <= 1'b0;
        else if (cn_reached) class_done <= 1'b1;
    end

    assign acsu_cng_en = l_is_FClast && AC_valid && (CN_count < N) && (N != '0);
endmodule


/* ------------------------------------------------------------
   DSR - Data & Signal Router with operand isolation
   OPT-12: Force outputs to zero when not in classify mode
   ------------------------------------------------------------ */
module DSR
import pkg_CU::*;
(
    input  logic signed [K-1:0]  AC_Psum_in,
    input  logic                 valid_in,
    input  logic                 l_is_FClast,
    input  logic [N_WIDTH-1:0]   CN_DC,
    input  logic                 class_done,

    output logic signed [K-1:0]  AC_to_ACSU,
    output logic                 valid_to_CUC,
    output logic signed [K-1:0]  AC_out,
    output logic [N_WIDTH-1:0]   CN_DC_out,
    output logic                 valid_out,
    output logic                 result_valid
);
    // OPT-12: Operand isolation - force ACSU input to zero when not classifying
    assign AC_to_ACSU   = l_is_FClast ? AC_Psum_in : '0;
    assign valid_to_CUC = l_is_FClast ? valid_in   : 1'b0;

    assign AC_out      = l_is_FClast ? '0      : AC_Psum_in;
    assign valid_out   = l_is_FClast ? 1'b0    : valid_in;
    assign CN_DC_out   = CN_DC;
    assign result_valid = class_done;
endmodule


/* ------------------------------------------------------------
   CU - top level (unchanged structure, optimized sub-modules)
   ------------------------------------------------------------ */
module CU
import pkg_CU::*;
(
    input  logic                 clk,
    input  logic                 rst,
    input  logic signed [K-1:0]  AC_Psum_in,
    input  logic                 valid_in,
    input  logic                 l_is_FClast,
    input  logic [N_WIDTH-1:0]   N,
    output logic signed [K-1:0]  AC_out,
    output logic                 valid_out,
    output logic [N_WIDTH-1:0]   CN_DC_out,
    output logic                 result_valid
);
    wire signed [K-1:0]  AC_to_ACSU;
    wire                 valid_to_CUC;
    wire                 acsu_cng_en;
    wire                 class_done;
    wire [N_WIDTH-1:0]   CN_from_CNG;
    wire [N_WIDTH-1:0]   CN_DC_from_ACSU;

    DSR dsr_inst (
        .AC_Psum_in  (AC_Psum_in),
        .valid_in    (valid_in),
        .l_is_FClast (l_is_FClast),
        .CN_DC       (CN_DC_from_ACSU),
        .class_done  (class_done),
        .AC_to_ACSU  (AC_to_ACSU),
        .valid_to_CUC(valid_to_CUC),
        .AC_out      (AC_out),
        .CN_DC_out   (CN_DC_out),
        .valid_out   (valid_out),
        .result_valid(result_valid)
    );

    CUC cuc_inst (
        .clk        (clk),
        .rst        (rst),
        .l_is_FClast(l_is_FClast),
        .AC_valid   (valid_to_CUC),
        .CN_count   (CN_from_CNG),
        .N          (N),
        .acsu_cng_en(acsu_cng_en),
        .class_done (class_done)
    );

    CNG cng_inst (
        .clk(clk),
        .rst(rst),
        .en (acsu_cng_en),
        .CN (CN_from_CNG)
    );

    ACSU acsu_inst (
        .clk     (clk),
        .rst     (rst),
        .en      (acsu_cng_en),
        .AC_valid(valid_to_CUC),
        .ACi     (AC_to_ACSU),
        .CNi     (CN_from_CNG),
        .CN_DC   (CN_DC_from_ACSU)
    );

endmodule
