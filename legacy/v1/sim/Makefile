# PROTEUS cocotb harness (Icarus).  Run: make -C sim   (or: cd sim && make)
#
# The DUT is the REAL top with four real engines; the test drives only the
# host SPI pins and checks pin-level behaviour (see sim/test_smoke.py).
#
# PYTHON_BIN/COCOTB_CONFIG are resolved to the repo virtualenv explicitly (with
# a fallback to whatever is on PATH), because cocotb's own Makefile.sim derives
# PYTHON_BIN from `cocotb-config --python-bin` -- if that lookup fails it
# silently falls back to python3, which has no cocotb installed.

SIM = icarus
TOPLEVEL_LANG = verilog

COCOTB_TOPLEVEL     = tt_um_proteus
COCOTB_TEST_MODULES = test_smoke

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

SRC_DIR = $(CURDIR)/../src
VERILOG_SOURCES = $(SRC_DIR)/tt_um_proteus.v \
                  $(SRC_DIR)/proteus_engine.v \
                  $(SRC_DIR)/proteus_host.v
VERILOG_INCLUDE_DIRS = $(SRC_DIR)

# sim/host.py must be importable by the test module; tools/ holds isa.py,
# model.py and diffgen.py, which the differential test imports directly.
export PYTHONPATH := $(CURDIR):$(CURDIR)/../tools:$(PYTHONPATH)

# `make diff` runs the DUT-vs-model differential test (see sim/test_diff.py).
# DIFF_SEEDS / DIFF_CYCLES bound the corpus and the per-program cycle budget.
# NOTE: without this line `diff` (defined before the cocotb include) would be
# make's default goal, and plain `make` would recurse into itself forever.
.DEFAULT_GOAL := all

diff:
	$(MAKE) COCOTB_TEST_MODULES=test_diff SIM_BUILD=$(CURDIR)/sim_build/diff

.PHONY: diff

# `make protocols` runs the four firmware protocol E2E tests on the real RTL
# (test_protocols.py): UART TX/RX, SPI master, I2C master, all decoded at the
# pads by independent models.  Separate SIM_BUILD and results file so it does
# not disturb the default smoke/diff builds.
protocols:
	$(MAKE) COCOTB_TEST_MODULES=test_protocols \
	        SIM_BUILD=$(CURDIR)/sim_build/protocols \
	        COCOTB_RESULTS_FILE=$(CURDIR)/results_protocols.xml

.PHONY: protocols

include $(shell $(COCOTB_CONFIG) --makefiles)/Makefile.sim
