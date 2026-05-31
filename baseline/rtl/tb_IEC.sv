`timescale 1ns / 1ps

/* TB_IEC - corrected testbench
   BEFORE RUNNING: set Vivado sim runtime to 10000ns
   Settings ? Simulation ? Simulation tab ? xsim.simulate.runtime = 10000ns
*/
module tb_IEC;
    import pkg_IEC::*;

    logic                  clk, rst;
    logic                  start;
    logic                  layer_config_valid;
    logic                  layer_config_ack;
    logic [L_WIDTH-1:0]    FClast;
    logic [N_WIDTH-1:0]    N_classes;
    logic [COMP_WIDTH-1:0] layer_comp_type;
    logic [NL_WIDTH-1:0]   nl, rl;
    logic [L_WIDTH-1:0]    layer_num;
    logic                  done_interrupt;
    logic [N_WIDTH-1:0]    CN_DC_proc;
    logic [2:0]            state_out;

    // KPU mock
    logic [M*K-1:0]        kpu_BIAS, kpu_I;
    logic [M*N_PE*K-1:0]   kpu_W;
    logic signed [K+4-1:0] kpu_AC_out;
    logic                  kpu_valid;
    logic                  kpu_rst;

    // CU mock
    logic signed [K-1:0]   cu_AC_in;
    logic                  cu_valid;
    logic                  cu_l_is_FClast;
    logic [N_WIDTH-1:0]    cu_N;
    logic [N_WIDTH-1:0]    cu_CN_DC;
    logic                  cu_result_valid;
    logic signed [K-1:0]   cu_AC_passthrough;
    logic                  cu_valid_passthrough;
    logic                  cu_rst;

    // DRAM mock
    logic signed [K-1:0]   dram_I_data, dram_W_data, dram_B_data;
    logic                  dram_I_valid, dram_W_valid, dram_B_valid;
    logic                  dram_I_req, dram_W_req, dram_B_req;

    int error_count = 0;

    IEC dut (.*);

    initial clk = 0;
    always #5 clk = ~clk;

    // DRAM always ready
    assign dram_I_data  = 16'sd10;
    assign dram_W_data  = 16'sd1;
    assign dram_B_data  = 16'sd0;
    assign dram_I_valid = 1'b1;
    assign dram_W_valid = 1'b1;
    assign dram_B_valid = 1'b1;

    // KPU mock: valid 2 cycles after kpu_rst falls
    logic [2:0] kpu_dly;
    always_ff @(posedge clk) begin
        if (kpu_rst || rst) begin
            kpu_dly    <= '0;
            kpu_valid  <= 1'b0;
            kpu_AC_out <= 20'sd100;
        end else begin
            if (kpu_dly < 3'd2) begin
                kpu_dly   <= kpu_dly + 1'b1;
                kpu_valid <= 1'b0;
            end else begin
                kpu_valid  <= 1'b1;
                kpu_AC_out <= 20'sd100;
            end
        end
    end

    // CU mock: result_valid 3 cycles after cu_l_is_FClast rises
    logic [2:0] cu_dly;
    always_ff @(posedge clk) begin
        if (cu_rst || rst) begin
            cu_dly          <= '0;
            cu_result_valid <= 1'b0;
            cu_CN_DC        <= 10'd42;
        end else if (cu_l_is_FClast) begin
            if (cu_dly < 3'd3) begin
                cu_dly          <= cu_dly + 1'b1;
                cu_result_valid <= 1'b0;
            end else begin
                cu_result_valid <= 1'b1;
                cu_CN_DC        <= 10'd42;
            end
        end
    end
    assign cu_AC_passthrough    = '0;
    assign cu_valid_passthrough = 1'b0;

    // Task: drive layer config and wait for IEC ack
    // FIX: positional arguments (not named .port() style)
    task automatic set_layer_config(
        input logic [L_WIDTH-1:0]    lnum,
        input logic [COMP_WIDTH-1:0] ctype,
        input logic [NL_WIDTH-1:0]   n_l,
        input logic [NL_WIDTH-1:0]   r_l,
        input logic [L_WIDTH-1:0]    fc_last,
        input logic [N_WIDTH-1:0]    n_cls
    );
        @(posedge clk);
        layer_num          = lnum;
        layer_comp_type    = ctype;
        nl                 = n_l;
        rl                 = r_l;
        FClast             = fc_last;
        N_classes          = n_cls;
        layer_config_valid = 1'b1;
        @(posedge layer_config_ack);  // wait for IEC to latch
        @(posedge clk);
        layer_config_valid = 1'b0;
    endtask

    initial begin
        $dumpfile("iec_waveform.vcd");
        $dumpvars(0, tb_IEC);

        rst                = 1;
        start              = 0;
        layer_config_valid = 0;
        FClast             = L_WIDTH'(1);
        N_classes          = N_WIDTH'(100);
        layer_comp_type    = COMP_CONV;
        nl                 = NL_WIDTH'(3);
        rl                 = NL_WIDTH'(1);
        layer_num          = L_WIDTH'(0);

        repeat(3) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);

        $display("\n==================================================");
        $display("  IEC TESTBENCH");
        $display("  Layer 0: Conv  nl=3 rl=1");
        $display("  Layer 1: FC (FClast=1)  nl=2 rl=1");
        $display("  Expected: done_interrupt=1, CN_DC_proc=42");
        $display("==================================================\n");

        start = 1'b1;

        // Layer 0 config
        $display("  [INFO] Providing Layer 0 config");
        set_layer_config(L_WIDTH'(0), COMP_CONV, NL_WIDTH'(3),
                         NL_WIDTH'(1), L_WIDTH'(1), N_WIDTH'(100));
        $display("  [INFO] Layer 0 running...");

        // Wait for LAYER_SWITCH (state=3'd4) using state_out port
        wait(state_out == 3'd4);
        $display("  [INFO] Layer 0 done, providing Layer 1 config");

        // Layer 1 config (FClast)
        set_layer_config(L_WIDTH'(1), COMP_FC, NL_WIDTH'(2),
                         NL_WIDTH'(1), L_WIDTH'(1), N_WIDTH'(100));
        $display("  [INFO] Layer 1 (FClast) running...");

        // Wait for done
        wait(done_interrupt);
        @(posedge clk); #1;

        $display("\n  done_interrupt = %0b", done_interrupt);
        $display("  CN_DC_proc     = %0d", CN_DC_proc);

        if (done_interrupt && CN_DC_proc === N_WIDTH'(42))
            $display("\n  [PASS] Inference complete, class=%0d", CN_DC_proc);
        else begin
            $display("\n  [FAIL] done=%0b CN_DC=%0d (expected 42)",
                     done_interrupt, CN_DC_proc);
            error_count++;
        end

        $display("\n==================================================");
        $display(error_count == 0 ? "  [SUCCESS]" : "  [FAILED]");
        $display("==================================================\n");

        start = 0;
        #100 $finish;
    end

    // Watchdog
    initial begin
        #9500;
        $display("  [TIMEOUT] - increase Vivado runtime to 10000ns+");
        $finish;
    end

endmodule