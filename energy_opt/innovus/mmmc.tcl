
# mmmc.tcl — Single-corner MMMC setup (fast only)

create_library_set -name libs_fast \
  -timing [list \
    /home/cadencea8/ASIC_NG/gsclib045_all_v4.8/gsclib045/timing/fast_vdd1v2_basicCells.lib \
    /home/cadencea8/ASIC_NG/gsclib045_all_v4.8/gsclib045/timing/fast_vdd1v2_multibitsDFF.lib \
    /home/cadencea8/ASIC_NG/gsclib045_all_v4.8/gsclib045_hvt/timing/fast_vdd1v2_basicCells_hvt.lib \
    /home/cadencea8/ASIC_NG/gsclib045_all_v4.8/gsclib045_lvt/timing/fast_vdd1v2_basicCells_lvt.lib \
  ]

create_rc_corner -name rc_typical \
  -qrc_tech /home/cadencea8/ASIC_NG/gsclib045_all_v4.8/gsclib045_tech/qrc/qx/gpdk045.tch

create_delay_corner -name dc_fast -library_set libs_fast -rc_corner rc_typical

create_constraint_mode -name func_mode \
  -sdc_files [list /home/cadencea8/ASIC_NG/RUN/Optimized/netlists_optimized/CNN_Inference_Engine_optimized.sdc]

create_analysis_view -name view_fast -constraint_mode func_mode -delay_corner dc_fast

set_analysis_view -setup {view_fast} -hold {view_fast}

