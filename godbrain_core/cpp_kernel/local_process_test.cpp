#include "local_tools.cpp"

namespace memory {
json working_shelf(const json&) { throw std::runtime_error("Unexpected fixture shelf call"); }
json shared_context(const std::string&, const std::string&, const std::string&, const godbrain_rag::Client&) {
    throw std::runtime_error("Unexpected fixture context call");
}
json research_document(const std::string&, bool) { throw std::runtime_error("Unexpected fixture document call"); }
}

static void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
static std::string executable() {
    char path[MAX_PATH]{};
    check(GetModuleFileNameA(nullptr, path, MAX_PATH) != 0, "Missing fixture path");
    return path;
}
static void emit(DWORD stream, const std::string& value) {
    size_t position = 0;
    while (position < value.size()) {
        DWORD written = 0;
        check(WriteFile(GetStdHandle(stream), value.data() + position,
              static_cast<DWORD>(value.size() - position), &written, nullptr) && written, "Fixture write failed");
        position += written;
    }
}
int main(int argc, char** argv) {
    try {
        if (argc > 2 && std::string(argv[1]) == "--fixture") {
            const std::string mode = argv[2];
            if (mode == "args") {
                json arguments = json::array();
                for (int i = 3; i < argc; ++i) arguments.push_back(argv[i]);
                emit(STD_OUTPUT_HANDLE, arguments.dump());
            } else if (mode == "streams") {
                emit(STD_OUTPUT_HANDLE, "stdout-A");
                emit(STD_ERROR_HANDLE, "stderr-B");
                emit(STD_OUTPUT_HANDLE, "stdout-C");
            } else if (mode == "flood") {
                emit(STD_OUTPUT_HANDLE, std::string(200000, 'o'));
                emit(STD_ERROR_HANDLE, std::string(200000, 'e'));
            } else if (mode == "exit") {
                emit(STD_ERROR_HANDLE, "expected fixture failure");
                return 7;
            } else if (mode == "hold") {
                Sleep(5000);
            } else if (mode == "descendant" || mode == "timeout") {
                STARTUPINFOA startup{};
                startup.cb = sizeof(startup);
                startup.dwFlags = STARTF_USESTDHANDLES;
                startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
                startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
                startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
                auto command = godbrain_process::quoted(executable()) + " --fixture hold";
                PROCESS_INFORMATION process{};
                check(CreateProcessA(nullptr, command.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW,
                                     nullptr, nullptr, &startup, &process) != FALSE, "Descendant create failed");
                CloseHandle(process.hThread); CloseHandle(process.hProcess);
                emit(STD_OUTPUT_HANDLE, "owned descendant fixture");
                if (mode == "timeout") Sleep(5000);
            }
            return 0;
        }
        const auto run = [](const std::string& arguments, DWORD timeout = 2500) {
            return local_tools::run_process(executable(), "--fixture " + arguments, timeout);
        };
        const json expected = json::array({"argument with spaces", "embedded\"quote",
                                          "C:\\directory with spaces\\", "", ";&|<>literal"});
        std::string arguments = "args";
        for (const auto& value : expected) arguments += " " + godbrain_process::quoted(value.get<std::string>());
        const auto quoted = run(arguments);
        check(quoted.exit == 0 && !quoted.timeout && json::parse(quoted.text) == expected,
              "Raw Windows argument semantics changed");
        const auto streams = run("streams");
        check(streams.exit == 0 && streams.text == "stdout-Astderr-Bstdout-C", "Merged stream ordering changed");
        const auto flood = run("flood");
        check(flood.exit == 0 && flood.text.size() == 256 * 1024 + std::string("\n[truncated 256KiB]").size(),
              "Merged output was not bounded and drained");
        const auto failure = run("exit");
        check(failure.exit == 7 && !failure.timeout && failure.text == "expected fixture failure",
              "Native exit/stderr receipt changed");
        const auto begin = GetTickCount64();
        const auto descendant = run("descendant");
        check(descendant.exit == 0 && GetTickCount64() - begin < 1500,
              "Direct completion waited on descendant pipe handles");
        const auto timed = run("timeout", 100);
        check(timed.timeout && timed.exit != 0 && timed.text.find("owned descendant fixture") != std::string::npos &&
              timed.text.find("[timeout]") != std::string::npos, "Timeout lost its explicit receipt or captured output");
        const auto missing = local_tools::run_process("C:\\nonexistent-fixture\\never.exe", "", 100);
        check(missing.exit != 0 && !missing.timeout && missing.text.find("Error:") == 0,
              "Process creation failure claimed success");
        std::cout << "local_process_test ok: raw argv, merged order/cap, exit/errors, descendants and timeout output\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
