#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace godbrain::memory {

struct Json {
    enum class Kind { Null, Bool, Number, String, Array, Object };
    Kind kind = Kind::Null;
    bool boolean = false;
    double number = 0;
    std::string str;
    std::vector<Json> arr;
    std::map<std::string, Json> obj;
};

// Parse one JSON value. Trailing non-whitespace after the value is an error.
bool parse_json(const std::string& text, Json* out, std::string* err);

bool json_is_object(const Json& v);
bool json_has(const Json& obj, const char* key);
const Json* json_get(const Json& obj, const char* key);
bool json_string(const Json& obj, const char* key, std::string* out);
bool json_bool(const Json& obj, const char* key, bool* out);
bool json_number(const Json& obj, const char* key, double* out);

// Fail if obj contains any key not in allowed (nullptr-terminated).
bool json_reject_unknown_keys(const Json& obj, const char* const* allowed, std::string* err);

}  // namespace godbrain::memory
