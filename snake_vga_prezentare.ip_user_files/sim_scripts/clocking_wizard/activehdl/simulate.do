transcript off
onbreak {quit -force}
onerror {quit -force}
transcript on

asim +access +r +m+clocking_wizard  -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.clocking_wizard xil_defaultlib.glbl

do {clocking_wizard.udo}

run 1000ns

endsim

quit -force
