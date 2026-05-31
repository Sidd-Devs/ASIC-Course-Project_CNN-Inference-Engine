`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 15.03.2026 17:59:44
// Design Name: 
// Module Name: tb_cnn_inference_engine
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

`timescale 1ns / 1ps

/* TB_CNN_Inference_Engine - End-to-end integration test
   
   Tests a 2-layer CNN using REAL KPU + CU + IEC:
     Layer 0 (Conv):  nl=16, rl=1  - not FClast
     Layer 1 (FC):    nl=5,  rl=1  - IS FClast, N_classes=5

   DRAM provides:
     inputs[i] = (i+1)<<8 broadcast to all M rows
     weights   = 1<<8  all
     bias      = 0

   KPU produces conv_out=270 every iteration (all inputs same).
   CU receives 5 equal AC values ? last class wins ? CN_DC = 4.

   Expected: done_interrupt=1, CN_DC_out=4

   IMPORTANT: Set Vivado sim runtime to 50000ns
   Settings ? Simulation ? Simulation tab ? xsim.simulate.runtime = 50000ns
*/
module tb_CNN_Inference_Engine;
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
    logic [N_WIDTH-1:0]    CN_DC_out;
    logic [2:0]            state_out;

    // DRAM
    logic signed [K-1:0]   dram_I_data, dram_W_data, dram_B_data;
    logic                  dram_I_valid, dram_W_valid, dram_B_valid;
    logic                  dram_I_req, dram_W_req, dram_B_req;

    int error_count = 0;

    CNN_Inference_Engine dut (.*);

    initial clk = 0;
    always #5 clk = ~clk;

    // DRAM always supplies data
    assign dram_I_data  = 16'sd256;     // 1.0 in Q8.8
    assign dram_W_data  = 16'sd256;     // 1.0 in Q8.8
    assign dram_B_data  = 16'sd0;
    assign dram_I_valid = 1'b1;
    assign dram_W_valid = 1'b1;
    assign dram_B_valid = 1'b1;

    // Task: set layer config and wait for IEC ack
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
        @(posedge layer_config_ack);
        @(posedge clk);
        layer_config_valid = 1'b0;
    endtask

    initial begin
        $dumpfile("cnn_ie_waveform.vcd");
        $dumpvars(0, tb_CNN_Inference_Engine);

        rst                = 1;
        start              = 0;
        layer_config_valid = 0;
        FClast             = L_WIDTH'(1);
        N_classes          = N_WIDTH'(5);
        layer_comp_type    = COMP_CONV;
        nl                 = NL_WIDTH'(16);
        rl                 = NL_WIDTH'(1);
        layer_num          = L_WIDTH'(0);

        repeat(4) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);

        $display("\n==================================================");
        $display("  CNN INFERENCE ENGINE - INTEGRATION TEST");
        $display("  Layer 0: Conv  nl=16 rl=1");
        $display("  Layer 1: FC (FClast=1)  nl=5 rl=1 N=5");
        $display("  inputs=1.0(Q8.8) weights=1.0(Q8.8) bias=0");
        $display("  KPU output: conv_out=270 per iteration");
        $display("  CU: 5 equal ACs ? last wins ? expected CN_DC=4");
        $display("==================================================\n");

        start = 1'b1;

        // Layer 0: Conv
        $display("  [INFO] Providing Layer 0 config (Conv, nl=16)");
        set_layer_config(L_WIDTH'(0), COMP_CONV,
                         NL_WIDTH'(16), NL_WIDTH'(1),
                         L_WIDTH'(1), N_WIDTH'(5));
        $display("  [INFO] Layer 0 running...");

        // Wait for LAYER_SWITCH (3'd4)
        wait(state_out == 3'd4);
        $display("  [INFO] Layer 0 complete");

        // Layer 1: FC / FClast
        $display("  [INFO] Providing Layer 1 config (FC/FClast, nl=5 N=5)");
        set_layer_config(L_WIDTH'(1), COMP_FC,
                         NL_WIDTH'(5), NL_WIDTH'(1),
                         L_WIDTH'(1), N_WIDTH'(5));
        $display("  [INFO] Layer 1 (FClast) running...");

        // Wait for done
        wait(done_interrupt);
        @(posedge clk); #1;

        $display("\n  done_interrupt = %0b", done_interrupt);
        $display("  CN_DC_out      = %0d", CN_DC_out);
        $display("  (expected 4 - last of 5 equal AC values)");

        if (done_interrupt && CN_DC_out === N_WIDTH'(4))
            $display("\n  [PASS] Integration test passed, class=%0d", CN_DC_out);
        else begin
            $display("\n  [FAIL] done=%0b CN_DC=%0d (expected 4)",
                     done_interrupt, CN_DC_out);
            error_count++;
        end

        $display("\n==================================================");
        $display(error_count == 0 ? "  [SUCCESS] FULL INTEGRATION PASSED"
                                  : "  [FAILED]");
        $display("==================================================\n");

        start = 0;
        #200 $finish;
    end

    // State monitor
    always_ff @(posedge clk) begin
        case (state_out)
            3'd0: ;  // IDLE - silent
            3'd1: $display("  [STATE] CONFIG  t=%0t", $time);
            3'd2: $display("  [STATE] PREFETCH t=%0t", $time);
            3'd3: ;  // COMPUTE - silent (too many cycles)
            3'd4: $display("  [STATE] LAYER_SWITCH t=%0t", $time);
            3'd5: $display("  [STATE] CLASSIFY t=%0t", $time);
            3'd6: $display("  [STATE] DONE t=%0t", $time);
        endcase
    end

    // Watchdog
    initial begin
        #48000;
        $display("  [TIMEOUT] Increase Vivado runtime to 50000ns+");
        $finish;
    end

endmodule
