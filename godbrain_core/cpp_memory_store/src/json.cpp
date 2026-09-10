#include "godbrain/memory_store/json.hpp"

#include <cctype>
#include <cmath>
#include <cstdlib>
#include <sstream>
#include <utility>

namespace godbrain::memory {
namespace {

struct Parser {
    const std::string& t;
    std::size_t i = 0;
    std::string* err = nullptr;

    explicit Parser(const std::string& text, std::string* e) : t(text), err(e) {}

    void fail(const char* m) {
        if (err && err->empty()) *err = m;
    }

    void skip_ws() {
        while (i < t.size() && std::isspace(static_cast<unsigned char>(t[i])) != 0) ++i;
    }

    bool peek(char c) {
        skip_ws();
        return i < t.size() && t[i] == c;
    }

    bool take(char c) {
        skip_ws();
        if (i < t.size() && t[i] == c) {
            ++i;
            return true;
        }
        return false;
    }

    bool parse_value(Json* out);

    bool parse_string(std::string* out) {
        skip_ws();
        if (i >= t.size() || t[i] != '"') {
            fail("expected string");
            return false;
        }
        ++i;
        out->clear();
        while (i < t.size()) {
            unsigned char c = static_cast<unsigned char>(t[i]);
            if (c == '"') {
                ++i;
                return true;
            }
            if (c == '\\') {
                ++i;
                if (i >= t.size()) {
                    fail("unterminated string escape");
                    return false;
                }
                char e = t[i++];
                switch (e) {
                    case '"':
                    case '\\':
                    case '/':
                        out->push_back(e);
                        break;
                    case 'b':
                        out->push_back('\b');
                        break;
                    case 'f':
                        out->push_back('\f');
                        break;
                    case 'n':
                        out->push_back('\n');
                        break;
                    case 'r':
                        out->push_back('\r');
                        break;
                    case 't':
                        out->push_back('\t');
                        break;
                    case 'u': {
                        if (i + 4 > t.size()) {
                            fail("bad unicode escape");
                            return false;
                        }
                        unsigned cp = 0;
                        for (int n = 0; n < 4; ++n) {
                            char h = t[i++];
                            cp <<= 4;
                            if (h >= '0' && h <= '9') cp |= static_cast<unsigned>(h - '0');
                            else if (h >= 'a' && h <= 'f') cp |= static_cast<unsigned>(h - 'a' + 10);
                            else if (h >= 'A' && h <= 'F') cp |= static_cast<unsigned>(h - 'A' + 10);
                            else {
                                fail("bad unicode escape");
                                return false;
                            }
                        }
                        if (cp < 0x80) {
                            out->push_back(static_cast<char>(cp));
                        } else if (cp < 0x800) {
                            out->push_back(static_cast<char>(0xC0 | (cp >> 6)));
                            out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                        } else {
                            out->push_back(static_cast<char>(0xE0 | (cp >> 12)));
                            out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                            out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                        }
                        break;
                    }
                    default:
                        fail("bad string escape");
                        return false;
                }
                continue;
            }
            if (c < 0x20) {
                fail("unescaped control in string");
                return false;
            }
            out->push_back(static_cast<char>(c));
            ++i;
        }
        fail("unterminated string");
        return false;
    }

    bool parse_number(Json* out) {
        skip_ws();
        const std::size_t start = i;
        if (i < t.size() && t[i] == '-') ++i;
        if (i >= t.size() || std::isdigit(static_cast<unsigned char>(t[i])) == 0) {
            fail("expected number");
            return false;
        }
        if (t[i] == '0') {
            ++i;
        } else {
            while (i < t.size() && std::isdigit(static_cast<unsigned char>(t[i])) != 0) ++i;
        }
        if (i < t.size() && t[i] == '.') {
            ++i;
            if (i >= t.size() || std::isdigit(static_cast<unsigned char>(t[i])) == 0) {
                fail("expected number");
                return false;
            }
            while (i < t.size() && std::isdigit(static_cast<unsigned char>(t[i])) != 0) ++i;
        }
        if (i < t.size() && (t[i] == 'e' || t[i] == 'E')) {
            ++i;
            if (i < t.size() && (t[i] == '+' || t[i] == '-')) ++i;
            if (i >= t.size() || std::isdigit(static_cast<unsigned char>(t[i])) == 0) {
                fail("expected number");
                return false;
            }
            while (i < t.size() && std::isdigit(static_cast<unsigned char>(t[i])) != 0) ++i;
        }
        std::string slice = t.substr(start, i - start);
        char* end = nullptr;
        out->kind = Json::Kind::Number;
        out->number = std::strtod(slice.c_str(), &end);
        if (end == slice.c_str() || !std::isfinite(out->number)) {
            fail("expected number");
            return false;
        }
        return true;
    }

