transcript off
onbreak {quit -force}
onerror {quit -force}
transcript on

vlib work
vlib activehdl/xil_defaultlib

vmap xil_defaultlib activehdl/xil_defaultlib

vlog -work xil_defaultlib  -v2k5 "+incdir+../../../../snake_vga.gen/sources_1/bd/clocking_wizard/ipshared/a415" "+incdir+../../../../../../AMDDesignTools/2025.2/Vivado/data/rsb/busdef" -l xil_defaultlib \
"../../../bd/clocking_wizard/ip/clocking_wizard_clk_wiz_0_0/clocking_wizard_clk_wiz_0_0_clk_wiz.v" \
"../../../bd/clocking_wizard/ip/clocking_wizard_clk_wiz_0_0/clocking_wizard_clk_wiz_0_0.v" \
"../../../bd/clocking_wizard/sim/clocking_wizard.v" \


vlog -work xil_defaultlib \
"glbl.v"

