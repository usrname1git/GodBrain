#include "surgery.h"

#include <iostream>
#include <string>

static bool expect(bool ok, const char* msg) {
    if (!ok) std::cerr << "FAIL " << msg << std::endl;
    return ok;
}

int main() {
    bool pass = true;
    const surgery::Outcome empty = surgery::execute_self_command("  \t");
    pass &= expect(!empty.ok, "empty is not ok");
    pass &= expect(empty.exit_code < 0, "empty has no exit");
    pass &= expect(empty.text.find("empty") != std::string::npos, "empty text");

    const surgery::Outcome bad = surgery::execute_self_command("exit 3");
    pass &= expect(!bad.ok, "nonzero is not ok");
    pass &= expect(bad.exit_code == 3, "nonzero exit");
    pass &= expect(bad.text.find("EXIT CODE 3") != std::string::npos, "nonzero text");

    const surgery::Outcome good = surgery::execute_self_command("Write-Output 'desk-ok'");
    pass &= expect(good.ok, "zero is ok");
    pass &= expect(good.exit_code == 0, "zero exit");
    pass &= expect(good.text.find("desk-ok") != std::string::npos, "zero text");

    if (!pass) return 1;
    std::cout << "surgery_outcome_test ok" << std::endl;
    return 0;
}
