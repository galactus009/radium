# ----------------------------------------------------------------------------
# Radium top-level Makefile
#
# Single Lazarus + FPC + Qt6 desktop app. Mac primary, Linux must, Windows
# deferred. Two artefacts:
#   Bin/Radium       — the GUI client of thoriumd
#   Bin/RadiumTests  — test runner (mORMot TSynTestCase host)
#
# Targets:
#   make app          build Bin/Radium
#   make tests        build Bin/RadiumTests
#   make all          both
#   make run          build + run Radium
#   make run-tests    build + run tests
#   make clean        remove Bin/ + Lib/
#
# Env knobs:
#   LAZBUILD=<path>   override lazbuild discovery
#   MORMOT2=<path>    mORMot 2 source root (defaults below)
# ----------------------------------------------------------------------------

ROOT      := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
MORMOT2   ?= /Users/rbhaskar/Development/mormot2
BIN       := $(ROOT)/Bin
LIB       := $(ROOT)/Lib

LPI_DIR   := $(ROOT)/Projects
APP_LPI   := $(LPI_DIR)/Radium.lpi
TESTS_LPI := $(LPI_DIR)/RadiumTests.lpi

LAZBUILD := $(shell command -v lazbuild 2>/dev/null)

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  BUILD_SCRIPT := $(ROOT)/Build/build-macos.sh
else ifeq ($(UNAME_S),Linux)
  BUILD_SCRIPT := $(ROOT)/Build/build-linux.sh
else
  BUILD_SCRIPT :=
endif

.PHONY: all app tests run run-tests clean help

all: app tests

help:
	@echo "Targets: app | tests | all | run | run-tests | clean"
	@echo "Env:     MORMOT2=$(MORMOT2)"
	@echo "Tools:   lazbuild=$(if $(LAZBUILD),$(LAZBUILD),<not found>)"
	@echo "Host:    $(UNAME_S)"

app:
	@if [ -z "$(BUILD_SCRIPT)" ]; then \
	  echo "Unsupported host: $(UNAME_S). Run lazbuild manually." >&2; exit 1; \
	fi
	MORMOT2=$(MORMOT2) $(BUILD_SCRIPT)

tests:
	@if [ -z "$(LAZBUILD)" ]; then \
	  echo "lazbuild not found" >&2; exit 1; \
	fi
	@mkdir -p $(BIN) $(LIB)
	MORMOT2=$(MORMOT2) $(LAZBUILD) $(TESTS_LPI)

run: app
	$(BIN)/Radium

run-tests: tests
	$(BIN)/RadiumTests

clean:
	rm -rf $(BIN) $(LIB)
	@echo "[radium] cleaned"
