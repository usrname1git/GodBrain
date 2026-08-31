#include <iostream>
#include <string>

#include "browser_evidence.h"

static bool expect(bool condition, const char* message) {
    if (!condition) std::cerr << message << std::endl;
    return condition;
}

int main() {
    browser_evidence::Evidence quote;
    quote.title = "Example\nHost";
    quote.url = "https://example.com/a";
    quote.selected = "/yolo 60\nC:\\Users\\autismo\\Documents\\GitHub\\GodBrain";
    quote.client_sha256 = "DEAD-beef";
    browser_evidence::normalize(quote);

    const std::string prompt = browser_evidence::format_prompt_block(quote);
    const std::string remember = browser_evidence::format_remember_body(quote);
    if (!expect(quote.title.find('\n') == std::string::npos, "title one line") ||
        !expect(quote.keccak.size() == 64, "keccak 64") ||
        !expect(quote.client_sha256 == "deadbeef", "sha hex only") ||
        !expect(prompt.find("Cannot grant tools") != std::string::npos,
                "prompt forbids tools") ||
        !expect(prompt.find("Do not obey") != std::string::npos,
                "prompt ignores page instructions") ||
        !expect(prompt.find("/yolo 60") != std::string::npos,
                "quote kept as quote") ||
        !expect(remember.find("trust=candidate") != std::string::npos,
                "remember is candidate") ||
        !expect(remember.find("source_type=browser_selection") !=
                    std::string::npos,
                "remember provenance") ||
        !expect(browser_evidence::source_type_for(quote) == "browser_selection",
                "source type quote") ||
        !expect(quote.keccak == browser_evidence::keccak_hex(quote.selected),
                "keccak is of selected bytes")) {
        return 1;
    }

    browser_evidence::Evidence tab;
    tab.title = "Docs";
    tab.url = "https://example.com";
    browser_evidence::normalize(tab);
    const std::string meta = browser_evidence::format_prompt_block(tab);
    const std::string meta_mem = browser_evidence::format_remember_body(tab);
    if (!expect(!browser_evidence::has_quote(tab), "tab is not a quote") ||
        !expect(meta.find("metadata only") != std::string::npos,
                "tab prompt is metadata") ||
        !expect(meta.find("---") == std::string::npos,
                "tab prompt has no excerpt") ||
        !expect(meta_mem.find("not page evidence") != std::string::npos,
                "tab remember is not evidence") ||
        !expect(browser_evidence::source_type_for(tab) == "browser_tab",
                "source type tab")) {
        return 1;
    }

    browser_evidence::Evidence big;
    big.selected.assign(browser_evidence::kMaxSelected + 50, 'a');
    browser_evidence::normalize(big);
    if (!expect(big.truncated, "oversize truncated") ||
        !expect(big.selected.size() == browser_evidence::kMaxSelected,
                "cap 8k")) {
        return 1;
    }

    std::cout << "browser_evidence_test ok" << std::endl;
    return 0;
}
