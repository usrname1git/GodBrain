#include "mouth_select.h"

#include <iostream>

static int fails = 0;

static void expect(bool ok, const char* msg) {
    if (ok) return;
    std::cerr << "FAIL " << msg << std::endl;
    ++fails;
}

static void check(const char* name, const mouth_select::Probes& in,
                  mouth_select::Kind kind, int port, bool busy, bool start) {
    const mouth_select::Choice got = mouth_select::select(in);
    expect(got.kind == kind, name);
    expect(got.port == port, name);
    expect(got.busy == busy, name);
    expect(got.start_runner == start, name);
}

int main() {
    mouth_select::Probes paused_ready;
    paused_ready.paused = true;
    paused_ready.exl3_up = true;
    paused_ready.llama_up = true;
    check("paused exl3 wins over llama", paused_ready, mouth_select::Kind::Exl3, 8888, false, false);

    mouth_select::Probes paused_busy = paused_ready;
    paused_busy.exl3_busy = true;
    check("paused exl3 busy", paused_busy, mouth_select::Kind::Exl3, 8888, true, false);

    mouth_select::Probes paused_down;
    paused_down.paused = true;
    paused_down.llama_up = false;
    check("paused exl3 down does not start llama", paused_down, mouth_select::Kind::None, 0, false, false);

    mouth_select::Probes llama_ready;
    llama_ready.llama_up = true;
    check("llama ready", llama_ready, mouth_select::Kind::Llama, 8000, false, false);

    mouth_select::Probes llama_busy = llama_ready;
    llama_busy.llama_busy = true;
    check("llama busy", llama_busy, mouth_select::Kind::Llama, 8000, true, false);

    mouth_select::Probes slot;
    slot.slot_held = true;
    check("held slot does not start llama", slot, mouth_select::Kind::None, 0, false, false);

    mouth_select::Probes exl3_unpaused;
    exl3_unpaused.exl3_up = true;
    check("unpaused exl3 does not start llama", exl3_unpaused, mouth_select::Kind::None, 0, false, false);

    mouth_select::Probes empty;
    check("nothing up may start llama", empty, mouth_select::Kind::None, 0, false, true);

    if (fails != 0) return 1;
    std::cout << "mouth_select_test ok" << std::endl;
    return 0;
}
