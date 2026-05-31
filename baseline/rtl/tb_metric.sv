`timescale 1ns / 1ps

/* TB_METRICS_864 with debug prints to trace class=0 issue */
module tb_metrics_864;
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

    logic signed [K-1:0]   dram_I_data, dram_W_data, dram_B_data;
    logic                  dram_I_valid, dram_W_valid, dram_B_valid;
    logic                  dram_I_req, dram_W_req, dram_B_req;

    int  active_cycles, total_cycles;
    bit  counting;
    longint t_start, t_done, latency_ns;
    real    sigma, tops, fps;

    localparam int  NPE        = M * N_PE;
    localparam real CLK_HZ     = 1.0e9 / 10.0;
    localparam real OMEGA      = 1.0;

    always_ff @(posedge clk) begin
        if (rst) begin
            active_cycles <= 0;
            total_cycles  <= 0;
        end else if (counting) begin
            total_cycles <= total_cycles + 1;
            if (state_out == 3'd3) active_cycles <= active_cycles + 1;
        end
    end

    CNN_Inference_Engine dut (.*);

    initial clk = 0;
    always #5 clk = ~clk;

    assign dram_I_data  = 16'sd256;
    assign dram_W_data  = 16'sd256;
    assign dram_B_data  = 16'sd0;
    assign dram_I_valid = 1'b1;
    assign dram_W_valid = 1'b1;
    assign dram_B_valid = 1'b1;

    // Debug wires into IEC internals
    wire [N_WIDTH-1:0]     dbg_classify_cnt  = dut.iec_inst.classify_cnt;
    wire [N_WIDTH-1:0]     dbg_r_N_classes   = dut.iec_inst.r_N_classes;
    wire signed [K+4-1:0]  dbg_psum_reg      = dut.iec_inst.psum_reg;
    wire                   dbg_cu_valid      = dut.cu_valid;
    wire signed [K-1:0]    dbg_cu_AC_in      = dut.cu_AC_in;
    wire [N_WIDTH-1:0]     dbg_CNDC          = dut.cu_inst.acsu_inst.CN_DC_r;
    wire signed [K-1:0]    dbg_ACMax         = dut.cu_inst.acsu_inst.ACMax;
    wire                   dbg_class_done    = dut.cu_inst.cuc_inst.class_done;

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

    // Layer 1 config provider
    initial begin
        @(negedge rst);
        wait(state_out == 3'd4);
        set_layer_config(L_WIDTH'(1), COMP_FC,
                         NL_WIDTH'(5), NL_WIDTH'(1),
                         L_WIDTH'(1), N_WIDTH'(5));
    end

    // Debug monitor - prints every cycle during CLASSIFY state
    always @(posedge clk) begin
        #1;
        if (state_out == 3'd5) begin  // S_CLASSIFY
            $display("  [DBG CLASSIFY] t=%0t  classify_cnt=%0d  r_N_classes=%0d  cu_valid=%0b  cu_AC_in=%0d  ACMax=%0d  CN_DC_r=%0d  class_done=%0b",
                $time, dbg_classify_cnt, dbg_r_N_classes,
                dbg_cu_valid, dbg_cu_AC_in,
                dbg_ACMax, dbg_CNDC, dbg_class_done);
        end
    end

    // Debug: print psum_reg when entering CLASSIFY
    always @(posedge clk) begin
        #1;
        if (state_out == 3'd5 && $past(state_out) != 3'd5) begin
            $display("  [DBG] Entered CLASSIFY: psum_reg=%0d  r_N_classes=%0d  classify_cnt=%0d",
                dbg_psum_reg, dbg_r_N_classes, dbg_classify_cnt);
        end
    end

    initial begin
        $dumpfile("ie_864pe_waveform.vcd");
        $dumpvars(0, tb_metrics_864);

        rst = 1; start = 0; layer_config_valid = 0; counting = 0;
        t_start = 0; t_done = 0; latency_ns = 0;
        sigma = 0.0; tops = 0.0; fps = 0.0;
        FClast = L_WIDTH'(1); N_classes = N_WIDTH'(5);
        layer_comp_type = COMP_CONV;
        nl = NL_WIDTH'(16); rl = NL_WIDTH'(1);
        layer_num = L_WIDTH'(0);

        repeat(4) @(posedge clk); rst = 0; repeat(2) @(posedge clk);

        $display("\n================================================================");
        $display("  864 PE - DEBUG RUN");
        $display("  NPE=%0d  N_classes=5  nl=16(Conv)+5(FC)", NPE);
        $display("================================================================\n");

        t_start = $time; counting = 1; start = 1'b1;

        set_layer_config(L_WIDTH'(0), COMP_CONV,
                         NL_WIDTH'(16), NL_WIDTH'(1),
                         L_WIDTH'(1), N_WIDTH'(5));

        wait(done_interrupt);
        t_done = $time; counting = 0;
        @(posedge clk); #1;

        latency_ns = t_done - t_start;
        sigma = (total_cycles > 0) ?
                real'(active_cycles) / real'(total_cycles) : 0.0;
        tops  = (2.0 * real'(NPE) * CLK_HZ * OMEGA * sigma) / 1.0e12;
        fps   = (latency_ns > 0) ? 1.0e9 / real'(latency_ns) : 0.0;

        $display("\n================================================================");
        $display("  RESULTS");
        $display("================================================================");
        $display("  Detected class          : %0d", CN_DC_out);
        $display("  Inference correct       : %s",
                 (CN_DC_out == N_WIDTH'(4)) ? "YES [PASS]" : "NO [FAIL]");
        $display("  Total latency           : %0d ns / %0d cycles",
                 latency_ns, total_cycles);
        $display("  Active COMPUTE cycles   : %0d / %0d", active_cycles, total_cycles);
        $display("  sigma                   : %0.4f (%0.1f%%)", sigma, sigma*100.0);
        $display("  Theta_T @ 100MHz 864PE  : %0.6f TOPS", tops);
        $display("  Theta_T @ 3.85GHz 864PE : %0.4f TOPS  (paper: 6.65)",
                 2.0*real'(NPE)*3.85e9*1.0*1.0/1.0e12);
        $display("================================================================\n");

        start = 0; #100 $finish;
    end

    initial begin #48000; $display("  [TIMEOUT]"); $finish; end

endmodule