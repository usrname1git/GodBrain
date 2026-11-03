#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#include "../cpp_kernel/json.hpp"
#include <algorithm>
#include <array>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <regex>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using json = nlohmann::json;

struct Handle {
    HANDLE value = INVALID_HANDLE_VALUE;
    explicit Handle(HANDLE handle) : value(handle) {}
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
};

static std::string read(const fs::path& file, size_t limit) {
    const DWORD attributes = GetFileAttributesW(file.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)))
        throw std::runtime_error("Missing or linked showcase input: " + file.filename().u8string());
    const auto size = fs::file_size(file);
    if (size > limit) throw std::runtime_error("Showcase input exceeds its size limit");
    std::ifstream stream(file, std::ios::binary);
    std::string bytes(static_cast<size_t>(size), '\0');
    if (!stream.read(bytes.data(), static_cast<std::streamsize>(bytes.size())))
        throw std::runtime_error("Could not read the complete showcase input");
    return bytes;
}

static std::string sha256(const std::string& bytes) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
        throw std::runtime_error("SHA-256 provider unavailable");
    std::array<unsigned char, 32> output{};
    const auto status = BCryptHash(algorithm, nullptr, 0,
        reinterpret_cast<PUCHAR>(const_cast<char*>(bytes.data())), static_cast<ULONG>(bytes.size()),
        output.data(), static_cast<ULONG>(output.size()));
    BCryptCloseAlgorithmProvider(algorithm, 0);
    if (status < 0) throw std::runtime_error("SHA-256 failed");
    static constexpr char hex[] = "0123456789abcdef";
    std::string result;
    for (const auto value : output) { result += hex[value >> 4]; result += hex[value & 15]; }
    return result;
}

static void write(const fs::path& file, const std::string& bytes) {
    fs::create_directories(file.parent_path());
    std::ofstream stream(file, std::ios::binary | std::ios::trunc);
    if (!stream.write(bytes.data(), static_cast<std::streamsize>(bytes.size())) || !stream.flush())
        throw std::runtime_error("Could not write showcase output");
}

static std::pair<unsigned, unsigned> png_size(const std::string& bytes) {
    const std::string signature("\x89PNG\r\n\x1a\n", 8);
    if (bytes.size() < 24 || bytes.compare(0, 8, signature) != 0 || bytes.compare(12, 4, "IHDR") != 0)
        throw std::runtime_error("Capture is not a PNG image");
    auto number = [&](size_t offset) {
        unsigned value = 0;
        for (size_t i = offset; i < offset + 4; ++i)
            value = (value << 8) | static_cast<unsigned char>(bytes[i]);
        return value;
    };
    const auto width = number(16), height = number(20);
    if (!width || !height || width > 4096 || height > 8192 ||
        static_cast<unsigned long long>(width) * height > 25000000)
        throw std::runtime_error("Capture dimensions exceed the bounded image profile");
    return {width, height};
}

static std::wstring quote(const fs::path& value) {
    if (value.native().find(L'"') != std::wstring::npos) throw std::runtime_error("Invalid encoder path");
    return L"\"" + value.native() + L"\"";
}

static void encode(const fs::path& executable, const fs::path& input,
                   const fs::path& output, const fs::path& log) {
    SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    Handle errors(CreateFileW(log.c_str(), GENERIC_WRITE, FILE_SHARE_READ, &security,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
    Handle empty(CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                             &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    Handle job(CreateJobObjectW(nullptr, nullptr));
    if (errors.value == INVALID_HANDLE_VALUE || empty.value == INVALID_HANDLE_VALUE || !job.value)
        throw std::runtime_error("Could not prepare the bounded CPU encoder");
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job.value, JobObjectExtendedLimitInformation, &limits, sizeof(limits)))
        throw std::runtime_error("Could not configure encoder cleanup");
    std::wstring command = quote(executable) + L" -nostdin -hide_banner -loglevel error -n -i " + quote(input) +
        L" -frames:v 1 -map_metadata -1 -an -c:v libwebp -lossless 1 -compression_level 6 -threads 1 " + quote(output);
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = empty.value; startup.hStdOutput = empty.value; startup.hStdError = errors.value;
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, nullptr, &startup, &process))
        throw std::runtime_error("Could not start the CPU image encoder");
    Handle child(process.hProcess), thread(process.hThread);
    if (!AssignProcessToJobObject(job.value, child.value)) {
        if (!TerminateProcess(child.value, 1) || WaitForSingleObject(child.value, 5000) != WAIT_OBJECT_0)
            throw std::runtime_error("Encoder job setup failed and exact-child cleanup did not complete");
        throw std::runtime_error("Could not bind encoder cleanup");
    }
    if (ResumeThread(thread.value) == static_cast<DWORD>(-1)) {
        if (!TerminateJobObject(job.value, 1) || WaitForSingleObject(child.value, 5000) != WAIT_OBJECT_0)
            throw std::runtime_error("Encoder resume failed and cleanup did not complete");
        throw std::runtime_error("Could not resume the CPU encoder");
    }
    if (WaitForSingleObject(child.value, 30000) != WAIT_OBJECT_0) {
        if (!TerminateJobObject(job.value, 1) || WaitForSingleObject(child.value, 5000) != WAIT_OBJECT_0)
            throw std::runtime_error("Encoder timed out and exact-job cleanup did not complete");
        throw std::runtime_error("CPU image encoding timed out");
    }
    DWORD exit = 1;
    if (!GetExitCodeProcess(child.value, &exit) || exit != 0)
        throw std::runtime_error("CPU image encoding failed; inspect the private encoding log");
}

