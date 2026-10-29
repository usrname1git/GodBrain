#include "tool_evidence.h"
#include <cassert>
#include <iostream>

int main() {
    std::string ledger = "repo map", output(71211, 'x'), error;
    assert(tool_evidence::append(ledger, output, true, error));
    assert(output.size() == 71211);
    assert(ledger.size() == 71220);
    const std::string before = ledger;
    output.assign(256 * 1024, 'y');
    assert(!tool_evidence::append(ledger, output, true, error));
    assert(ledger == before);
    assert(error.find("No partial-file analysis") != std::string::npos);
    output = "read_local_file [truncated 256KiB]";
    assert(!tool_evidence::append(ledger, output, true, error));
    ledger.clear();
    output.assign(13000, 'z');
    assert(tool_evidence::append(ledger, output, false, error));
    assert(ledger.find("[truncated tool ledger") != std::string::npos);
    std::cout << "PASS: complete 71KB evidence, overflow atomicity, explicit truncation.\n";
}
