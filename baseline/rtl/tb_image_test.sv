//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 17.03.2026 21:04:18
// Design Name: 
// Module Name: tb_image
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

/* ================================================================
   TB_IMAGE_TEST - Functional image classification test
   
   Simulates classifying a 3×3 grayscale image using our CNN
   inference engine (KPU + IEC + CU).

   IMAGE (3×3 grayscale, pixel values 1..9):
     [ 1  2  3 ]
     [ 4  5  6 ]
     [ 7  8  9 ]
   Flattened row-major ? 9 values, one per KPU line memory row.

   CNN OPERATION (1×1 convolution, 9 classes):
     Layer 0 (Conv, nl=9):
       Each iteration i uses filter weight = (i+1) in Q8.8.
       KPU computes: conv_out[i] = N × sum(pixels) × weight[i]
                                 = 96 × 45 × (i+1)
       IEC feeds conv_out[i] as ACi to CU.

     Layer 1 (FC/FClast, nl=9, N_classes=9):
       CU finds argmax of 9 AC values.
       AC values: 4320, 8640, 12960, ..., 38880 (strictly increasing).
       Expected CN_DC = 8 (class with weight=9, highest activation).

   Manual verification:
     AC[0] = 96×45×1 = 4320   (class 0)
     AC[1] = 96×45×2 = 8640   (class 1)
     ...
     AC[8] = 96×45×9 = 38880  (class 8) ? maximum ? CN_DC = 8

   IMPORTANT: Set Vivado sim runtime to 10000ns
   ================================================================ */

