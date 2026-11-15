CXX ?= c++
CPPFLAGS += -isystem ../cpp_kernel -isystem ../cpp_tools
CXXFLAGS ?= -O2
CXXFLAGS += -std=c++17 -Wall -Wextra -Werror -pthread
HEADERS = ../cpp_kernel/httplib.h ../cpp_kernel/json.hpp ../cpp_tools/keccak256.hpp

.PHONY: all test
all: build/godbrain-memory

build:
	mkdir -p build

build/godbrain-memory: main.cpp $(HEADERS) | build
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) main.cpp -o $@

build/client-tests: tests.cpp main.cpp $(HEADERS) | build
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) tests.cpp -o $@

test: build/client-tests
	./build/client-tests
