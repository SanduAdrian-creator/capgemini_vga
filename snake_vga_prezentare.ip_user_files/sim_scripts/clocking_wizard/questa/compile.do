vlib questa_lib/work
vlib questa_lib/msim

vlib questa_lib/msim/xil_defaultlib

vmap xil_defaultlib questa_lib/msim/xil_defaultlib

vlog -work xil_defaultlib  -incr -mfcu  "+incdir+../../../../snake_vga.gen/sources_1/bd/clocking_wizard/ipshared/a415" "+incdir+../../../../../../AMDDesignTools/2025.2/Vivado/data/rsb/busdef" \
"../../../bd/clocking_wizard/ip/clocking_wizard_clk_wiz_0_0/clocking_wizard_clk_wiz_0_0_clk_wiz.v" \
"../../../bd/clocking_wizard/ip/clocking_wizard_clk_wiz_0_0/clocking_wizard_clk_wiz_0_0.v" \
"../../../bd/clocking_wizard/sim/clocking_wizard.v" \


vlog -work xil_defaultlib \
"glbl.v"

