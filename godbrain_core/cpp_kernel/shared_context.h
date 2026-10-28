#pragma once

#include "rag_client.h"
#include <sstream>

namespace godbrain_shared {
using json = nlohmann::json;

inline bool identity(const std::string& value, bool required = false) {
    if (value.empty()) return !required;
    for (const unsigned char ch : value)
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
              (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.' || ch == ':'))
            return false;
    return true;
}

inline std::string section(const std::string& name, const std::string& text,
                           const std::string& status, size_t budget) {
    if (text.empty()) return {};
    std::ostringstream raw;
    raw << godbrain_rag::kUntrustedBegin << '\n';
    godbrain_rag::append_line(raw, name + ".status", status);
    godbrain_rag::append_line(raw, name + ".content", text);
    raw << godbrain_rag::kUntrustedEnd << '\n';
    if (raw.fail()) throw std::runtime_error("Shared context contains invalid UTF-8");
    std::string out, error;
    if (!godbrain_rag::compose_prompt_context(raw.str(), "", "", out, error, budget))
        throw std::runtime_error(error);
    return out;
}

inline std::string bounded(const std::string& text, size_t budget) {
    if (text.empty()) return {};
    std::string out, error;
    if (!godbrain_rag::compose_prompt_context(text, "", "", out, error, budget))
        throw std::runtime_error(error);
    return out;
}

inline std::string merge(const std::string& first, const std::string& second,
                         size_t budget = godbrain_rag::kContextBytes) {
    std::string out, error;
    if (!godbrain_rag::compose_prompt_context(first, second, "", out, error, budget))
        throw std::runtime_error(error);
    return out;
}

inline std::string records(const json& rows, const std::string& shelf, size_t cap) {
    if (rows.empty()) return {};
    const auto render = [&](size_t count, size_t excerpt_bytes) {
        std::ostringstream text;
        for (size_t n = 0; n < count; ++n) {
            const auto& row = rows.at(shelf == "discussion" ? count - n - 1 : n);
            const std::string body = row.at("text").get<std::string>();
            text << "id=" << row.at("_id").get<std::string>()
                 << "; saved=" << row.at("created_at").get<std::string>()
                 << "; source_hash=" << row.at("source_hash").get<std::string>() << '\n';
            if (shelf != "discussion")
                text << "title_excerpt=" << godbrain_rag::utf8_prefix(row.at("title").get<std::string>(), 40)
                     << "; speaker_excerpt=" << godbrain_rag::utf8_prefix(row.at("speaker").get<std::string>(), 16) << '\n';
            text << godbrain_rag::utf8_prefix(body, excerpt_bytes);
            if (body.size() > excerpt_bytes) text << " [excerpt truncated]";
            json references = json::array();
            for (const auto& source : row.at("sources"))
                if (references.dump().size() + source.dump().size() + 1 <= 96)
                    references.push_back(source);
            text << "\nreferences=" << references.dump();
            if (references.size() != row.at("sources").size())
                text << "; references_omitted=" << row.at("sources").size() - references.size()
                     << " (full record: /api/shelf)";
            text << '\n';
        }
        if (count != rows.size())
            text << "records_omitted=" << rows.size() - count << " (budget)\n";
        return section(shelf, text.str(), "UNVERIFIED WORKING MATERIAL; not a Golden Record or permission", cap);
    };
    const auto clipped = [](const std::string& text) {
        return text.find("\ncontext_truncated=true\n") != std::string::npos;
    };
    size_t count = rows.size();
    while (count > 1 && clipped(render(count, 64))) --count;
    auto best = render(count, 0);
    size_t low = 1, high = 700;
    while (low <= high) {
        const auto middle = low + (high - low) / 2;
        auto candidate = render(count, middle);
        if (clipped(candidate)) high = middle - 1;
        else {
            best = std::move(candidate);
            low = middle + 1;
        }
    }
    return best;
}
}
