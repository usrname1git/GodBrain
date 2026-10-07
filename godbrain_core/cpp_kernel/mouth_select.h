#pragma once

// Which loopback mouth a consumer may use. Probes are supplied by the caller
// so a test can fake them. This function does not open a socket or start a process.
namespace mouth_select {

enum class Kind { None, Exl3, Llama };

struct Probes {
    bool paused = false;
    bool exl3_up = false;
    bool exl3_busy = false;
    bool llama_up = false;
    bool llama_busy = false;
    // :8888 is already listening. Do not start llama beside it.
    bool slot_held = false;
};

struct Choice {
    Kind kind = Kind::None;
    int port = 0;
    bool busy = false;
    bool start_runner = false;
};

inline Choice select(const Probes& in) {
    Choice out;
    if (in.paused) {
        if (!in.exl3_up) return out;
        out.kind = Kind::Exl3;
        out.port = 8888;
        out.busy = in.exl3_busy;
        return out;
    }
    if (in.llama_up) {
        out.kind = Kind::Llama;
        out.port = 8000;
        out.busy = in.llama_busy;
        return out;
    }
    if (in.slot_held || in.exl3_up) return out;
    out.start_runner = true;
    return out;
}

}  // namespace mouth_select
