`timescale 1ns / 1ps

/* TB_CU
   Tie-breaking: paper uses >= so LAST equal wins (Test 3 expects class 1).
   result_valid now holds until rst - sampled safely after all sends complete.
*/
module tb_CU;
    import pkg_CU::*;

    logic                clk, rst;
    logic signed [K-1:0] AC_Psum_in;
    logic                valid_in;
    logic                l_is_FClast;
    logic [N_WIDTH-1:0]  N;

    wire  signed [K-1:0] AC_out;
    wire                 valid_out;
    wire  [N_WIDTH-1:0]  CN_DC_out;
    wire                 result_valid;

    int error_count = 0;

    CU dut (.*);

    initial clk = 0;
    always #5 clk = ~clk;

    // Send one activation - 1 cycle valid pulse
    task automatic send_ac(input logic signed [K-1:0] val);
        @(posedge clk);
        AC_Psum_in = val;
        valid_in   = 1'b1;
        @(posedge clk);
        valid_in   = 1'b0;
        AC_Psum_in = '0;
    endtask

    // Reset DUT cleanly
    task automatic do_rst();
        rst = 1;
        repeat(2) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);
    endtask

    // Check - result_valid holds until rst, so sample after all sends done
    task automatic check(
        input string             name,
        input logic [N_WIDTH-1:0] expected
    );
        // Give a few cycles for last CNG increment to propagate
        repeat(4) @(posedge clk); #1;
        if (!result_valid) begin
            $display("  [FAIL] %s: result_valid not asserted", name);
            error_count++;
        end else if (CN_DC_out === expected)
            $display("  [PASS] %s: class=%0d", name, CN_DC_out);
        else begin
            $display("  [FAIL] %s: expected class=%0d got=%0d",
                     name, expected, CN_DC_out);
            error_count++;
        end
    endtask

    initial begin
        $dumpfile("cu_waveform.vcd");
        $dumpvars(0, tb_CU);

        rst         = 1;
        AC_Psum_in  = '0;
        valid_in    = 1'b0;
        l_is_FClast = 1'b0;
        N           = '0;

        repeat(2) @(posedge clk); rst = 0; repeat(2) @(posedge clk);

        $display("\n==================================================");
        $display("  CU TESTBENCH");
        $display("==================================================\n");

        // ============================================================
        // TEST 1: Passthrough - l_is_FClast=0
        // ============================================================
        $display("--- TEST 1: Passthrough (l_is_FClast=0) ---");
        l_is_FClast = 1'b0;
        @(posedge clk);
        AC_Psum_in = 16'sd42; valid_in = 1'b1;
        @(posedge clk); #1;
        if (AC_out === 16'sd42 && valid_out === 1'b1)
            $display("  [PASS] AC_out=%0d valid_out=%0b", AC_out, valid_out);
        else begin
            $display("  [FAIL] AC_out=%0d (exp 42) valid_out=%0b (exp 1)",
                     AC_out, valid_out);
            error_count++;
        end
        valid_in = 1'b0; AC_Psum_in = '0;
        @(posedge clk);

        // ============================================================
        // TEST 2: Argmax {3,7,2,9,1} ? class 3
        // ============================================================
        $display("\n--- TEST 2: Argmax {3,7,2,9,1} ? class 3 ---");
        do_rst();
        l_is_FClast = 1'b1; N = 10'd5;
        begin
            logic signed [K-1:0] ac[5] = '{16'sd3,16'sd7,16'sd2,16'sd9,16'sd1};
            for (int i=0; i<5; i++) send_ac(ac[i]);
        end
        check("TEST 2 argmax", 10'd3);

        // ============================================================
        // TEST 3: Tie {5,5,3} ? class 1 (last equal wins)
        // ============================================================
        $display("\n--- TEST 3: Tie {5,5,3} ? class 1 (last equal wins) ---");
        do_rst();
        l_is_FClast = 1'b1; N = 10'd3;
        begin
            logic signed [K-1:0] ac[3] = '{16'sd5,16'sd5,16'sd3};
            for (int i=0; i<3; i++) send_ac(ac[i]);
        end
        check("TEST 3 tie", 10'd1);

        // ============================================================
        // TEST 4: Reset mid-run, clean run {1,2,3,4,5} ? class 4
        // ============================================================
        $display("\n--- TEST 4: Reset mid-run, clean run {1..5} ? class 4 ---");
        do_rst();
        l_is_FClast = 1'b1; N = 10'd5;
        send_ac(16'sd100); send_ac(16'sd200); // partial run
        do_rst();
        l_is_FClast = 1'b1; N = 10'd5;
        begin
            for (int i=1; i<=5; i++) send_ac(K'(signed'(i)));
        end
        check("TEST 4 post-reset", 10'd4);

        // ============================================================
        // TEST 5: N=10, max=9 at class 7
        // ============================================================
        $display("\n--- TEST 5: N=10, max=9 at class 7 ---");
        do_rst();
        l_is_FClast = 1'b1; N = 10'd10;
        begin
            logic signed [K-1:0] ac[10] = '{
                16'sd1,16'sd3,16'sd2,16'sd5,
                16'sd4,16'sd6,16'sd3,16'sd9,
                16'sd2,16'sd1};
            for (int i=0; i<10; i++) send_ac(ac[i]);
        end
        check("TEST 5 N=10", 10'd7);

        // ============================================================
        // TEST 6: All equal {4,4,4} ? class 2 (last wins)
        // ============================================================
        $display("\n--- TEST 6: All equal {4,4,4} ? class 2 ---");
        do_rst();
        l_is_FClast = 1'b1; N = 10'd3;
        begin
            for (int i=0; i<3; i++) send_ac(16'sd4);
        end
        check("TEST 6 all-equal", 10'd2);

        // ============================================================
        // SUMMARY
        // ============================================================
        $display("\n==================================================");
        if (error_count == 0)
            $display("  [SUCCESS] ALL TESTS PASSED");
        else
            $display("  [FAILED]  %0d TEST(S) FAILED", error_count);
        $display("==================================================\n");

        #20 $finish;
    end

endmodule