    bool parse_array(Json* out) {
        if (!take('[')) {
            fail("expected array");
            return false;
        }
        out->kind = Json::Kind::Array;
        skip_ws();
        if (take(']')) return true;
        for (;;) {
            Json item;
            if (!parse_value(&item)) return false;
            out->arr.push_back(std::move(item));
            skip_ws();
            if (take(']')) return true;
            if (!take(',')) {
                fail("expected comma in array");
                return false;
            }
        }
    }

    bool parse_object(Json* out) {
        if (!take('{')) {
            fail("expected object");
            return false;
        }
        out->kind = Json::Kind::Object;
        skip_ws();
        if (take('}')) return true;
        for (;;) {
            std::string key;
            if (!parse_string(&key)) return false;
            if (!take(':')) {
                fail("expected colon");
                return false;
            }
            Json val;
            if (!parse_value(&val)) return false;
            if (out->obj.find(key) != out->obj.end()) {
                fail("duplicate object key");
                return false;
            }
            out->obj.emplace(std::move(key), std::move(val));
            skip_ws();
            if (take('}')) return true;
            if (!take(',')) {
                fail("expected comma in object");
                return false;
            }
        }
    }
};

bool Parser::parse_value(Json* out) {
    skip_ws();
    if (i >= t.size()) {
        fail("unexpected end of json");
        return false;
    }
    if (t[i] == '{') return parse_object(out);
    if (t[i] == '[') return parse_array(out);
    if (t[i] == '"') {
        out->kind = Json::Kind::String;
        return parse_string(&out->str);
    }
    if (t[i] == '-' || std::isdigit(static_cast<unsigned char>(t[i])) != 0) {
        return parse_number(out);
    }
    if (t.compare(i, 4, "true") == 0) {
        i += 4;
        out->kind = Json::Kind::Bool;
        out->boolean = true;
        return true;
    }
    if (t.compare(i, 5, "false") == 0) {
        i += 5;
        out->kind = Json::Kind::Bool;
        out->boolean = false;
        return true;
    }
    if (t.compare(i, 4, "null") == 0) {
        i += 4;
        out->kind = Json::Kind::Null;
        return true;
    }
    fail("unexpected token");
    return false;
}

}  // namespace

bool parse_json(const std::string& text, Json* out, std::string* err) {
    if (out == nullptr) return false;
    *out = Json{};
    Parser p(text, err);
    if (!p.parse_value(out)) return false;
    p.skip_ws();
    if (p.i != text.size()) {
        if (err && err->empty()) *err = "trailing data after JSON";
        return false;
    }
    return true;
}

bool json_is_object(const Json& v) { return v.kind == Json::Kind::Object; }

bool json_has(const Json& obj, const char* key) {
    return obj.kind == Json::Kind::Object && obj.obj.find(key) != obj.obj.end();
}

const Json* json_get(const Json& obj, const char* key) {
    if (obj.kind != Json::Kind::Object) return nullptr;
    auto it = obj.obj.find(key);
    if (it == obj.obj.end()) return nullptr;
    return &it->second;
}

bool json_string(const Json& obj, const char* key, std::string* out) {
    const Json* v = json_get(obj, key);
    if (v == nullptr || v->kind != Json::Kind::String) return false;
    *out = v->str;
    return true;
}

bool json_bool(const Json& obj, const char* key, bool* out) {
    const Json* v = json_get(obj, key);
    if (v == nullptr || v->kind != Json::Kind::Bool) return false;
    *out = v->boolean;
    return true;
}

bool json_number(const Json& obj, const char* key, double* out) {
    const Json* v = json_get(obj, key);
    if (v == nullptr || v->kind != Json::Kind::Number) return false;
    *out = v->number;
    return true;
}

bool json_reject_unknown_keys(const Json& obj, const char* const* allowed, std::string* err) {
    if (obj.kind != Json::Kind::Object) {
        if (err) *err = "expected object";
        return false;
    }
    for (const auto& kv : obj.obj) {
        bool ok = false;
        for (const char* const* a = allowed; *a != nullptr; ++a) {
            if (kv.first == *a) {
                ok = true;
                break;
            }
        }
        if (!ok) {
            if (err) *err = "unknown field: " + kv.first;
            return false;
        }
    }
    return true;
}

}  // namespace godbrain::memory
