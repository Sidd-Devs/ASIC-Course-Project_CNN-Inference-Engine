`timescale 1ns / 1ps

/* ============================================================
   TB_ENERGY_COMPARE - Vivado Power Comparison Testbench
   
   This is a SIMPLER version for Vivado workflow:
   
   STEP 1: Run with ORIGINAL RTL
     - Add original files (kpu.sv, CU.sv, IEC.sv, CNN_inference_engine.sv)
     - Add this testbench
     - Run simulation -> note toggle counts printed in console
     - Run Synthesis (if desired) -> Report Power
   
   STEP 2: Replace with OPTIMIZED RTL
     - Remove original files from project
     - Add optimized files from energy_opt/rtl/
     - Re-run simulation -> note NEW toggle counts
     - Re-run Synthesis -> Report Power
   
   STEP 3: Compare the two sets of numbers
   
   The testbench prints a clear table you can copy into your report.
   ============================================================ */

module tb_energy_compare;
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

    // ---- Toggle counting infrastructure ----
    int  active_cycles, total_cycles;
    bit  counting;
    longint t_start, t_done, latency_ns;

    localparam int  NPE    = M * N_PE;  // 864
    localparam real CLK_HZ = 1.0e9 / 10.0;  // 100 MHz

    // Toggle counters for key signals
    longint unsigned toggle_mac_reg;       // MAC pipeline register
    longint unsigned toggle_psum_out;      // PE output register
    longint unsigned toggle_weight_bus;    // Weight data bus
    longint unsigned toggle_input_bus;     // Input data bus
    longint unsigned toggle_fsm_state;     // IEC FSM state register
    longint unsigned toggle_conv_out;      // Final KPU output
    longint unsigned toggle_wag;           // Line memory write address
    longint unsigned toggle_read_base;     // Line memory read address

    // Previous values for edge detection
    logic signed [K-1:0]    prev_mac_reg;
    logic signed [K-1:0]    prev_psum_out;
    logic [K-1:0]           prev_wbus;
    logic [K-1:0]           prev_ibus;
    logic [2:0]             prev_state;
    logic signed [K+4-1:0]  prev_conv_out;

    // ---- DUT ----
    CNN_Inference_Engine dut (.*);

    initial clk = 0;
    always #5 clk = ~clk;

    assign dram_I_data  = 16'sd256;
    assign dram_W_data  = 16'sd256;
    assign dram_B_data  = 16'sd0;
    assign dram_I_valid = 1'b1;
    assign dram_W_valid = 1'b1;
    assign dram_B_valid = 1'b1;

    // ---- Probe internal signals ----
    wire signed [K-1:0]   probe_mac_reg   = dut.kpu_inst.PE_ROW[0].PE_COL[0].pe_inst.mpr;
    wire signed [K-1:0]   probe_psum_out  = dut.kpu_inst.PE_ROW[0].PE_COL[0].pe_inst.Psum;
    wire [K-1:0]          probe_wbus      = dut.kpu_W[K-1:0];
    wire [K-1:0]          probe_ibus      = dut.kpu_I[K-1:0];
    wire [2:0]            probe_state     = dut.iec_inst.state;
    wire signed [K+4-1:0] probe_conv_out  = dut.kpu_inst.conv_out;

    // ---- Toggle counter logic ----
    always_ff @(posedge clk) begin
        if (rst) begin
            toggle_mac_reg    <= 0;
            toggle_psum_out   <= 0;
            toggle_weight_bus <= 0;
            toggle_input_bus  <= 0;
            toggle_fsm_state  <= 0;
            toggle_conv_out   <= 0;
            prev_mac_reg      <= '0;
            prev_psum_out     <= '0;
            prev_wbus         <= '0;
            prev_ibus         <= '0;
            prev_state        <= '0;
            prev_conv_out     <= '0;
            active_cycles     <= 0;
            total_cycles      <= 0;
        end else if (counting) begin
            total_cycles <= total_cycles + 1;
            // Match COMPUTE/PREFETCH for BOTH binary and Gray FSM encodings:
            //   Binary: PREFETCH=3'd2 (010), COMPUTE=3'd3 (011)
            //   Gray:   PREFETCH=3'b011 (3), COMPUTE=3'b010 (2)
            // So checking for 2 or 3 works for BOTH encodings!
            if (probe_state == 3'd2 || probe_state == 3'd3)
                active_cycles <= active_cycles + 1;

            // Count bit-level transitions on each signal
            for (int b = 0; b < K; b++) begin
                if (probe_mac_reg[b] !== prev_mac_reg[b])
                    toggle_mac_reg <= toggle_mac_reg + 1;
                if (probe_psum_out[b] !== prev_psum_out[b])
                    toggle_psum_out <= toggle_psum_out + 1;
                if (probe_wbus[b] !== prev_wbus[b])
                    toggle_weight_bus <= toggle_weight_bus + 1;
                if (probe_ibus[b] !== prev_ibus[b])
                    toggle_input_bus <= toggle_input_bus + 1;
            end
            for (int b = 0; b < 3; b++) begin
                if (probe_state[b] !== prev_state[b])
                    toggle_fsm_state <= toggle_fsm_state + 1;
            end
            for (int b = 0; b < K+4; b++) begin
                if (probe_conv_out[b] !== prev_conv_out[b])
                    toggle_conv_out <= toggle_conv_out + 1;
            end

            prev_mac_reg  <= probe_mac_reg;
            prev_psum_out <= probe_psum_out;
            prev_wbus     <= probe_wbus;
            prev_ibus     <= probe_ibus;
            prev_state    <= probe_state;
            prev_conv_out <= probe_conv_out;
        end
    end

    // ---- Layer config task ----
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
        wait(state_out == 3'd4 || state_out == 3'b110);  // LAYER_SWITCH (binary or gray)
        set_layer_config(L_WIDTH'(1), COMP_FC,
                         NL_WIDTH'(5), NL_WIDTH'(1),
                         L_WIDTH'(1), N_WIDTH'(5));
    end

    // ---- Main test ----
    initial begin
        $dumpfile("energy_compare.vcd");
        $dumpvars(0, tb_energy_compare);

        rst = 1; start = 0; layer_config_valid = 0; counting = 0;
        FClast = L_WIDTH'(1); N_classes = N_WIDTH'(5);
        layer_comp_type = COMP_CONV;
        nl = NL_WIDTH'(16); rl = NL_WIDTH'(1);
        layer_num = L_WIDTH'(0);

        repeat(4) @(posedge clk); rst = 0; repeat(2) @(posedge clk);

        $display("");
        $display("================================================================");
        $display("     ENERGY COMPARISON TESTBENCH");
        $display("     CNN Inference Engine - 864 PEs");
        $display("================================================================");
        $display("  Config: Layer0=Conv(nl=16) + Layer1=FC(nl=5,N=5)");
        $display("  Run this TWICE:");
        $display("    Run 1: With ORIGINAL RTL files");
        $display("    Run 2: With OPTIMIZED RTL files (energy_opt/rtl/)");
        $display("  Then compare the toggle counts below.");
        $display("================================================================");
        $display("");

        t_start = $time;
        counting = 1;
        start = 1'b1;

        set_layer_config(L_WIDTH'(0), COMP_CONV,
                         NL_WIDTH'(16), NL_WIDTH'(1),
                         L_WIDTH'(1), N_WIDTH'(5));

        wait(done_interrupt);
        t_done = $time;
        counting = 0;
        @(posedge clk); #1;

        latency_ns = t_done - t_start;

        begin
            automatic real sigma = (total_cycles > 0) ?
                        real'(active_cycles) / real'(total_cycles) : 0.0;
            automatic real tops  = (2.0 * real'(NPE) * CLK_HZ * 1.0 * sigma) / 1.0e12;

            // Extrapolate single-PE toggles to full design
            automatic longint unsigned total_toggles_sampled =
                toggle_mac_reg + toggle_psum_out + toggle_weight_bus +
                toggle_input_bus + toggle_fsm_state + toggle_conv_out;

            automatic longint unsigned total_toggles_estimated =
                (toggle_mac_reg * NPE) + (toggle_psum_out * NPE) +
                (toggle_weight_bus * NPE) + (toggle_input_bus * M) +
                toggle_fsm_state + toggle_conv_out;

            $display("");
            $display("================================================================");
            $display("  FUNCTIONAL CORRECTNESS");
            $display("================================================================");
            $display("  Detected class : %0d  (expected: 4)", CN_DC_out);
            if (CN_DC_out === N_WIDTH'(4))
                $display("  Status         : *** PASS ***");
            else
                $display("  Status         : *** FAIL *** (functional mismatch!)");

            $display("");
            $display("================================================================");
            $display("  PERFORMANCE METRICS");
            $display("================================================================");
            $display("  Total latency      : %0d ns  (%0d cycles)", latency_ns, total_cycles);
            $display("  Active cycles      : %0d / %0d  (sigma = %0.1f%%)",
                     active_cycles, total_cycles, sigma*100.0);
            $display("  Throughput @100MHz  : %0.6f TOPS", tops);

            $display("");
            $display("================================================================");
            $display("  ENERGY PROXY: TOGGLE ACTIVITY (per PE[0][0])");
            $display("================================================================");
            $display("  +-----------------------+-------------+");
            $display("  | Signal                | Toggles     |");
            $display("  +-----------------------+-------------+");
            $display("  | MAC pipeline reg      | %11d |", toggle_mac_reg);
            $display("  | Psum output reg       | %11d |", toggle_psum_out);
            $display("  | Weight bus slice       | %11d |", toggle_weight_bus);
            $display("  | Input bus slice        | %11d |", toggle_input_bus);
            $display("  | IEC FSM state          | %11d |", toggle_fsm_state);
            $display("  | conv_out               | %11d |", toggle_conv_out);
            $display("  +-----------------------+-------------+");
            $display("  | TOTAL (sampled)        | %11d |", total_toggles_sampled);
            $display("  +-----------------------+-------------+");

            $display("");
            $display("================================================================");
            $display("  FULL-DESIGN TOGGLE ESTIMATE (scaled to 864 PEs)");
            $display("================================================================");
            $display("  MAC toggles  x%0d PEs  : %0d", NPE, toggle_mac_reg * NPE);
            $display("  Psum toggles x%0d PEs  : %0d", NPE, toggle_psum_out * NPE);
            $display("  WBus toggles x%0d PEs  : %0d", NPE, toggle_weight_bus * NPE);
            $display("  IBus toggles x%0d LMs  : %0d", M, toggle_input_bus * M);
            $display("  FSM + conv_out          : %0d", toggle_fsm_state + toggle_conv_out);
            $display("  -----------------------------------------");
            $display("  >>> TOTAL DESIGN TOGGLES : %0d <<<", total_toggles_estimated);
            $display("");
            $display("  Energy is PROPORTIONAL to toggle count.");
            $display("  Lower toggles = Lower dynamic energy.");
            $display("================================================================");
            $display("");
        end

        start = 0;
        #200 $finish;
    end

    // Watchdog
    initial begin #48000; $display("  [TIMEOUT]"); $finish; end

endmodule