static void require_text(const json& value, size_t maximum) {
    if (!value.is_string()) throw std::runtime_error("Invalid showcase text field");
    const auto text = value.get<std::string>();
    if (text.empty() || text.size() > maximum || std::any_of(text.begin(), text.end(),
        [](unsigned char c) { return c < 32; })) throw std::runtime_error("Invalid showcase text field");
}

static void fields(const json& value, std::initializer_list<const char*> names) {
    if (!value.is_object() || value.size() != names.size())
        throw std::runtime_error("Unknown or missing showcase field");
    for (const auto* name : names) if (!value.contains(name))
        throw std::runtime_error("Unknown or missing showcase field");
}

static void self_test() {
    if (sha256("abc") != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        throw std::runtime_error("SHA-256 self-test failed");
    std::string png("\x89PNG\r\n\x1a\n", 8);
    png += std::string("\0\0\0\rIHDR\0\0\2\x80\0\0\1\xe0", 16);
    if (png_size(png) != std::make_pair(640u, 480u)) throw std::runtime_error("PNG dimensions self-test failed");
    bool rejected = false;
    try { png_size("not a PNG"); } catch (const std::runtime_error&) { rejected = true; }
    if (!rejected) throw std::runtime_error("Invalid PNG was accepted");
}

int wmain(int argc, wchar_t** argv) {
    try {
        if (argc == 2 && std::wstring(argv[1]) == L"--self-test") {
            self_test(); std::cout << R"({"ok":true,"self_test":"passed"})" << '\n'; return 0;
        }
        if (argc != 6) throw std::runtime_error("Usage: showcase CAPTURES TEMPLATES OUTPUT_BATCH FFMPEG PROJECTS_JSON");
        const fs::path captures(argv[1]), templates(argv[2]), batch(argv[3]), ffmpeg(argv[4]), descriptor(argv[5]);
        if (fs::exists(batch)) throw std::runtime_error("Output batch must not already exist");
        auto catalog = json::parse(read(descriptor, 262144));
        fields(catalog, {"schema_version", "projects"});
        if (catalog.at("schema_version") != 1 || !catalog.at("projects").is_array() ||
            catalog["projects"].empty() || catalog["projects"].size() > 16)
            throw std::runtime_error("Invalid showcase catalog");
        const std::regex project_id("^[a-z][a-z0-9-]{0,47}$"), image_id("^[A-Z][A-Z0-9_]{0,47}$");
        std::vector<std::string> seen_projects, seen_images;
        const auto site = batch / L"site";
        fs::create_directories(site);
        for (auto& project : catalog["projects"]) {
            fields(project, {"id", "title", "description", "url", "source_url", "cover", "images"});
            require_text(project.at("id"), 48);
            const auto id = project["id"].get<std::string>();
            if (!std::regex_match(id, project_id) ||
                std::find(seen_projects.begin(), seen_projects.end(), id) != seen_projects.end())
                throw std::runtime_error("Invalid or duplicate project ID");
            seen_projects.push_back(id);
            for (const auto* key : {"title", "description", "url", "source_url"}) require_text(project.at(key), 600);
            if (!project.at("images").is_array() || project["images"].empty() || project["images"].size() > 16)
                throw std::runtime_error("Invalid showcase image list");
            bool cover_found = false;
            for (auto& image : project["images"]) {
                fields(image, {"id", "description", "capture_kind"});
                require_text(image.at("id"), 48);
                const auto name = image["id"].get<std::string>();
                if (seen_images.size() >= 128 || !std::regex_match(name, image_id) ||
                    std::find(seen_images.begin(), seen_images.end(), name) != seen_images.end())
                    throw std::runtime_error("Invalid or duplicate image ID");
                seen_images.push_back(name);
                require_text(image.at("description"), 400); require_text(image.at("capture_kind"), 80);
                const auto input = captures / fs::u8path(name + ".png");
                const auto size = png_size(read(input, 32 * 1024 * 1024));
                const std::string relative = "assets/" + id + "/" + name + ".webp";
                const auto output = site / fs::u8path(relative);
                fs::create_directories(output.parent_path());
                encode(ffmpeg, input, output, batch / L"encoding.log");
                const auto encoded = read(output, 5 * 1024 * 1024);
                image["path"] = relative; image["width"] = size.first; image["height"] = size.second;
                image["sha256"] = sha256(encoded);
                if (project.at("cover") == name) cover_found = true;
            }
            if (!cover_found) throw std::runtime_error("Project cover is missing");
        }
        write(site / L"catalog.json", catalog.dump(2) + "\n");
        for (const auto* name : {L"index.html", L"gallery.js", L"gallery.css"})
            write(site / name, read(templates / name, 262144));
        std::vector<fs::path> paths;
        for (const auto& entry : fs::recursive_directory_iterator(site)) if (entry.is_regular_file()) paths.push_back(entry.path());
        std::sort(paths.begin(), paths.end());
        json files = json::array();
        std::string binding;
        for (const auto& file : paths) {
            const auto relative = fs::relative(file, site).generic_u8string(), hash = sha256(read(file, 5 * 1024 * 1024));
            files.push_back({{"path", relative}, {"sha256", hash}});
            binding += relative + "\n" + hash + "\n";
        }
        const json receipt{{"schema_version", 1}, {"ok", true}, {"batch_sha256", sha256(binding)},
            {"operator_review_required", true}, {"files", files}};
        write(batch / L"review.json", receipt.dump(2) + "\n");
        std::cout << receipt.dump() << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << json{{"ok", false}, {"error", error.what()}}.dump() << '\n'; return 1;
    }
}
