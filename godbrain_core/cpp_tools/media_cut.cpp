#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#include "../cpp_kernel/json.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

using json = nlohmann::json;
namespace fs = std::filesystem;
struct Handle {
    HANDLE value = nullptr;
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
};
static void win(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(std::string(message) + " (Windows " + std::to_string(GetLastError()) + ")");
}
static std::string utf8(const std::wstring& value) {
    const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    win(count > 0 || value.empty(), "UTF-8 conversion");
    std::string result(static_cast<size_t>(count), '\0');
    if (count) win(WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), result.data(), count, nullptr, nullptr) == count, "UTF-8 conversion");
    return result;
}
static std::wstring wide(const std::string& value) {
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), nullptr, 0);
    win(count > 0 || value.empty(), "Unicode conversion");
    std::wstring result(static_cast<size_t>(count), L'\0');
    if (count) win(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), result.data(), count) == count, "Unicode conversion");
    return result;
}
static std::wstring quote(const std::wstring& value) {
    std::wstring result = L"\"";
    size_t slashes = 0;
    for (wchar_t c : value) {
        if (c == L'\\') { ++slashes; continue; }
        result.append(slashes * (c == L'"' ? 2 : 1), L'\\');
        slashes = 0;
        if (c == L'"') result += L'\\';
        result += c;
    }
    result.append(slashes * 2, L'\\');
    return result + L'"';
}
static std::string run(const fs::path& executable, const std::vector<std::wstring>& args, DWORD timeout) {
    std::wstring command = quote(executable.wstring());
    for (const auto& arg : args) command += L" " + quote(arg);
    if (command.size() >= 32767) throw std::runtime_error("Native command line exceeds Windows limit");
    SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
    Handle read, write, input, job;
    win(CreatePipe(&read.value, &write.value, &security, 0) != FALSE, "Create output pipe");
    win(SetHandleInformation(read.value, HANDLE_FLAG_INHERIT, 0) != FALSE, "Protect parent pipe");
    input.value = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
        &security, OPEN_EXISTING, 0, nullptr);
    win(input.value != INVALID_HANDLE_VALUE, "Null stdin");
    job.value = CreateJobObjectW(nullptr, nullptr);
    win(job.value != nullptr, "Create child job");
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_JOB_MEMORY;
    limits.JobMemoryLimit = static_cast<SIZE_T>(2ULL * 1024 * 1024 * 1024);
    win(SetInformationJobObject(job.value, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) != FALSE, "Child job limits");
    SIZE_T attributeBytes = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &attributeBytes);
    win(attributeBytes != 0, "Size media handle list");
    std::vector<BYTE> attributeStorage(attributeBytes);
    auto* attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributeStorage.data());
    win(InitializeProcThreadAttributeList(attributes, 1, 0, &attributeBytes) != FALSE, "Initialize media handle list");
    struct Attributes {
        LPPROC_THREAD_ATTRIBUTE_LIST value;
        ~Attributes() { DeleteProcThreadAttributeList(value); }
    } attributeGuard{attributes};
    HANDLE inherited[] = {input.value, write.value};
    win(UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
        inherited, sizeof(inherited), nullptr, nullptr) != FALSE, "Restrict media handle inheritance");
    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = input.value;
    startup.StartupInfo.hStdOutput = startup.StartupInfo.hStdError = write.value;
    startup.lpAttributeList = attributes;
    PROCESS_INFORMATION info{};
    win(CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT,
        nullptr, nullptr, &startup.StartupInfo, &info) != FALSE, "Create media child");
    Handle process{info.hProcess}, thread{info.hThread};
    if (!AssignProcessToJobObject(job.value, process.value)) {
        TerminateProcess(process.value, 1);
        WaitForSingleObject(process.value, 5000);
        throw std::runtime_error("Could not contain the media child; it was terminated");
    }
    struct Reap {
        HANDLE process, job;
        ~Reap() {
            if (WaitForSingleObject(process, 0) == WAIT_TIMEOUT) {
                TerminateJobObject(job, 1);
                TerminateProcess(process, 1);
                WaitForSingleObject(process, 5000);
            }
        }
    } reap{process.value, job.value};
    win(ResumeThread(thread.value) != static_cast<DWORD>(-1), "Resume media child");
    CloseHandle(write.value); write.value = nullptr;
    std::string output;
    const ULONGLONG deadline = GetTickCount64() + timeout;
    std::array<char, 8192> bytes{};
    for (;;) {
        if (GetTickCount64() >= deadline) throw std::runtime_error("Media child timed out");
        DWORD available = 0;
        if (!PeekNamedPipe(read.value, nullptr, 0, nullptr, &available, nullptr)) {
            win(GetLastError() == ERROR_BROKEN_PIPE, "Read media pipe");
            break;
        }
        if (available) {
            DWORD received = 0;
            win(ReadFile(read.value, bytes.data(), std::min<DWORD>(available, static_cast<DWORD>(bytes.size())), &received, nullptr) != FALSE, "Read media output");
            output.append(bytes.data(), received);
            if (output.size() > 2 * 1024 * 1024) throw std::runtime_error("Media child output exceeded 2 MiB");
        } else if (WaitForSingleObject(process.value, 0) == WAIT_OBJECT_0) break;
        else Sleep(10);
    }
    win(WaitForSingleObject(process.value, 5000) == WAIT_OBJECT_0, "Reap media child");
    DWORD code = 0;
    win(GetExitCodeProcess(process.value, &code) != FALSE, "Read media exit code");
    if (code) throw std::runtime_error("Media child failed (" + std::to_string(code) + "): " + output.substr(0, 3000));
    return output;
}
static std::string sha256(HANDLE file) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
        throw std::runtime_error("SHA-256 unavailable");
    try {
        if (BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) < 0)
            throw std::runtime_error("SHA-256 initialization failed");
        std::array<BYTE, 65536> buffer{};
        for (;;) {
            DWORD count = 0;
            win(ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr) != FALSE, "Hash source");
            if (!count) break;
            if (BCryptHashData(hash, buffer.data(), count, 0) < 0) throw std::runtime_error("Source hashing failed");
        }
        BYTE digest[32]{};
        if (BCryptFinishHash(hash, digest, sizeof(digest), 0) < 0) throw std::runtime_error("Source hash finish failed");
        BCryptDestroyHash(hash); hash = nullptr;
        BCryptCloseAlgorithmProvider(algorithm, 0); algorithm = nullptr;
        std::string result;
        for (BYTE value : digest) {
            result += "0123456789abcdef"[value >> 4];
            result += "0123456789abcdef"[value & 15];
        }
        return result;
    } catch (...) {
        if (hash) BCryptDestroyHash(hash);
        if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
        throw;
    }
}
struct Temporary {
    fs::path path;
    Temporary(const fs::path& folder, const std::wstring& extension) {
        BYTE random[16]{};
        if (BCryptGenRandom(nullptr, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0)
            throw std::runtime_error("Temporary name entropy unavailable");
        std::wstring name = L".godbrain-media-";
        for (BYTE value : random) {
            name += L"0123456789abcdef"[value >> 4];
            name += L"0123456789abcdef"[value & 15];
        }
        path = folder / (name + extension);
        Handle file{CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr)};
        win(file.value != INVALID_HANDLE_VALUE, "Reserve exclusive media temporary");
    }
    ~Temporary() { if (!path.empty()) DeleteFileW(path.c_str()); }
};
static double number(const std::string& value) {
    size_t count = 0;
    const double result = std::stod(value, &count);
    if (count != value.size() || !std::isfinite(result)) throw std::runtime_error("Invalid finite number");
    return result;
}
static std::string decimal(double value) {
    std::ostringstream output;
    output.imbue(std::locale::classic());
    output << std::fixed << std::setprecision(9) << value;
    return output.str();
}
struct Range { double start, end; };
static std::vector<Range> detected(const std::string& metadata, double duration, bool requireScan = false) {
    std::vector<double> starts, ends;
    double scanned = 0;
    double timebase = 0;
    bool completed = false;
    const std::regex packet(R"(^\s*0,\s*(-?[0-9]+),\s*(-?[0-9]+),\s*([0-9]+),\s*([0-9]+),\s*[a-fA-F0-9]{64}\s*$)");
    std::istringstream lines(metadata);
    std::string line;
    while (std::getline(lines, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line.rfind("frame:", 0) == 0) continue;
        if (line.rfind("#tb 0:", 0) == 0) {
            const auto slash = line.find('/');
            if (slash == std::string::npos) throw std::runtime_error("Missing decoded PCM timebase");
            timebase = number(line.substr(6, slash - 6)) / number(line.substr(slash + 1));
            if (!std::isfinite(timebase) || timebase <= 0) throw std::runtime_error("Invalid decoded PCM timebase");
        } else if (line[0] == '#') continue;
        else if (std::smatch match; std::regex_match(line, match, packet)) {
            if (timebase <= 0 || number(match[2]) < 0 || number(match[3]) <= 0 || number(match[4]) <= 0)
                throw std::runtime_error("Invalid decoded PCM packet");
            scanned = std::max(scanned, (number(match[2]) + number(match[3])) * timebase);
        } else if (line.rfind("lavfi.silence_start=", 0) == 0) starts.push_back(number(line.substr(20)));
        else if (line.rfind("lavfi.silence_end=", 0) == 0) ends.push_back(number(line.substr(18)));
        else if (line.rfind("progress=", 0) == 0) completed = line.substr(9) == "end" || completed;
        else if (line.rfind("frame=", 0) == 0 || line.rfind("fps=", 0) == 0 ||
            line.rfind("stream_", 0) == 0 || line.rfind("bitrate=", 0) == 0 ||
            line.rfind("total_size=", 0) == 0 || line.rfind("out_time_", 0) == 0 ||
            line.rfind("out_time=", 0) == 0 ||
            line.rfind("dup_frames=", 0) == 0 || line.rfind("drop_frames=", 0) == 0 ||
            line.rfind("speed=", 0) == 0) continue;
        else throw std::runtime_error("Unexpected silence sensor output: " + line.substr(0, 120));
    }
    if (requireScan && (!completed || scanned < duration - 0.1 || scanned <= 0))
        throw std::runtime_error("Silence scan did not prove complete audio decoding");
    std::sort(starts.begin(), starts.end());
    std::sort(ends.begin(), ends.end());
    if (starts.size() > 512 || ends.size() > starts.size()) throw std::runtime_error("Too many or inconsistent silence intervals; increase minimum gap");
    std::vector<Range> result;
    size_t cursor = 0;
    for (double begin : starts) {
        if (begin < -0.1 || begin > duration + 0.1) throw std::runtime_error("Silence starts outside source");
        const double end = cursor < ends.size() ? ends[cursor++] : duration;
        if (end < begin || end > duration + 0.1) throw std::runtime_error("Invalid silence interval");
        result.push_back({std::max(0.0, begin), std::min(duration, end)});
    }
    return result;
}
static std::vector<Range> retained(const std::vector<Range>& silence, double duration, double padding) {
    std::vector<Range> result;
    double cursor = 0;
    for (const auto& gap : silence) {
        const double begin = gap.start <= 0.0001 ? 0 : std::min(duration, gap.start + padding);
        const double end = gap.end >= duration - 0.0001 ? duration : std::max(begin, gap.end - padding);
        if (begin < cursor || end < begin) throw std::runtime_error("Overlapping silence intervals");
        if (begin > cursor + 0.0001) result.push_back({cursor, begin});
        cursor = end;
    }
    if (cursor < duration - 0.0001) result.push_back({cursor, duration});
    return result;
}
static std::string graph(const std::vector<Range>& ranges, bool video) {
    const std::string count = std::to_string(ranges.size());
    std::string result;
    if (video) {
        result += "[0:v:0]split=" + count;
        for (size_t i = 0; i < ranges.size(); ++i) result += "[v" + std::to_string(i) + "]";
        result += ";";
    }
    result += "[0:a:0]aresample=async=1:first_pts=0,asplit=" + count;
    for (size_t i = 0; i < ranges.size(); ++i) result += "[a" + std::to_string(i) + "]";
    result += ";";
    for (size_t i = 0; i < ranges.size(); ++i) {
        const auto index = std::to_string(i);
        const auto start = decimal(ranges[i].start), end = decimal(ranges[i].end);
        if (video) result += "[v" + index + "]trim=start=" + start + ":end=" + end +
            ",setpts=PTS-" + start + "/TB[vo" + index + "];";
        result += "[a" + index + "]atrim=start=" + start + ":end=" + end +
            ",asetpts=PTS-" + start + "/TB[ao" + index + "];";
    }
    for (size_t i = 0; i < ranges.size(); ++i) {
        if (video) result += "[vo" + std::to_string(i) + "]";
        result += "[ao" + std::to_string(i) + "]";
    }
    result += "concat=n=" + count + ":v=" + (video ? "1" : "0") + ":a=1";
    return result + (video ? "[video][audio]" : "[audio]");
}
struct Media { double duration = 0, fps = 30; bool video = false; };
static Media probe(const fs::path& tool, const fs::path& input) {
    const json data = json::parse(run(tool, {L"-v", L"error", L"-show_entries",
        L"format=duration:stream=codec_type,avg_frame_rate,color_transfer", L"-of", L"json", input.wstring()}, 30000));
    Media result;
    result.duration = number(data.at("format").at("duration").get<std::string>());
    if (result.duration <= 0 || result.duration > 86400) throw std::runtime_error("Source duration must be positive and at most 24 hours");
    size_t audio = 0, video = 0;
    for (const auto& stream : data.at("streams")) {
        const auto type = stream.at("codec_type").get<std::string>();
        if (type == "audio") ++audio;
        else if (type == "video") {
            ++video;
            const auto color = stream.value("color_transfer", "");
            if (color == "smpte2084" || color == "arib-std-b67")
                throw std::runtime_error("HDR input needs an explicit HDR encoding profile; no SDR conversion performed");
            const auto rate = stream.value("avg_frame_rate", "0/0");
            const auto slash = rate.find('/');
            if (slash != std::string::npos && number(rate.substr(slash + 1)) > 0)
                result.fps = number(rate.substr(0, slash)) / number(rate.substr(slash + 1));
        } else throw std::runtime_error("Subtitle/data streams need explicit timeline handling; source left untouched");
    }
    if (audio != 1 || video > 1) throw std::runtime_error("Select a source with one audio stream and at most one video stream");
    if (result.fps <= 0 || result.fps > 1000) throw std::runtime_error("Unsupported video frame rate");
    result.video = video == 1;
    return result;
}
static void write(const fs::path& path, const std::string& value) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) throw std::runtime_error("Cannot write owned media temporary");
    file.write(value.data(), static_cast<std::streamsize>(value.size()));
    file.close();
    if (!file) throw std::runtime_error("Media temporary write failed");
}
int wmain(int argc, wchar_t** argv) {
    std::string phase = "arguments";
    try {
        if (argc == 2 && wcscmp(argv[1], L"--deadline-fixture") == 0) { Sleep(5000); return 0; }
        if (argc == 3 && wcscmp(argv[1], L"--inherited-handle-fixture") == 0) {
            SetEvent(reinterpret_cast<HANDLE>(static_cast<uintptr_t>(std::stoull(argv[2]))));
            return 0;
        }
        if (argc == 2 && wcscmp(argv[1], L"--self-test") == 0) {
            const auto gaps = detected("frame:2\nlavfi.silence_end=2\nframe:1\nlavfi.silence_start=1\n", 3);
            const auto keep = retained(gaps, 3, 0.1);
            const auto trailing = retained(detected("lavfi.silence_start=1\n", 3), 3, 0);
            if (keep.size() != 2 || std::abs(keep[0].end - 1.1) > 0.0001 ||
                trailing.size() != 1 || !retained({{0, 3}}, 3, 0.1).empty())
                throw std::runtime_error("Interval regression");
            std::vector<wchar_t> image(32768);
            const DWORD count = GetModuleFileNameW(nullptr, image.data(), static_cast<DWORD>(image.size()));
            win(count && count < image.size(), "Locate media fixture");
            const fs::path executable(std::wstring(image.data(), count));
            SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
            Handle event{CreateEventW(&security, TRUE, FALSE, nullptr)};
            win(event.value != nullptr, "Create inheritance fixture");
            run(executable, {L"--inherited-handle-fixture",
                std::to_wstring(reinterpret_cast<uintptr_t>(event.value))}, 10000);
            if (WaitForSingleObject(event.value, 0) != WAIT_TIMEOUT)
                throw std::runtime_error("Unlisted inheritable handle reached media child");
            const ULONGLONG started = GetTickCount64();
            bool timedOut = false;
            try { run(executable, {L"--deadline-fixture"}, 100); }
            catch (const std::runtime_error& error) {
                if (std::string(error.what()) != "Media child timed out") throw;
                timedOut = true;
            }
            if (!timedOut || GetTickCount64() - started > 3000)
                throw std::runtime_error("Media child deadline/cleanup regression");
            std::cout << R"({"status":"pass","checks":["buffered sensor order","padding","trailing silence","all silence","handle isolation","deadline and exact-child cleanup"]})" << '\n';
            return 0;
        }
        fs::path input, output, ffmpeg = L"C:\\Tools\\ffmpeg\\ffmpeg.exe", ffprobe = L"C:\\Tools\\ffmpeg\\ffprobe.exe";
        double noise = -40, minimum = 0.5, padding = 0.1;
        bool plan = false;
        for (int i = 1; i < argc; ++i) {
            const std::wstring name = argv[i];
            if (name == L"--plan") { plan = true; continue; }
            if (++i >= argc) throw std::runtime_error("Missing option value");
            const std::wstring value = argv[i];
            if (name == L"--input") input = value;
            else if (name == L"--output") output = value;
            else if (name == L"--ffmpeg") ffmpeg = value;
            else if (name == L"--ffprobe") ffprobe = value;
            else if (name == L"--noise-db") noise = number(utf8(value));
            else if (name == L"--min-gap") minimum = number(utf8(value));
            else if (name == L"--padding") padding = number(utf8(value));
            else throw std::runtime_error("Unknown media option");
        }
        if (input.empty() || noise < -90 || noise > -10 || minimum < 0.05 || minimum > 30 || padding < 0 || padding > 1)
            throw std::runtime_error("Input required; noise -90..-10 dB, minimum gap .05..30s, padding 0..1s");
        input = fs::absolute(input).lexically_normal();
        Handle source{CreateFileW(input.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr)};
        win(source.value != INVALID_HANDLE_VALUE, "Pin read-only source");
        phase = "probe";
        const Media media = probe(ffprobe, input);
        if (output.empty()) output = input.parent_path() / (input.stem().wstring() + L".no-silence" + (media.video ? L".mp4" : L".wav"));
        output = fs::absolute(output).lexically_normal();
        const fs::path receiptPath = output.wstring() + L".cut.json";
        if (_wcsicmp(input.c_str(), output.c_str()) == 0 || (!plan && (fs::exists(output) || fs::exists(receiptPath))))
            throw std::runtime_error("Output/receipt already exists or would overwrite the source");
        if (_wcsicmp(output.extension().c_str(), media.video ? L".mp4" : L".wav") != 0)
            throw std::runtime_error("Derived output must be MP4 for video or WAV for audio");
        const std::string hash = sha256(source.value);
        phase = "detect";
        // Clear source-supplied sensor keys before collecting only the detector's own values.
        const std::string filter = "aresample=48000:async=1:first_pts=0,apad=whole_dur=" + decimal(media.duration) +
            ",ametadata=mode=delete:key=lavfi.silence_start,"
            "ametadata=mode=delete:key=lavfi.silence_end,"
            "silencedetect=noise=" + decimal(noise) + "dB:duration=" + decimal(minimum) +
            ",ametadata=mode=print:key=lavfi.silence_start:file=-,"
            "ametadata=mode=print:key=lavfi.silence_end:file=-,asetnsamples=n=480000:p=0";
        const auto silence = detected(run(ffmpeg, {L"-hide_banner", L"-nostdin", L"-v", L"error",
            L"-progress", L"pipe:1", L"-stats_period", L"3600",
            L"-copyts", L"-start_at_zero", L"-i", input.wstring(), L"-map", L"0:a:0", L"-af", wide(filter),
            L"-map_metadata", L"-1", L"-c:a", L"pcm_s16le", L"-f", L"framehash", L"pipe:1"}, 600000), media.duration, true);
        const auto keep = retained(silence, media.duration, padding);
        if (keep.empty()) throw std::runtime_error("Source is entirely silent; no playable derivative created");
        double expected = 0;
        json intervals = json::array();
        for (const auto& item : keep) { expected += item.end - item.start; intervals.push_back({{"start", item.start}, {"end", item.end}}); }
        json receipt{{"schema_version", "media-cut-v1"}, {"trust", "untrusted"}, {"source_sha256", hash},
            {"input", utf8(input.wstring())}, {"source_seconds", media.duration}, {"expected_seconds", expected},
            {"noise_db", noise}, {"minimum_gap_seconds", minimum}, {"padding_seconds", padding}, {"keep", intervals}};
        if (silence.empty() || media.duration - expected < 0.0001) {
            receipt["status"] = "unchanged";
            receipt["message"] = "No qualifying silent gaps; original untouched, no derivative created";
            std::cout << receipt.dump() << '\n';
            return 0;
        }
        if (plan) { receipt["status"] = "planned"; std::cout << receipt.dump() << '\n'; return 0; }
        if (!fs::is_directory(output.parent_path())) throw std::runtime_error("Output parent directory does not exist");
        Handle parent{CreateFileW(output.parent_path().c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr)};
        win(parent.value != INVALID_HANDLE_VALUE, "Pin output directory");
        Temporary specification(output.parent_path(), L".filter");
        Temporary encoded(output.parent_path(), output.extension().wstring());
        Temporary record(output.parent_path(), L".json");
        write(specification.path, graph(keep, media.video));
        phase = "encode";
        std::vector<std::wstring> args{L"-hide_banner", L"-nostdin", L"-v", L"error", L"-y", L"-copyts",
            L"-start_at_zero", L"-i", input.wstring(), L"-filter_complex_threads", L"2",
            L"-/filter_complex", specification.path.wstring()};
        if (media.video) {
            args.insert(args.end(), {L"-map", L"[video]", L"-map", L"[audio]", L"-c:v", L"libx264",
                L"-crf", L"18", L"-preset", L"medium", L"-threads", L"4", L"-fps_mode", L"vfr",
                L"-c:a", L"aac", L"-b:a", L"192k", L"-movflags", L"+faststart"});
        } else args.insert(args.end(), {L"-map", L"[audio]", L"-c:a", L"pcm_s24le"});
        args.push_back(encoded.path.wstring());
        const auto errors = run(ffmpeg, args, 3600000);
        if (!errors.empty()) throw std::runtime_error("Encoder emitted errors: " + errors.substr(0, 3000));
        phase = "verify";
        const Media actual = probe(ffprobe, encoded.path);
        const double tolerance = 0.05 + (media.video ? static_cast<double>(keep.size()) / media.fps : 0);
        if (actual.video != media.video || std::abs(actual.duration - expected) > tolerance)
            throw std::runtime_error("Encoded stream/duration verification failed; original untouched");
        receipt["status"] = "created";
        receipt["output"] = utf8(output.wstring());
        receipt["output_seconds"] = actual.duration;
        receipt["video_frame_bound_seconds"] = media.video ? 1 / media.fps : 0;
        write(record.path, receipt.dump(2) + "\n");
        win(MoveFileExW(encoded.path.c_str(), output.c_str(), MOVEFILE_WRITE_THROUGH) != FALSE, "Commit new derivative without overwrite");
        encoded.path.clear();
        if (!MoveFileExW(record.path.c_str(), receiptPath.c_str(), MOVEFILE_WRITE_THROUGH))
            throw std::runtime_error("Derivative created but receipt commit failed; do not rerun over the existing output");
        record.path.clear();
        std::cout << receipt.dump() << '\n';
        return 0;
    } catch (const std::exception& e) {
        std::cerr << json({{"status", "failed"}, {"phase", phase}, {"error", e.what()}}).dump(-1, ' ', false, json::error_handler_t::replace) << '\n';
        return 1;
    }
}
