#pragma once

#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>
#include "json.hpp"

namespace godbrain_protected_read {

struct Handle {
    HANDLE value = INVALID_HANDLE_VALUE;
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    Handle() = default;
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
};

inline std::wstring wide(const std::string& text) {
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (!size) throw std::runtime_error("invalid UTF-8 path");
    std::wstring result(static_cast<size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        text.data(), static_cast<int>(text.size()), result.data(), size);
    return result;
}

inline std::string utf8(const std::wstring& text) {
    if (text.empty()) return "";
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
        text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (!size) throw std::runtime_error("invalid UTF-16 metadata");
    std::string result(static_cast<size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
        text.data(), static_cast<int>(text.size()), result.data(), size, nullptr, nullptr);
    return result;
}

class BackupReadToken {
    Handle source_, token_;
    bool active_ = false;
public:
    BackupReadToken() {
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE, &source_.value) ||
            !DuplicateTokenEx(source_.value, TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES | TOKEN_IMPERSONATE,
                nullptr, SecurityImpersonation, TokenImpersonation, &token_.value)) {
            throw std::runtime_error("cannot create isolated read token");
        }
        TOKEN_PRIVILEGES privileges{};
        privileges.PrivilegeCount = 1;
        if (!LookupPrivilegeValueW(nullptr, L"SeBackupPrivilege", &privileges.Privileges[0].Luid)) {
            throw std::runtime_error("cannot resolve backup-read privilege");
        }
        privileges.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
        SetLastError(ERROR_SUCCESS);
        if (!AdjustTokenPrivileges(token_.value, FALSE, &privileges, 0, nullptr, nullptr) ||
            GetLastError() != ERROR_SUCCESS) {
            throw std::runtime_error("backup-read privilege unavailable; administrator helper required");
        }
        if (!SetThreadToken(nullptr, token_.value)) throw std::runtime_error("cannot enter isolated read token");
        active_ = true;
    }
    ~BackupReadToken() {
        if (active_ && !RevertToSelf()) TerminateProcess(GetCurrentProcess(), ERROR_ACCESS_DENIED);
    }
};

inline nlohmann::json inspect(
    const std::string& input, const std::function<bool(const std::string&)>& allowed) {
    if (!allowed(input)) throw std::runtime_error("protected directory is outside the read allowlist");
    BackupReadToken token;
    Handle directory;
    directory.value = CreateFileW(wide(input).c_str(),
        FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | READ_CONTROL,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (directory.value == INVALID_HANDLE_VALUE) {
        throw std::runtime_error("backup directory open failed, Win32=" + std::to_string(GetLastError()));
    }
    std::vector<wchar_t> path(32768);
    const DWORD length = GetFinalPathNameByHandleW(directory.value, path.data(),
        static_cast<DWORD>(path.size()), FILE_NAME_NORMALIZED);
    if (!length || length >= path.size()) throw std::runtime_error("cannot resolve opened directory");
    std::wstring resolved(path.data(), length);
    if (resolved.rfind(L"\\\\?\\", 0) == 0) resolved.erase(0, 4);
    const auto resolved_utf8 = utf8(resolved);
    if (!allowed(resolved_utf8) ||
        CompareStringOrdinal(wide(input).c_str(), -1, resolved.c_str(), -1, TRUE) != CSTR_EQUAL) {
        throw std::runtime_error("resolved directory differs from the approved path; reparse traversal denied");
    }
    BY_HANDLE_FILE_INFORMATION info{};
    if (!GetFileInformationByHandle(directory.value, &info) ||
        !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
        throw std::runtime_error("protected inspection accepts directories only");
    }
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    const DWORD status = GetSecurityInfo(directory.value, SE_FILE_OBJECT,
        OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
        nullptr, nullptr, nullptr, nullptr, &descriptor);
    if (status != ERROR_SUCCESS) {
        throw std::runtime_error("directory ACL read failed, Win32=" + std::to_string(status));
    }
    struct Descriptor {
        PSECURITY_DESCRIPTOR value;
        ~Descriptor() { LocalFree(value); }
    } descriptor_guard{descriptor};
    LPWSTR sddl = nullptr;
    if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(descriptor, SDDL_REVISION_1,
            OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &sddl, nullptr)) throw std::runtime_error("cannot encode directory ACL");
    const std::wstring sddl_text(sddl);
    LocalFree(sddl);
    nlohmann::json result = {{"path", resolved_utf8}, {"sddl", utf8(sddl_text)},
        {"privilege", "isolated backup read"}, {"acl_changed", false},
        {"content_read", false}, {"recursive", false}, {"entries", nlohmann::json::array()},
        {"listing_complete", false}};
    std::vector<unsigned char> buffer(32768);
    while (result["entries"].size() < 80) {
        if (!GetFileInformationByHandleEx(directory.value, FileIdBothDirectoryInfo,
                buffer.data(), static_cast<DWORD>(buffer.size()))) {
            const auto error = GetLastError();
            if (error == ERROR_NO_MORE_FILES) { result["listing_complete"] = true; break; }
            throw std::runtime_error("directory enumeration failed, Win32=" + std::to_string(error));
        }
        DWORD offset = 0;
        do {
            const auto* entry = reinterpret_cast<const FILE_ID_BOTH_DIR_INFO*>(buffer.data() + offset);
            const std::wstring name(entry->FileName, entry->FileNameLength / sizeof(wchar_t));
            if (name != L"." && name != L"..") {
                result["entries"].push_back({{"name", utf8(name)},
                    {"directory", (entry->FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0},
                    {"reparse_point", (entry->FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0}});
                if (result["entries"].size() == 80) break;
            }
            if (!entry->NextEntryOffset) break;
            offset += entry->NextEntryOffset;
        } while (offset < buffer.size());
    }
    if (result.dump().size() > 24000) throw std::runtime_error("directory metadata exceeds the bounded read result");
    return result;
}
}
