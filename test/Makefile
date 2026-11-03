# Makefile -- PROTEUS (hybrid v2) Tiny Tapeout harness.
#
# Same structure as the v1 Makefile (archived at legacy/v1/test/Makefile); the
# only differences are
#   * PROJECT_SOURCES lists the 12 hybrid files (info.yaml source_files), and
#   * PYTHONPATH adds sim/ (the cocotb SPI driver) and tools/ (the ISA).
#
# Run: make -C test           (RTL)
#      make -C test GATES=yes (netlist, needs PDK_ROOT + gate_level_netlist.v)

# defaults
SIM ?= icarus
FST ?= -fst # Use more efficient FST format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(CURDIR)/../src
PROJECT_SOURCES = proteus_defs.vh proteus_engine.v proteus_host.v \
                  proteus_assist.v crc_bit.v assist_fifo.v shiftreg32.v \
                  nrzi_enc.v nrzi_dec.v manchester_enc.v manchester_dec.v \
                  tt_um_proteus.v

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD				= sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

# Gate level simulation:
SIM_BUILD				= sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DSIM
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/verilog/sg13cmos5l_io.v
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/verilog/sg13cmos5l_udp.v
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/verilog/sg13cmos5l_stdcell.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(CURDIR)/gate_level_netlist.v

endif

# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS 		+= -I$(SRC_DIR)

# Include the testbench sources:
VERILOG_SOURCES += $(CURDIR)/tb.v
TOPLEVEL = tb

# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test

# The test imports the SPI driver from ../sim; the ISA tables come from
# ../tools.
export PYTHONPATH := $(CURDIR)/../sim:$(CURDIR)/../tools:$(PYTHONPATH)

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim
