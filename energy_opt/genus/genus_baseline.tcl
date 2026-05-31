# genus_baseline.tcl — Baseline Synthesis (No Power Opts)
# Design: CNN_Inference_Engine | PDK: gsclib045 (45nm)

set DESIGN CNN_Inference_Engine

# ---- PATHS (UPDATE THESE) ----
set rtlDir /home/<YOUR_USERNAME>/Documents/<YOUR_PROJECT>/RTL_BASELINE

set libDir [list \
  /home/<YOUR_USERNAME>/Documents/<YOUR_PROJECT>/gsclib045_all_v4.8/gsclib045/timing     \
  /home/<YOUR_USERNAME>/Documents/<YOUR_PROJECT>/gsclib045_all_v4.8/gsclib045_hvt/timing  \
  /home/<YOUR_USERNAME>/Documents/<YOUR_PROJECT>/gsclib045_all_v4.8/gsclib045_lvt/timing  \
]

set libList [list \
  fast_vdd1v2_basicCells.lib \
  fast_vdd1v2_multibitsDFF.lib \
  fast_vdd1v2_basicCells_hvt.lib \
  fast_vdd1v2_basicCells_lvt.lib \
]

# ---- SETUP ----
set_db init_lib_search_path $libDir
set_db init_hdl_search_path {$rtlDir}
set_db max_cpus_per_server 8

# ---- READ LIBS + LEF + QRC ----
read_libs $libList

read_physical -lefs { \
  /home/<YOUR_USERNAME>/Documents/<YOUR_PROJECT>/gsclib045_all_v4.8/gsclib045/lef/gsclib045_tech.lef \
  /home/<YOUR_USERNAME>/Documents/<YOUR_PROJECT>/gsclib045_all_v4.8/gsclib045/lef/gsclib045_macro.lef \
  /home/<YOUR_USERNAME>/Documents/<YOUR_PROJECT>/gsclib045_all_v4.8/gsclib045/lef/gsclib045_multibitsDFF.lef \
  /home/<YOUR_USERNAME>/Documents/<YOUR_PROJECT>/gsclib045_all_v4.8/gsclib045_hvt/lef/gsclib045_hvt_macro.lef \
  /home/<YOUR_USERNAME>/Documents/<YOUR_PROJECT>/gsclib045_all_v4.8/gsclib045_lvt/lef/gsclib045_lvt_macro.lef \
}

set_db qrc_tech_file /home/<YOUR_USERNAME>/Documents/<YOUR_PROJECT>/gsclib045_all_v4.8/gsclib045_tech/qrc/qx/gpdk045.tch

# ---- READ RTL ----
read_hdl -sv [list \
  ${rtlDir}/kpu.sv \
  ${rtlDir}/CU.sv \
  ${rtlDir}/IEC.sv \
  ${rtlDir}/CNN_inference_engine.sv \
]

elaborate $DESIGN
set_top_module $DESIGN

# ---- CONSTRAINTS ----
create_clock -name clk -period 10.0 [get_ports clk]
set_input_delay  -clock clk 1.0 [all_inputs]
set_output_delay -clock clk 1.0 [all_outputs]
check_design -unresolved

# ---- SYNTHESIZE ----
syn_generic
syn_map
syn_opt

# ---- REPORTS ----
file mkdir reports_baseline
report_power -unit mW   > reports_baseline/power.rpt
report_area              > reports_baseline/area.rpt
report_timing -nworst 5  > reports_baseline/timing.rpt

# ---- WRITE OUTPUTS ----
file mkdir netlists_baseline
write_hdl     > netlists_baseline/${DESIGN}_baseline.v
write_sdc     > netlists_baseline/${DESIGN}_baseline.sdc
write_sdf -timescale ns > netlists_baseline/${DESIGN}_baseline.sdf
write_db -to_file ${DESIGN}_baseline.db

puts "BASELINE SYNTHESIS DONE"
