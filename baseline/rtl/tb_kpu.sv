`timescale 1ns / 1ps

module tb_kpu;
    import pkg_KPU::*;

    logic                   clk, rst;
    logic [M*K-1:0]         bias_packed;
    logic [M*K-1:0]         lm_inputs_packed;
    logic [M*N*K-1:0]       weights_packed;
    logic signed [K+4-1:0]  out;

    initial clk = 0;
    always #5 clk = ~clk;

    KPU_cluster dut (
        .clk(clk), .rst(rst),
        .BIAS_Bus_packed(bias_packed),
        .LM_INPUTS_packed(lm_inputs_packed),
        .WEIGHTS_packed(weights_packed),
        .conv_out(out)
    );

    wire signed [K-1:0] lm0_O0  = dut.feature_packed[0*N*K + 0*K +: K];
    wire signed [K-1:0] psum_00 = dut.psum_packed[0*N*K + 0*K +: K];
    wire signed [K-1:0] psum_05 = dut.psum_packed[0*N*K + (N-1)*K +: K];
    wire                sr_00   = dut.stride_req[0];
    wire [1:0]          wr_rr   = dut.kpc_Wr_Rr;

    // FIX: declare expected as same type as out to avoid width/sign mismatch
    localparam logic signed [K+4-1:0] EXPECTED = 20'sd270;

    integer i, j;

    initial begin
        $dumpfile("kpu_waveform.vcd");
        $dumpvars(0, tb_kpu);

        rst = 1;
        bias_packed = '0;

        for (i = 0; i < M; i++)
            lm_inputs_packed[i*K +: K] = K'(i+1) << 8;

        for (i = 0; i < M; i++)
            for (j = 0; j < N; j++)
                weights_packed[i*N*K + j*K +: K] = K'(1) << 8;

        repeat(2) @(posedge clk);
        rst = 0;

        $display("\n==================================================");
        $display("  KPU TESTBENCH  expected=%0d", EXPECTED);
        $display("==================================================");

        repeat(80) @(posedge clk);
        #1;

        $display("  conv_out = %0d", out);

        // FIX: compare as integers to avoid any width/sign elaboration issue
        if ($isunknown(out))
            $display("  [FAIL] X in output");
        else if ($signed(out) == $signed(EXPECTED))
            $display("  [PASS] conv_out = %0d matches expected %0d", out, EXPECTED);
        else
            $display("  [FAIL] expected %0d got %0d", EXPECTED, out);

        $display("==================================================\n");
        #20 $finish;
    end

    initial begin
        @(negedge rst);
        repeat(Z) @(posedge clk);
        $display("\n  cyc | WrRr | lm0_O0 | psum_00 | psum_05 | SR | conv_out");
        $display("  ----|------|--------|---------|---------|----|---------");
        repeat(50) begin
            @(posedge clk); #1;
            $display("  %4t | %2b   | %6d | %7d | %7d |  %b | %d",
                $time/10000, wr_rr, lm0_O0, psum_00, psum_05, sr_00, out);
        end
    end

endmodule