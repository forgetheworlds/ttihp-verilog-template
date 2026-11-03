# PROTEUS (hybrid v2) cocotb harness.  Run: make -C sim
#
# The DUT is the REAL top (three engines + five assists) and every test drives
# only the host SPI pins and decodes the protocol at the pads.
#
#   make                  # = the protocols suite (test_protocols, 6 tests)
#   make protocols        # same, named explicitly
#   make smoke            # the v2 map test alone (identity, CSR bank, pages)
#   make diff             # RTL vs tools/model.py differential (test_diff)
#   COCOTB_TEST_MODULES=x make   # one module
#   COCOTB_TEST_FILTER=proteus_uart_tx_pins make   # one test
#
# PYTHON_BIN/COCOTB_CONFIG are resolved to the repo virtualenv explicitly (with
# a fallback to whatever is on PATH), because cocotb's own Makefile.sim derives
# PYTHON_BIN from `cocotb-config --python-bin` -- if that lookup fails it
# silently falls back to python3, which has no cocotb installed.

SIM = icarus
TOPLEVEL_LANG = verilog

COCOTB_TOPLEVEL     = tt_um_proteus
COCOTB_TEST_MODULES = test_protocols

VENV_BIN := $(abspath $(CURDIR)/../.venv/bin)
ifeq ($(wildcard $(VENV_BIN)/python),)
  COCOTB_CONFIG := cocotb-config
  MY_PYTHON     := python3
else
  COCOTB_CONFIG := $(VENV_BIN)/cocotb-config
  MY_PYTHON     := $(VENV_BIN)/python
endif
export PATH := $(VENV_BIN):$(PATH)
override PYTHON_BIN := $(MY_PYTHON)

# The submission source list (info.yaml source_files, 12 files).  55.18 % flat.
SRC_DIR = $(CURDIR)/../src
VERILOG_SOURCES = $(SRC_DIR)/proteus_defs.vh \
                  $(SRC_DIR)/proteus_engine.v \
                  $(SRC_DIR)/proteus_host.v \
                  $(SRC_DIR)/proteus_assist.v \
                  $(SRC_DIR)/crc_bit.v \
                  $(SRC_DIR)/assist_fifo.v \
                  $(SRC_DIR)/shiftreg32.v \
                  $(SRC_DIR)/nrzi_enc.v \
                  $(SRC_DIR)/nrzi_dec.v \
                  $(SRC_DIR)/manchester_enc.v \
                  $(SRC_DIR)/manchester_dec.v \
                  $(SRC_DIR)/tt_um_proteus.v
VERILOG_INCLUDE_DIRS = $(SRC_DIR)

# host.py and the ISA/assembler/model in tools/ must be importable.
export PYTHONPATH := $(CURDIR):$(CURDIR)/../tools:$(PYTHONPATH)

# Separate build dir and results file so a module run does not disturb another.
SIM_BUILD            = $(CURDIR)/sim_build/protocols
COCOTB_RESULTS_FILE  = $(CURDIR)/results_protocols.xml

.DEFAULT_GOAL := all

# `make protocols` -- the default suite, named explicitly.  A bare `make` runs
# the same thing through COCOTB_TEST_MODULES above.
protocols:
	$(MAKE) COCOTB_TEST_MODULES=test_protocols \
	        SIM_BUILD=$(CURDIR)/sim_build/protocols \
	        COCOTB_RESULTS_FILE=$(CURDIR)/results_protocols.xml

# `make smoke` -- the v2 map test alone: identity, assist CSR bank and every
# engine program page (defect D1's regression), no firmware image loaded.
smoke:
	$(MAKE) COCOTB_TEST_MODULES=test_protocols \
	        COCOTB_TEST_FILTER=proteus_v2_map \
	        SIM_BUILD=$(CURDIR)/sim_build/smoke \
	        COCOTB_RESULTS_FILE=$(CURDIR)/results_smoke.xml

# `make diff` runs the DUT-vs-model differential test (sim/test_diff.py):
# DIFF_SEEDS generated programs plus the crafted corners from tools/diffgen.py,
# the same words into the RTL over the host SPI and into tools/model.py, every
# architectural field compared each cycle.
# DIFF_SEEDS / DIFF_CYCLES bound the corpus and the per-program cycle budget.
# (The .DEFAULT_GOAL above keeps these targets from hijacking a plain `make`.)
diff:
	$(MAKE) COCOTB_TEST_MODULES=test_diff \
	        SIM_BUILD=$(CURDIR)/sim_build/diff \
	        COCOTB_RESULTS_FILE=$(CURDIR)/results_diff.xml

.PHONY: protocols smoke diff

include $(shell $(COCOTB_CONFIG) --makefiles)/Makefile.sim
