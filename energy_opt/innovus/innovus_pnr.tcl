
# ============================================================
# innovus_pnr.tcl — Place & Route for CNN Inference Engine
# Cadence Innovus v23.13 | PDK: gsclib045 (45nm)
# ============================================================

set DESIGN CNN_Inference_Engine

# ============================================================
# 1. DESIGN IMPORT
# ============================================================

set init_mmmc_file /home/cadencea8/ASIC_NG/innovus/mmmc.tcl
set init_lef_file [list \
  /home/cadencea8/ASIC_NG/gsclib045_all_v4.8/gsclib045/lef/gsclib045_tech.lef \
  /home/cadencea8/ASIC_NG/gsclib045_all_v4.8/gsclib045/lef/gsclib045_macro.lef \
  /home/cadencea8/ASIC_NG/gsclib045_all_v4.8/gsclib045/lef/gsclib045_multibitsDFF.lef \
  /home/cadencea8/ASIC_NG/gsclib045_all_v4.8/gsclib045_hvt/lef/gsclib045_hvt_macro.lef \
  /home/cadencea8/ASIC_NG/gsclib045_all_v4.8/gsclib045_lvt/lef/gsclib045_lvt_macro.lef \
]
set init_verilog /home/cadencea8/ASIC_NG/RUN/Optimized/netlists_optimized/CNN_Inference_Engine_optimized.v
set init_top_cell $DESIGN

# Power net names — using ALL known variable name variants
set init_pwr_net {VDD}
set init_gnd_net {VSS}
set init_pwr_nets {VDD}
set init_gnd_nets {VSS}
set init_pwr_nets_list {VDD}
set init_gnd_nets_list {VSS}

# Also try Stylus API (modern Innovus)
catch {set_db init_power_nets VDD}
catch {set_db init_ground_nets VSS}

init_design

# Connect power pins (legacy syntax)
catch {globalNetConnect VDD -type pgpin -pin VDD -all}
catch {globalNetConnect VSS -type pgpin -pin VSS -all}
catch {applyGlobalNets}

# Also try modern Stylus CUI syntax
catch {connect_global_net VDD -type pg_pin -pin_base_name VDD -all}
catch {connect_global_net VSS -type pg_pin -pin_base_name VSS -all}

# OCV analysis from the start
setAnalysisMode -analysisType onChipVariation
catch {setAnalysisMode -cppr both}
# ============================================================
# 2. FLOORPLAN
# ============================================================

floorPlan -site CoreSite -r 1.0 0.5 20 20 20 20

# ============================================================
# 3. POWER PLANNING
# ============================================================

addRing -type core_rings \
  -nets {VDD VSS} \
  -width 3 -spacing 1.5 \
  -layer {top Metal5 bottom Metal5 left Metal6 right Metal6}

addStripe -nets {VDD VSS} \
  -layer Metal6 \
  -width 3 -spacing 1.5 \
  -set_to_set_distance 30 \
  -start_from left

sroute -connect {blockPin padPin corePin floatingStripe} \
  -allowJogging 1 \
  -allowLayerChange 1 \
  -nets {VDD VSS}

# ============================================================
# 4. PLACEMENT
# ============================================================

setPlaceMode -place_global_place_io_pins true
place_opt_design

# ============================================================
# 4.5. TIE CELL INSERTION
# ============================================================

catch {setTieHiLoMode -maxDistance 100 -maxFanout 10}
catch {addTieHiLo -cell {TIEHI TIELO}}

# ============================================================
# 5. CLOCK TREE SYNTHESIS
# ============================================================

clock_opt_design

# ============================================================
# 6. ROUTING
# ============================================================

routeDesign

# Set process node for extraction accuracy
catch {setDesignMode -process 45}

# Post-route RC extraction — use low effort (high needs QRC tech file on all corners)
setExtractRCMode -engine postRoute -effortLevel low

optDesign -postRoute
optDesign -postRoute -hold

# ============================================================
# 7. FILLER CELLS
# ============================================================

if {[catch {addFiller -cell FILL1 FILL2 FILL4 FILL8 FILL16 FILL32 FILL64 -prefix FILLER} err]} {
    puts "WARN: Filler insertion failed ($err) — trying alternative names"
    catch {addFiller -cell FILLCELL_X1 FILLCELL_X2 FILLCELL_X4 FILLCELL_X8 FILLCELL_X16 FILLCELL_X32 -prefix FILLER}
}
catch {ecoRoute}

# ============================================================
# 8. SIGNOFF REPORTS
# ============================================================

file mkdir reports_pnr

report_timing -nworst 10 > reports_pnr/timing_setup.rpt
report_timing -early -nworst 10 > reports_pnr/timing_hold.rpt
report_power > reports_pnr/power.rpt
report_area > reports_pnr/area.rpt
catch {verifyGeometry > reports_pnr/geometry.rpt}
catch {verifyConnectivity -type all > reports_pnr/connectivity.rpt}
catch {verifyProcessAntenna > reports_pnr/antenna.rpt}
catch {summaryReport > reports_pnr/summary.rpt}

# ============================================================
# 9. OUTPUT FILES
# ============================================================

file mkdir outputs_pnr

streamOut outputs_pnr/${DESIGN}.gds \
  -mapFile /home/cadencea8/ASIC_NG/gsclib045_all_v4.8/gsclib045/lef/gsclib045.map \
  -libName ${DESIGN} \
  -structureName ${DESIGN} \
  -units 1000 \
  -mode ALL

defOut outputs_pnr/${DESIGN}.def
saveNetlist outputs_pnr/${DESIGN}_final.v
saveDesign ${DESIGN}_pnr.enc

puts ""
puts "=============================================="
puts "  PLACE & ROUTE COMPLETE"
puts "  GDSII:   outputs_pnr/${DESIGN}.gds"
puts "  Reports: reports_pnr/"
puts "=============================================="
