/* ============================================================
   Classify Unit (CU) - paper Section III-B, Fig.7

   FIX HISTORY:
   v1: CNG reset on !en ? CN never accumulated
   v2: class_done combinational ? cleared before TB sampled it
   v3 (this): rst_sub reset ACSU same cycle class_done latched
              ? CN_DC_r wiped to 0, result lost

   ROOT CAUSE OF v3 BUG:
   rst_sub is combinational (cn_reached && !cn_reached_r).
   It goes high immediately after CN reaches N.
   At the very next posedge, both class_done latches AND ACSU resets
   simultaneously - the correct CN_DC_r is destroyed.

   FIX: Remove rst_sub entirely.
   - ACSU and CNG reset only on top-level rst.
   - CUC simply deactivates (acsu_cng_en=0) when class_done fires.
   - Result held in ACSU until IEC issues rst between inferences.
   - This matches the paper: CUC "deactivates" ACSU/CNG, not resets.
     IEC handles reset between layers/inferences.
   ============================================================ */

package pkg_CU;
    parameter int K       = 16;
    parameter int N_WIDTH = 10;
endpackage


/* ------------------------------------------------------------
   CNG - Class Number Generator
   Counts up on each enabled valid activation.
   Resets only on rst (top-level, between inferences).
   ------------------------------------------------------------ */
module CNG
import pkg_CU::*;
(
    input  logic               clk,
    input  logic               rst,
    input  logic               en,
    output logic [N_WIDTH-1:0] CN
);
    always_ff @(posedge clk) begin
        if (rst) CN <= '0;
        else if (en) CN <= CN + 1'b1;
        // hold when en=0 (between valid pulses)
    end
endmodule


/* ------------------------------------------------------------
   ACSU - Activation Searching Unit
   Finds argmax. Updates REG1/REG2 when ACi >= ACMax.
   Resets only on rst. Result held until IEC reads it.
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
    logic signed [K-1:0]  ACMax;    // REG1
    logic [N_WIDTH-1:0]   CN_DC_r;  // REG2

    // Comparator: ACi - ACMax. MSB=0 ? ACi >= ACMax ? update
    wire signed [K-1:0] cmp    = ACi - ACMax;
    wire                update = en && AC_valid && !cmp[K-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            ACMax   <= '0;   // Algorithm 1 line 1
            CN_DC_r <= '0;
        end else if (update) begin
            ACMax   <= ACi;  // MUX5 ? REG1
            CN_DC_r <= CNi;  // MUX6 ? REG2
        end
        // hold otherwise - result stays valid until rst
    end

    assign CN_DC = CN_DC_r;  // MUX7
endmodule


/* ------------------------------------------------------------
   CUC - Classify Unit Controller
   Registers class_done (holds until rst).
   Deactivates acsu_cng_en when class_done fires.
   No rst_sub - ACSU/CNG reset via top-level rst only.
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
    // Combinational: have we processed all N classes?
    wire cn_reached = l_is_FClast && (N != '0) && (CN_count == N);

    // Registered class_done - latches when cn_reached, holds until rst
    always_ff @(posedge clk) begin
        if (rst)         class_done <= 1'b0;
        else if (cn_reached) class_done <= 1'b1;
    end

    // MUX4: enable ACSU+CNG only while active and not yet done.
    // FIX: use combinational (CN_count < N) not registered class_done.
    // class_done latches one cycle AFTER cn_reached fires, causing
    // one extra en pulse that increments CNG to N+1 and overwrites CN_DC.
    // (CN_count < N) goes low immediately when CN reaches N - no extra cycle.
    assign acsu_cng_en = l_is_FClast && AC_valid && (CN_count < N) && (N != '0);
endmodule


/* ------------------------------------------------------------
   DSR - Data & Signal Router (MUX1 / MUX2 / MUX3)
   ------------------------------------------------------------ */
module DSR
import pkg_CU::*;
(
    input  logic signed [K-1:0]  AC_Psum_in,
    input  logic                 valid_in,
    input  logic                 l_is_FClast,
    input  logic [N_WIDTH-1:0]   CN_DC,
    input  logic                 class_done,

    output logic signed [K-1:0]  AC_to_ACSU,   // MUX1 output
    output logic                 valid_to_CUC,
    output logic signed [K-1:0]  AC_out,        // MUX2 - passthrough to IEC
    output logic [N_WIDTH-1:0]   CN_DC_out,     // classification result
    output logic                 valid_out,     // MUX3
    output logic                 result_valid
);
    // MUX1: route AC to ACSU when processing FClast
    assign AC_to_ACSU   = l_is_FClast ? AC_Psum_in : '0;
    assign valid_to_CUC = l_is_FClast ? valid_in   : 1'b0;

    // MUX2/MUX3: passthrough or classification result to IEC
    assign AC_out      = l_is_FClast ? '0      : AC_Psum_in;
    assign valid_out   = l_is_FClast ? 1'b0    : valid_in;
    assign CN_DC_out   = CN_DC;
    assign result_valid = class_done;
endmodule


/* ------------------------------------------------------------
   CU - top level (paper Fig.7)
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