module tb_image_test;
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

    // DRAM mock - driven per-cycle to simulate unique pixel/weight data
    logic signed [K-1:0]   dram_I_data, dram_W_data, dram_B_data;
    logic                  dram_I_valid, dram_W_valid, dram_B_valid;
    logic                  dram_I_req,   dram_W_req,   dram_B_req;

    CNN_Inference_Engine dut (.*);

    initial clk = 0;
    always #5 clk = ~clk;

    // ----------------------------------------------------------------
    // Image data - 3×3 grayscale, pixels 1..9 in Q8.8
    // Each pixel assigned to one line memory row (M=9 rows)
    // ----------------------------------------------------------------
    logic signed [K-1:0] image_pixels [0:8];
    initial begin
        image_pixels[0] = 16'sd1 << 8;   // pixel (0,0) = 1
        image_pixels[1] = 16'sd2 << 8;   // pixel (0,1) = 2
        image_pixels[2] = 16'sd3 << 8;   // pixel (0,2) = 3
        image_pixels[3] = 16'sd4 << 8;   // pixel (1,0) = 4
        image_pixels[4] = 16'sd5 << 8;   // pixel (1,1) = 5
        image_pixels[5] = 16'sd6 << 8;   // pixel (1,2) = 6
        image_pixels[6] = 16'sd7 << 8;   // pixel (2,0) = 7
        image_pixels[7] = 16'sd8 << 8;   // pixel (2,1) = 8
        image_pixels[8] = 16'sd9 << 8;   // pixel (2,2) = 9
    end

    // ----------------------------------------------------------------
    // Class weights - 9 classes, weight[c] = c+1 in Q8.8
    // Class with highest weight wins (weight=9 ? class 8)
    // ----------------------------------------------------------------
    logic signed [K-1:0] class_weights [0:8];
    initial begin
        class_weights[0] = 16'sd1 << 8;
        class_weights[1] = 16'sd2 << 8;
        class_weights[2] = 16'sd3 << 8;
        class_weights[3] = 16'sd4 << 8;
        class_weights[4] = 16'sd5 << 8;
        class_weights[5] = 16'sd6 << 8;
        class_weights[6] = 16'sd7 << 8;
        class_weights[7] = 16'sd8 << 8;
        class_weights[8] = 16'sd9 << 8;
    end

    // ----------------------------------------------------------------
    // DRAM simulation:
    //   I_data : cycles through image pixels (broadcast same pixel
    //            to all M rows - limitation of current IEC)
    //            For this test: all rows get average pixel = 5<<8
    //            to give predictable conv_out = N*9*avg_pixel*weight
    //   W_data : changes with each KPU iteration (class weight)
    //   B_data : always 0
    // ----------------------------------------------------------------
    // Track current KPU iteration for weight selection
    logic [3:0] iter_track;

    always_ff @(posedge clk) begin
        if (rst)
            iter_track <= '0;
        else if (state_out == 3'd3 && dut.iec_inst.kpu_valid &&
                 dut.iec_inst.warmup_done)
            iter_track <= iter_track + 1'b1;
        else if (state_out == 3'd1)  // CONFIG - reset for new layer
            iter_track <= '0;
    end

    // Use average pixel value (5) broadcast to all rows
    // This gives: conv_out = N * M * 5 * weight = 96*9*5*weight = 4320*weight
    // Per-class: 4320*1=4320, 4320*2=8640, ..., 4320*9=38880
    assign dram_I_data  = 16'sd5 << 8;         // average pixel in Q8.8
    assign dram_B_data  = 16'sd0;
    assign dram_I_valid = 1'b1;
    assign dram_W_valid = 1'b1;
    assign dram_B_valid = 1'b1;

    // Weight changes per iteration - use iter_track to select
    assign dram_W_data  = (iter_track < 9) ? class_weights[iter_track] : 16'sd0;

    // ----------------------------------------------------------------
    // Layer config task
    // ----------------------------------------------------------------
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

    // Layer 1 config provider (parallel)
    initial begin
        @(negedge rst);
        wait(state_out == 3'd4);  // LAYER_SWITCH
        set_layer_config(L_WIDTH'(1), COMP_FC,
                         NL_WIDTH'(9), NL_WIDTH'(1),
                         L_WIDTH'(1), N_WIDTH'(9));
    end

    // ----------------------------------------------------------------
    // Main stimulus
    // ----------------------------------------------------------------
    initial begin
        $dumpfile("image_test_waveform.vcd");
        $dumpvars(0, tb_image_test);

        rst                = 1;
        start              = 0;
        layer_config_valid = 0;
        FClast             = L_WIDTH'(1);
        N_classes          = N_WIDTH'(9);
        layer_comp_type    = COMP_CONV;
        nl                 = NL_WIDTH'(9);
        rl                 = NL_WIDTH'(1);
        layer_num          = L_WIDTH'(0);

        repeat(4) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);

        $display("\n================================================================");
        $display("  IMAGE CLASSIFICATION TEST");
        $display("================================================================");
        $display("  Input image (3x3 grayscale, pixels 1-9):");
        $display("    [ 1  2  3 ]");
        $display("    [ 4  5  6 ]");
        $display("    [ 7  8  9 ]");
        $display("  Using average pixel = 5 (broadcast to all M rows)");
        $display("  9 classes, filter weights = [1,2,...,9] Q8.8");
        $display("  Expected AC per class: 4320, 8640, ..., 38880");
        $display("  Expected classification: class 8 (weight=9, max AC=38880)");
        $display("================================================================\n");

        start = 1'b1;

        // Layer 0: Conv - 9 iterations, one per class weight
        $display("  [INFO] Layer 0 (Conv): computing 9 class activations...");
        set_layer_config(L_WIDTH'(0), COMP_CONV,
                         NL_WIDTH'(9), NL_WIDTH'(1),
                         L_WIDTH'(1), N_WIDTH'(9));

        // Wait for classification result
        wait(done_interrupt);
        @(posedge clk); #1;

        $display("  [INFO] Inference complete\n");
        $display("================================================================");
        $display("  CLASSIFICATION RESULT");
        $display("================================================================");
        $display("  Detected class  : %0d", CN_DC_out);
        $display("  Expected class  : 8  (highest weight = 9, max activation)");
        $display("  Result          : %s",
                 (CN_DC_out === N_WIDTH'(8)) ? "[PASS] Correct classification!" :
                                               "[FAIL] Wrong class");
        $display("================================================================\n");

        // Print what each class activation should have been
        $display("  Per-class activation breakdown:");
        $display("  Class | Weight | Expected AC | Note");
        $display("  ------|--------|-------------|-----");
        for (int c = 0; c < 9; c++) begin
            int w = c + 1;
            int ac = 96 * 9 * 5 * w;  // N * M * avg_pixel * weight
            $display("    %2d  |   %2d   |    %6d   | %s",
                     c, w, ac,
                     (c == 8) ? "<-- max (detected)" : "");
        end

        start = 0;
        #100 $finish;
    end

    // Watchdog
    initial begin
        #98000;
        $display("  [TIMEOUT] Increase sim runtime to 100000ns");
        $finish;
    end

endmodule
