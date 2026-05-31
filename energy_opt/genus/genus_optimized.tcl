# genus_optimized.tcl — Energy-Optimized Synthesis
# Design: CNN_Inference_Engine | PDK: gsclib045 (45nm)

set DESIGN CNN_Inference_Engine

# ---- PATHS (UPDATE THESE) ----
set rtlDir /home/cadencea8/ASIC_NG/cnn_asic_project/rtl/optimized

set libDir [list \
  /home/cadencea8/ASIC_NG/cnn_asic_project/gsclib045_all_v4.8/gsclib045/timing     \
  /home/cadencea8/ASIC_NG/cnn_asic_project/gsclib045_all_v4.8/gsclib045_hvt/timing  \
  /home/cadencea8/ASIC_NG/cnn_asic_project/gsclib045_all_v4.8/gsclib045_lvt/timing  \
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

# ---- SYNTHESIS EFFORT ----
set_db syn_generic_effort high
set_db syn_map_effort high
set_db syn_opt_effort high

# ---- CLOCK GATING (must be BEFORE elaborate) ----
set_db lp_insert_clock_gating true

# ---- READ LIBS + LEF + QRC ----
read_libs $libList

read_physical -lefs { \
  /home/cadencea8/ASIC_NG/cnn_asic_project/gsclib045_all_v4.8/gsclib045/lef/gsclib045_tech.lef \
  /home/cadencea8/ASIC_NG/cnn_asic_project/gsclib045_all_v4.8/gsclib045/lef/gsclib045_macro.lef \
  /home/cadencea8/ASIC_NG/cnn_asic_project/gsclib045_all_v4.8/gsclib045/lef/gsclib045_multibitsDFF.lef \
  /home/cadencea8/ASIC_NG/cnn_asic_project/gsclib045_all_v4.8/gsclib045_hvt/lef/gsclib045_hvt_macro.lef \
  /home/cadencea8/ASIC_NG/cnn_asic_project/gsclib045_all_v4.8/gsclib045_lvt/lef/gsclib045_lvt_macro.lef \
}

set_db qrc_tech_file /home/cadencea8/ASIC_NG/cnn_asic_project/gsclib045_all_v4.8/gsclib045_tech/qrc/qx/gpdk045.tch

# ---- READ OPTIMIZED RTL ----
read_hdl -sv [list \
  ${rtlDir}/kpu_optimized.sv \
  ${rtlDir}/CU_optimized.sv \
  ${rtlDir}/IEC_optimized.sv \
  ${rtlDir}/CNN_inference_engine_optimized.sv \
]

elaborate $DESIGN
set_top_module $DESIGN

# ---- CONSTRAINTS (same as baseline) ----
create_clock -name clk -period 10.0 [get_ports clk]
set_input_delay  -clock clk 1.0 [all_inputs]
set_output_delay -clock clk 1.0 [all_outputs]
check_design -unresolved

# ---- SYNTHESIZE (high effort) ----
syn_generic
syn_map
syn_opt

# ---- REPORTS ----
file mkdir reports_optimized
report_power -unit mW    > reports_optimized/power.rpt
report_area              > reports_optimized/area.rpt
report_timing -nworst 5  > reports_optimized/timing.rpt

# ---- WRITE OUTPUTS ----
file mkdir netlists_optimized
write_hdl     > netlists_optimized/${DESIGN}_optimized.v
write_sdc     > netlists_optimized/${DESIGN}_optimized.sdc
write_sdf -timescale ns > netlists_optimized/${DESIGN}_optimized.sdf
write_db -to_file ${DESIGN}_optimized.db

puts "OPTIMIZED SYNTHESIS DONE"
