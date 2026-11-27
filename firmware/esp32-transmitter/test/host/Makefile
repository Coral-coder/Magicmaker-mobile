# Host tests for the hub's SYNC v1 codec (../../sync_*.h) and the relay protocol
# (../../relay_proto.h). g++ only, no dependencies.
#
#   make test          build and run every check (CI: make -C firmware/esp32-transmitter/test/host test)
#   make relay         build and run test_relay only
#   make clean
#
#   test_sync    (C++17)  every group of tools/sync/vectors.json + every transcript (README schema)
#   cxx11_smoke  (gnu++11, the Arduino-ESP32 sketch standard) the headers compile C++11-clean with
#                -Werror, and a phone/hub Session pair handshakes and syncs through the framer
#   test_relay   (C++17)  CMD parsing (power_off, set_low_cutoff, ...) and the STATUS object
#
# Build outputs go to build/ (git-ignored).

CXX ?= g++
WARN := -Wall -Wextra -Werror -Wshadow -Wpedantic -Wcast-align -Wformat=2 -Wundef
SANITIZE ?= -fsanitize=address,undefined -fno-omit-frame-pointer
CXXFLAGS_17 := -std=c++17 -O1 -g $(WARN) $(SANITIZE)
CXXFLAGS_11 := -std=gnu++11 -Os $(WARN) -Wno-pedantic -fno-rtti $(SANITIZE)

HERE := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SYNC_DIR ?= $(abspath $(HERE)/../../../../tools/sync)
BUILD := $(HERE)build
HEADERS := $(wildcard $(HERE)../../sync_*.h)
RELAY_HEADERS := $(HERE)../../relay_proto.h $(HERE)../../relay_engine.h

.PHONY: all test relay clean

all: $(BUILD)/test_sync $(BUILD)/cxx11_smoke $(BUILD)/test_relay

test: all
	$(BUILD)/cxx11_smoke
	$(BUILD)/test_sync $(SYNC_DIR)
	$(BUILD)/test_relay

relay: $(BUILD)/test_relay
	$(BUILD)/test_relay

$(BUILD)/test_sync: $(HERE)test_sync.cc $(HERE)json_mini.hpp $(HEADERS) | $(BUILD)
	$(CXX) $(CXXFLAGS_17) -o $@ $(HERE)test_sync.cc

$(BUILD)/cxx11_smoke: $(HERE)cxx11_smoke.cc $(HEADERS) | $(BUILD)
	$(CXX) $(CXXFLAGS_11) -o $@ $(HERE)cxx11_smoke.cc

$(BUILD)/test_relay: $(HERE)test_relay.cc $(HERE)json_mini.hpp $(RELAY_HEADERS) | $(BUILD)
	$(CXX) $(CXXFLAGS_17) -o $@ $(HERE)test_relay.cc

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
