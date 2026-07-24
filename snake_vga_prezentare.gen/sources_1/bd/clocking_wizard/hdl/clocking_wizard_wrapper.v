//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.2 (win64) Build 6299465 Fri Nov 14 19:35:11 GMT 2025
//Date        : Tue Jul 14 09:12:09 2026
//Host        : lpt_elementaro running 64-bit major release  (build 9200)
//Command     : generate_target clocking_wizard_wrapper.bd
//Design      : clocking_wizard_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module clocking_wizard_wrapper
   (clk_100MHz,
    clk_out1_0,
    reset_rtl_0);
  input clk_100MHz;
  output clk_out1_0;
  input reset_rtl_0;

  wire clk_100MHz;
  wire clk_out1_0;
  wire reset_rtl_0;

  clocking_wizard clocking_wizard_i
       (.clk_100MHz(clk_100MHz),
        .clk_out1_0(clk_out1_0),
        .reset_rtl_0(reset_rtl_0));
endmodule
