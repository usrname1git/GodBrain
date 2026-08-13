#include "godbrain/polygon_observer.hpp"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <limits>
#include <random>
#include <sstream>
#include <tuple>
#include <utility>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#endif

namespace godbrain::polygon::observer {
namespace {

constexpr std::size_t maximum_record_bytes = 256 * 1024;

bool is_lower_hex(std::string_view value) {
    return std::all_of(value.begin(), value.end(), [](unsigned char character) {
        return std::isdigit(character) != 0 ||
            (character >= static_cast<unsigned char>('a') &&
             character <= static_cast<unsigned char>('f'));
    });
}

std::string require_address(const Json& value, std::string_view field) {
    if (!value.is_string()) {
        throw ObserverError(std::string(field) + " must be a string");
    }
    const std::string address = value.get<std::string>();
    if (address.size() != 42 || address.substr(0, 2) != "0x" ||
        !is_lower_hex(std::string_view(address).substr(2))) {
        throw ObserverError(std::string(field) + " must be a canonical lowercase address");
    }
    return address;
}

std::string require_hash(const Json& value, std::string_view field) {
    if (!value.is_string()) {
        throw ObserverError(std::string(field) + " must be a string");
    }
    const std::string hash = value.get<std::string>();
    if (hash.size() != 66 || hash.substr(0, 2) != "0x" ||
        !is_lower_hex(std::string_view(hash).substr(2))) {
        throw ObserverError(std::string(field) + " must be a canonical lowercase hash");
    }
    return hash;
}

std::uint64_t require_uint64(const Json& value, std::string_view field) {
    if (!value.is_number_integer()) {
        throw ObserverError(std::string(field) + " must be an integer");
    }
    if (value.is_number_unsigned()) {
        return value.get<std::uint64_t>();
    }
    const auto parsed = value.get<std::int64_t>();
    if (parsed < 0) {
        throw ObserverError(std::string(field) + " must not be negative");
    }
    return static_cast<std::uint64_t>(parsed);
}

std::string require_label(const Json& value, std::string_view field) {
    if (!value.is_string()) {
        throw ObserverError(std::string(field) + " must be a string");
    }
    const std::string label = value.get<std::string>();
    if (label.empty() || label.size() > 80 ||
        !std::all_of(label.begin(), label.end(), [](unsigned char character) {
            return character >= 0x20 && character <= 0x7e;
        })) {
        throw ObserverError(std::string(field) + " is invalid");
    }
    return label;
}

std::string require_source_url(const Json& value) {
    if (!value.is_string()) {
        throw ObserverError("allowlist source_url must be a string");
    }
    const std::string source = value.get<std::string>();
    if (!source.starts_with("https://") || source.size() > 2'048 ||
        source.find_first_of(" @#\\") != std::string::npos) {
        throw ObserverError("allowlist source_url must be an explicit HTTPS URL");
    }
    return source;
}

std::string require_sha256(const Json& value, std::string_view field) {
    if (!value.is_string()) {
        throw ObserverError(std::string(field) + " must be a string");
    }
    const std::string digest = value.get<std::string>();
    if (digest.size() != 64 || !is_lower_hex(digest)) {
        throw ObserverError(std::string(field) + " must be a lowercase SHA-256 digest");
    }
    return digest;
}

void require_exact_keys(const Json& value, const std::set<std::string>& keys) {
    if (!value.is_object() || value.size() != keys.size()) {
        throw ObserverError("JSON object has missing or unknown keys");
    }
    for (const auto& [key, unused] : value.items()) {
        (void)unused;
        if (!keys.contains(key)) {
            throw ObserverError("JSON object has an unknown key");
        }
    }
}

struct BigSigned {
    int sign{0};
    std::string digits{"0"};
};

BigSigned parse_amount(std::string_view value) {
    static constexpr std::string_view maximum_uint256 =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935";
    if (value.empty() || value.size() > maximum_uint256.size() + 1) {
        throw ObserverError("raw token amount is empty or exceeds uint256 scale");
    }
    std::size_t first = 0;
    int sign = 1;
    if (value.front() == '-') {
        sign = -1;
        first = 1;
    }
    if (first == value.size() ||
        !std::all_of(value.begin() + static_cast<std::ptrdiff_t>(first), value.end(),
            [](unsigned char character) { return std::isdigit(character) != 0; })) {
        throw ObserverError("raw token amount is not a signed decimal integer");
    }
    const std::string digits(value.substr(first));
    if (digits.size() > 1 && digits.front() == '0') {
        throw ObserverError("raw token amount is not canonical");
    }
    if (digits.size() > maximum_uint256.size() ||
        (digits.size() == maximum_uint256.size() &&
         std::string_view(digits) > maximum_uint256)) {
        throw ObserverError("raw token amount exceeds uint256");
    }
    if (digits == "0") {
        if (sign < 0) {
            throw ObserverError("negative zero token amount is not canonical");
        }
        return {};
    }
    return {.sign = sign, .digits = digits};
}

int magnitude_compare(const BigSigned& left, const BigSigned& right) {
    if (left.digits.size() != right.digits.size()) {
        return left.digits.size() < right.digits.size() ? -1 : 1;
    }
    if (left.digits == right.digits) {
        return 0;
    }
    return left.digits < right.digits ? -1 : 1;
}

std::string add_magnitude(std::string_view left, std::string_view right) {
    std::string output;
    const std::size_t maximum = std::max(left.size(), right.size());
    output.reserve(maximum + 1);
    int carry = 0;
    for (std::size_t offset = 0; offset < maximum; ++offset) {
        const int left_digit = offset < left.size() ? left[left.size() - 1 - offset] - '0' : 0;
        const int right_digit =
            offset < right.size() ? right[right.size() - 1 - offset] - '0' : 0;
        const int sum = left_digit + right_digit + carry;
        output.push_back(static_cast<char>('0' + (sum % 10)));
        carry = sum / 10;
    }
    if (carry != 0) {
        output.push_back(static_cast<char>('0' + carry));
    }
    std::reverse(output.begin(), output.end());
    return output;
}

std::string subtract_magnitude(std::string_view larger, std::string_view smaller) {
    std::string output;
    output.reserve(larger.size());
    int borrow = 0;
    for (std::size_t offset = 0; offset < larger.size(); ++offset) {
        int digit = larger[larger.size() - 1 - offset] - '0' - borrow;
        const int subtrahend =
            offset < smaller.size() ? smaller[smaller.size() - 1 - offset] - '0' : 0;
        if (digit < subtrahend) {
            digit += 10;
            borrow = 1;
        } else {
            borrow = 0;
        }
        output.push_back(static_cast<char>('0' + digit - subtrahend));
    }
    while (output.size() > 1 && output.back() == '0') {
        output.pop_back();
    }
    std::reverse(output.begin(), output.end());
    return output;
}

BigSigned add(BigSigned left, const BigSigned& right) {
    if (left.sign == 0) {
        return right;
    }
    if (right.sign == 0) {
        return left;
    }
    if (left.sign == right.sign) {
        left.digits = add_magnitude(left.digits, right.digits);
        return left;
    }
    const int comparison = magnitude_compare(left, right);
    if (comparison == 0) {
        return {};
    }
    if (comparison > 0) {
        left.digits = subtract_magnitude(left.digits, right.digits);
        return left;
    }
    return {
        .sign = right.sign,
        .digits = subtract_magnitude(right.digits, left.digits),
    };
}

int compare(const BigSigned& left, const BigSigned& right) {
    if (left.sign != right.sign) {
        return left.sign < right.sign ? -1 : 1;
    }
    if (left.sign == 0) {
        return 0;
    }
    const int magnitude = magnitude_compare(left, right);
    return left.sign > 0 ? magnitude : -magnitude;
}

std::string amount_string(const BigSigned& value) {
    if (value.sign < 0) {
        return "-" + value.digits;
    }
    return value.sign == 0 ? "0" : value.digits;
}

std::string record_checksum(const Json& payload) {
    constexpr std::uint64_t offset_basis = 14'695'981'039'346'656'037ULL;
    constexpr std::uint64_t prime = 1'099'511'628'211ULL;
    std::uint64_t checksum = offset_basis;
    for (const unsigned char character : payload.dump()) {
        checksum ^= character;
        checksum *= prime;
    }
    constexpr char hex[] = "0123456789abcdef";
    std::string output(16, '0');
    for (std::size_t index = 0; index < output.size(); ++index) {
        const std::size_t shift = (output.size() - 1 - index) * 4;
        output[index] = hex[(checksum >> shift) & 0x0fU];
    }
    return output;
}

ConfirmedAction action_from_stored_json(const Json& value) {
    ConfirmedAction action;
    action.chain_id = value.at("chain_id").get<std::uint64_t>();
    action.block_number = value.at("block_number").get<std::uint64_t>();
    action.block_hash = value.at("block_hash").get<std::string>();
    action.block_timestamp = value.at("block_timestamp").get<std::int64_t>();
    action.observed_head = value.at("observed_head").get<std::uint64_t>();
    action.transaction_hash = value.at("transaction_hash").get<std::string>();
    action.transaction_index = value.at("transaction_index").get<std::uint64_t>();
    action.actor = value.at("actor").get<std::string>();
    action.executor = value.at("executor").get<std::string>();
    action.venues = value.at("venues").get<std::vector<std::string>>();
    for (const auto& delta : value.at("token_deltas")) {
        action.token_deltas.push_back({
            .token = delta.at("token").get<std::string>(),
            .raw_amount = delta.at("raw_amount").get<std::string>(),
        });
    }
    action.venue_log_indices =
        value.at("venue_log_indices").get<std::vector<std::uint64_t>>();
    action.transfer_log_indices =
        value.at("transfer_log_indices").get<std::vector<std::uint64_t>>();
    action.receipt_success = value.at("receipt_success").get<bool>();
    action.costs_accounted = value.at("costs_accounted").get<bool>();
    action.allowlist_revision = value.at("allowlist_revision").get<std::string>();
    action.confidence_bps = value.at("confidence_bps").get<unsigned int>();
    return action;
}

bool in_window(
    const ConfirmedAction& action,
    std::int64_t as_of_epoch_seconds,
    unsigned int window_days) {
    if (window_days == 0 || window_days > 30) {
        throw ObserverError("ranking window must be between 1 and 30 days");
    }
    if (action.block_timestamp > as_of_epoch_seconds) {
        return false;
    }
    const std::int64_t seconds =
        static_cast<std::int64_t>(window_days) * 24 * 60 * 60;
    return action.block_timestamp >= as_of_epoch_seconds - seconds;
}

std::string csv_field(std::string_view value) {
    std::string output("\"");
    for (const char character : value) {
        if (character == '"') {
            output += "\"\"";
        } else {
            output += character;
        }
    }
    output += '"';
    return output;
}

void validate_stored_action(const ConfirmedAction& action) {
    if (action.chain_id != 137 || action.venues.size() != 2 ||
        action.venues[0] == action.venues[1] || action.token_deltas.size() != 2 ||
        action.venue_log_indices.size() != 2 ||
        action.transfer_log_indices.size() < 2 || !action.receipt_success ||
        !action.costs_accounted || action.confidence_bps < 8'000 ||
        action.confidence_bps > 9'000) {
        throw ObserverError("stored action invariants are invalid");
    }
    (void)require_hash(Json(action.block_hash), "stored block hash");
    (void)require_hash(Json(action.transaction_hash), "stored transaction hash");
    (void)require_address(Json(action.actor), "stored actor");
    (void)require_address(Json(action.executor), "stored executor");
    (void)require_sha256(Json(action.allowlist_revision), "stored allowlist revision");
    std::set<std::string> tokens;
    for (const auto& venue : action.venues) {
        (void)require_address(Json(venue), "stored venue");
    }
    for (const auto& delta : action.token_deltas) {
        (void)require_address(Json(delta.token), "stored token");
        (void)parse_amount(delta.raw_amount);
        if (!tokens.insert(delta.token).second) {
            throw ObserverError("stored action contains duplicate tokens");
        }
    }
}

class RegistryLock {
public:
    explicit RegistryLock(const std::filesystem::path& path) {
#ifdef _WIN32
        handle_ = CreateFileW(
            path.c_str(),
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr,
            OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            nullptr);
        if (handle_ == INVALID_HANDLE_VALUE) {
            throw ObserverError("cannot open registry lock");
        }
        OVERLAPPED overlapped{};
        if (!LockFileEx(handle_, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &overlapped)) {
            CloseHandle(handle_);
            handle_ = INVALID_HANDLE_VALUE;
            throw ObserverError("cannot acquire registry lock");
        }
#else
        descriptor_ = open(path.c_str(), O_CREAT | O_RDWR, 0600);
        if (descriptor_ < 0 || flock(descriptor_, LOCK_EX) != 0) {
            if (descriptor_ >= 0) {
                close(descriptor_);
                descriptor_ = -1;
            }
            throw ObserverError("cannot acquire registry lock");
        }
#endif
    }

    ~RegistryLock() {
#ifdef _WIN32
        if (handle_ != INVALID_HANDLE_VALUE) {
            OVERLAPPED overlapped{};
            (void)UnlockFileEx(handle_, 0, 1, 0, &overlapped);
            CloseHandle(handle_);
        }
#else
        if (descriptor_ >= 0) {
            (void)flock(descriptor_, LOCK_UN);
            close(descriptor_);
        }
#endif
    }

    RegistryLock(const RegistryLock&) = delete;
    RegistryLock& operator=(const RegistryLock&) = delete;

private:
#ifdef _WIN32
    HANDLE handle_{INVALID_HANDLE_VALUE};
#else
    int descriptor_{-1};
#endif
};

}  // namespace

VerifiedAllowlist VerifiedAllowlist::from_json(const Json& value) {
    reject_sensitive_config_names(value);
    require_exact_keys(
        value, {"schema_version", "chain_id", "revision", "venues", "tokens"});
    if (require_uint64(value.at("schema_version"), "allowlist schema_version") != 1 ||
        require_uint64(value.at("chain_id"), "allowlist chain_id") != 137 ||
        !value.at("venues").is_array() || !value.at("tokens").is_array()) {
        throw ObserverError("allowlist schema or chain is invalid");
    }

    VerifiedAllowlist allowlist;
    allowlist.revision_ = require_sha256(value.at("revision"), "allowlist revision");
    const auto load_entries = [](const Json& entries, bool token) {
        std::map<std::string, AllowlistEntry> output;
        for (const auto& value_entry : entries) {
            const std::set<std::string> keys = token
                ? std::set<std::string>{
                      "address", "label", "source_url", "source_sha256", "decimals"}
                : std::set<std::string>{
                      "address", "label", "source_url", "source_sha256"};
            require_exact_keys(value_entry, keys);
            AllowlistEntry entry;
            entry.address = require_address(value_entry.at("address"), "allowlist address");
            entry.label = require_label(value_entry.at("label"), "allowlist label");
            entry.source_url = require_source_url(value_entry.at("source_url"));
            entry.source_sha256 =
                require_sha256(value_entry.at("source_sha256"), "allowlist source_sha256");
            if (token) {
                const auto decimals =
                    require_uint64(value_entry.at("decimals"), "token decimals");
                if (decimals > 36) {
                    throw ObserverError("token decimals exceeds configured bound");
                }
                entry.decimals = static_cast<unsigned int>(decimals);
            }
            if (!output.emplace(entry.address, entry).second) {
                throw ObserverError("allowlist contains a duplicate address");
            }
        }
        if (output.size() < 2) {
            throw ObserverError("allowlist must contain at least two entries per category");
        }
        return output;
    };
    allowlist.venues_ = load_entries(value.at("venues"), false);
    allowlist.tokens_ = load_entries(value.at("tokens"), true);
    return allowlist;
}

bool VerifiedAllowlist::has_venue(std::string_view address) const {
    return venues_.contains(std::string(address));
}

bool VerifiedAllowlist::has_token(std::string_view address) const {
    return tokens_.contains(std::string(address));
}

const AllowlistEntry& VerifiedAllowlist::venue(std::string_view address) const {
    return venues_.at(std::string(address));
}

const AllowlistEntry& VerifiedAllowlist::token(std::string_view address) const {
    return tokens_.at(std::string(address));
}

const std::string& VerifiedAllowlist::revision() const noexcept {
    return revision_;
}

ConfirmedAction parse_confirmed_action(
    const Json& value,
    const VerifiedAllowlist& allowlist,
    const ObservationPolicy& policy) {
    static const std::set<std::string> keys{
        "schema_version",
        "chain_id",
        "block_number",
        "block_hash",
        "block_timestamp",
        "observed_head",
        "transaction_hash",
        "transaction_index",
        "actor",
        "executor",
        "venues",
        "token_deltas",
        "venue_log_indices",
        "transfer_log_indices",
        "receipt_success",
        "costs_accounted",
        "allowlist_revision",
    };
    require_exact_keys(value, keys);
    if (require_uint64(value.at("schema_version"), "action schema_version") != 1) {
        throw ObserverError("confirmed action schema version is unsupported");
    }

    ConfirmedAction action;
    action.chain_id = require_uint64(value.at("chain_id"), "action chain_id");
    action.block_number = require_uint64(value.at("block_number"), "action block_number");
    action.block_hash = require_hash(value.at("block_hash"), "action block_hash");
    const auto timestamp =
        require_uint64(value.at("block_timestamp"), "action block_timestamp");
    if (timestamp > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
        throw ObserverError("action timestamp is out of range");
    }
    action.block_timestamp = static_cast<std::int64_t>(timestamp);
    action.observed_head = require_uint64(value.at("observed_head"), "action observed_head");
    action.transaction_hash =
        require_hash(value.at("transaction_hash"), "action transaction_hash");
    action.transaction_index =
        require_uint64(value.at("transaction_index"), "action transaction_index");
    action.actor = require_address(value.at("actor"), "action actor");
    action.executor = require_address(value.at("executor"), "action executor");
    action.allowlist_revision =
        require_sha256(value.at("allowlist_revision"), "action allowlist_revision");

    if (action.chain_id != 137 || action.allowlist_revision != allowlist.revision()) {
        throw ObserverError("action chain or allowlist revision does not match");
    }
    if (action.observed_head < action.block_number ||
        action.observed_head - action.block_number + 1 < policy.minimum_confirmations) {
        throw ObserverError("action does not meet the confirmation policy");
    }

    if (!value.at("receipt_success").is_boolean() ||
        !value.at("costs_accounted").is_boolean()) {
        throw ObserverError("action evidence flags must be booleans");
    }
    action.receipt_success = value.at("receipt_success").get<bool>();
    action.costs_accounted = value.at("costs_accounted").get<bool>();
    if (!action.receipt_success || !action.costs_accounted) {
        throw ObserverError("failed receipts or unaccounted costs are not rankable");
    }

    if (!value.at("venues").is_array() || value.at("venues").size() != 2) {
        throw ObserverError("action must identify exactly two venues");
    }
    for (const auto& venue_value : value.at("venues")) {
        const std::string venue = require_address(venue_value, "action venue");
        if (!allowlist.has_venue(venue)) {
            throw ObserverError("action venue is not externally allowlisted");
        }
        action.venues.push_back(venue);
    }
    if (action.venues[0] == action.venues[1]) {
        throw ObserverError("action venues must be distinct");
    }

    if (!value.at("token_deltas").is_object() || value.at("token_deltas").size() != 2) {
        throw ObserverError("action must identify exactly two token deltas");
    }
    bool has_positive = false;
    for (const auto& [token_key, amount_value] : value.at("token_deltas").items()) {
        const std::string token =
            require_address(Json(token_key), "action token");
        if (!allowlist.has_token(token) || !amount_value.is_string()) {
            throw ObserverError("action token is not externally allowlisted");
        }
        const std::string amount = amount_value.get<std::string>();
        const BigSigned parsed = parse_amount(amount);
        has_positive = has_positive || parsed.sign > 0;
        action.token_deltas.push_back({.token = token, .raw_amount = amount});
    }
    if (!has_positive) {
        throw ObserverError("action has no positive realized token delta");
    }

    const auto read_indices = [](const Json& array, std::string_view field) {
        if (!array.is_array()) {
            throw ObserverError(std::string(field) + " must be an array");
        }
        std::vector<std::uint64_t> result;
        std::set<std::uint64_t> unique;
        for (const auto& index : array) {
            const auto parsed = require_uint64(index, field);
            if (!unique.insert(parsed).second) {
                throw ObserverError(std::string(field) + " contains duplicates");
            }
            result.push_back(parsed);
        }
        return result;
    };
    action.venue_log_indices =
        read_indices(value.at("venue_log_indices"), "venue log indices");
    action.transfer_log_indices =
        read_indices(value.at("transfer_log_indices"), "transfer log indices");
    if (action.venue_log_indices.size() != 2 ||
        action.transfer_log_indices.size() < 2) {
        throw ObserverError("action lacks two-venue transfer-log evidence");
    }

    action.confidence_bps = 8'000;
    if (action.actor == action.executor) {
        action.confidence_bps += 500;
    }
    if (policy.minimum_confirmations <=
        (action.observed_head - action.block_number + 1) / 2) {
        action.confidence_bps += 500;
    }
    return action;
}

Json confirmed_action_to_json(const ConfirmedAction& action) {
    Json deltas = Json::array();
    for (const auto& delta : action.token_deltas) {
        deltas.push_back({{"token", delta.token}, {"raw_amount", delta.raw_amount}});
    }
    return {
        {"schema_version", 1},
        {"chain_id", action.chain_id},
        {"block_number", action.block_number},
        {"block_hash", action.block_hash},
        {"block_timestamp", action.block_timestamp},
        {"observed_head", action.observed_head},
        {"transaction_hash", action.transaction_hash},
        {"transaction_index", action.transaction_index},
        {"actor", action.actor},
        {"executor", action.executor},
        {"venues", action.venues},
        {"token_deltas", deltas},
        {"venue_log_indices", action.venue_log_indices},
        {"transfer_log_indices", action.transfer_log_indices},
        {"receipt_success", action.receipt_success},
        {"costs_accounted", action.costs_accounted},
        {"allowlist_revision", action.allowlist_revision},
        {"confidence_bps", action.confidence_bps},
    };
}

ActionRegistry::ActionRegistry(std::filesystem::path directory)
    : directory_(std::move(directory)) {}

void ActionRegistry::initialize() {
    std::error_code error;
    if (std::filesystem::exists(directory_, error)) {
        if (error || !std::filesystem::is_directory(directory_) ||
            std::filesystem::is_symlink(directory_)) {
            throw ObserverError("registry path is not a safe directory");
        }
        return;
    }
    if (!std::filesystem::create_directories(directory_, error) || error) {
        throw ObserverError("cannot create action registry directory");
    }
}

bool ActionRegistry::append(const ConfirmedAction& action) {
    initialize();
    [[maybe_unused]] const RegistryLock lock(directory_ / ".registry.lock");
    const Json payload = confirmed_action_to_json(action);
    const Json envelope{
        {"checksum_fnv1a64", record_checksum(payload)},
        {"payload", payload},
    };
    const std::string name =
        action.transaction_hash.substr(2) + ".json";
    const std::filesystem::path destination = directory_ / name;
    if (std::filesystem::exists(destination)) {
        if (std::filesystem::is_symlink(destination) ||
            !std::filesystem::is_regular_file(destination)) {
            throw ObserverError("registry destination is not a regular file");
        }
        std::ifstream existing(destination, std::ios::binary);
        Json current;
        existing >> current;
        if (!existing || current != envelope) {
            throw ObserverError("registry contains a conflicting transaction record");
        }
        return false;
    }

    std::random_device entropy;
    const std::uint64_t nonce =
        (static_cast<std::uint64_t>(entropy()) << 32) ^
        static_cast<std::uint64_t>(entropy());
    std::ostringstream pending_name;
    pending_name << name << '.' << std::hex << nonce << ".pending";
    const std::filesystem::path pending = directory_ / pending_name.str();
    {
        std::ofstream output(pending, std::ios::binary | std::ios::trunc);
        if (!output) {
            throw ObserverError("cannot create pending registry record");
        }
        output << envelope.dump() << '\n';
        output.flush();
        if (!output) {
            throw ObserverError("cannot persist pending registry record");
        }
    }
    std::error_code error;
    std::filesystem::rename(pending, destination, error);
    if (error) {
        std::error_code remove_error;
        (void)std::filesystem::remove(pending, remove_error);
        if (std::filesystem::exists(destination) &&
            !std::filesystem::is_symlink(destination) &&
            std::filesystem::is_regular_file(destination)) {
            std::ifstream existing(destination, std::ios::binary);
            Json current;
            existing >> current;
            if (existing && current == envelope) {
                return false;
            }
            throw ObserverError("registry contains a conflicting transaction record");
        }
        throw ObserverError("cannot atomically publish registry record");
    }
    return true;
}

std::vector<ConfirmedAction> ActionRegistry::load() const {
    if (!std::filesystem::exists(directory_)) {
        return {};
    }
    std::vector<std::filesystem::path> files;
    for (const auto& entry : std::filesystem::directory_iterator(directory_)) {
        if (entry.is_symlink()) {
            throw ObserverError("registry contains a prohibited symbolic link");
        }
        if (entry.is_regular_file() && entry.path().extension() == ".json") {
            files.push_back(entry.path());
        }
    }
    std::sort(files.begin(), files.end());

    std::vector<ConfirmedAction> actions;
    for (const auto& path : files) {
        const auto size = std::filesystem::file_size(path);
        if (size == 0 || size > maximum_record_bytes) {
            throw ObserverError("registry record size is invalid");
        }
        std::ifstream input(path, std::ios::binary);
        Json envelope;
        try {
            input >> envelope;
        } catch (const Json::exception&) {
            throw ObserverError("registry record contains malformed JSON");
        }
        if (!input || !envelope.is_object() || envelope.size() != 2 ||
            !envelope.contains("checksum_fnv1a64") ||
            !envelope.at("checksum_fnv1a64").is_string() ||
            !envelope.contains("payload") ||
            envelope.at("checksum_fnv1a64").get<std::string>() !=
                record_checksum(envelope.at("payload"))) {
            throw ObserverError("registry record integrity check failed");
        }
        ConfirmedAction action = action_from_stored_json(envelope.at("payload"));
        validate_stored_action(action);
        if (path.filename().string() !=
            action.transaction_hash.substr(2) + ".json") {
            throw ObserverError("registry filename does not match transaction hash");
        }
        actions.push_back(std::move(action));
    }
    return actions;
}

Json build_rankings(
    const std::vector<ConfirmedAction>& actions,
    const VerifiedAllowlist& allowlist,
    std::int64_t as_of_epoch_seconds,
    unsigned int window_days) {
    struct Aggregate {
        BigSigned amount;
        std::uint64_t actions{0};
        unsigned int confidence_bps{10'000};
    };
    std::map<std::pair<std::string, std::string>, Aggregate> aggregates;
    for (const auto& action : actions) {
        validate_stored_action(action);
        if (!in_window(action, as_of_epoch_seconds, window_days) ||
            action.chain_id != 137 ||
            action.allowlist_revision != allowlist.revision()) {
            continue;
        }
        for (const auto& delta : action.token_deltas) {
            auto& aggregate = aggregates[{action.actor, delta.token}];
            aggregate.amount = add(aggregate.amount, parse_amount(delta.raw_amount));
            ++aggregate.actions;
            aggregate.confidence_bps =
                std::min(aggregate.confidence_bps, action.confidence_bps);
        }
    }

    struct Row {
        std::string actor;
        std::string token;
        Aggregate aggregate;
    };
    std::vector<Row> rows;
    for (const auto& [key, aggregate] : aggregates) {
        rows.push_back({.actor = key.first, .token = key.second, .aggregate = aggregate});
    }
    std::sort(rows.begin(), rows.end(), [](const Row& left, const Row& right) {
        if (left.token != right.token) {
            return left.token < right.token;
        }
        const int amount_order = compare(left.aggregate.amount, right.aggregate.amount);
        return amount_order != 0 ? amount_order > 0 : left.actor < right.actor;
    });

    Json entries = Json::array();
    std::string current_token;
    std::uint64_t rank = 0;
    for (const auto& row : rows) {
        if (row.token != current_token) {
            current_token = row.token;
            rank = 1;
        } else {
            ++rank;
        }
        const auto& token = allowlist.token(row.token);
        entries.push_back({
            {"rank_within_token", rank},
            {"actor", row.actor},
            {"token", row.token},
            {"token_symbol", token.label},
            {"token_decimals", *token.decimals},
            {"realized_pnl_raw", amount_string(row.aggregate.amount)},
            {"action_count", row.aggregate.actions},
            {"confidence_bps", row.aggregate.confidence_bps},
        });
    }
    return {
        {"schema_version", 1},
        {"chain_id", 137},
        {"as_of_epoch_seconds", as_of_epoch_seconds},
        {"window_days", window_days},
        {"allowlist_revision", allowlist.revision()},
        {"methodology", "confirmed_receipt_transfer_deltas_costs_accounted"},
        {"entries", entries},
    };
}

std::string rankings_to_csv(const Json& rankings) {
    std::ostringstream output;
    output << "rank_within_token,actor,token,token_symbol,token_decimals,"
              "realized_pnl_raw,action_count,confidence_bps\n";
    for (const auto& entry : rankings.at("entries")) {
        output << entry.at("rank_within_token").get<std::uint64_t>() << ','
               << csv_field(entry.at("actor").get<std::string>()) << ','
               << csv_field(entry.at("token").get<std::string>()) << ','
               << csv_field(entry.at("token_symbol").get<std::string>()) << ','
               << entry.at("token_decimals").get<unsigned int>() << ','
               << csv_field(entry.at("realized_pnl_raw").get<std::string>()) << ','
               << entry.at("action_count").get<std::uint64_t>() << ','
               << entry.at("confidence_bps").get<unsigned int>() << '\n';
    }
    return output.str();
}

Json build_tuning_export(
    const std::vector<ConfirmedAction>& actions,
    const VerifiedAllowlist& allowlist,
    std::int64_t as_of_epoch_seconds,
    unsigned int window_days) {
    struct Aggregate {
        BigSigned amount;
        std::uint64_t action_count{0};
        std::uint64_t positive_count{0};
        unsigned int confidence_bps{10'000};
    };
    using Key = std::tuple<std::string, std::string, std::string>;
    std::map<Key, Aggregate> aggregates;
    for (const auto& action : actions) {
        validate_stored_action(action);
        if (!in_window(action, as_of_epoch_seconds, window_days) ||
            action.allowlist_revision != allowlist.revision()) {
            continue;
        }
        std::vector<std::string> venues = action.venues;
        std::sort(venues.begin(), venues.end());
        for (const auto& delta : action.token_deltas) {
            auto& aggregate = aggregates[{venues[0], venues[1], delta.token}];
            const BigSigned amount = parse_amount(delta.raw_amount);
            aggregate.amount = add(aggregate.amount, amount);
            ++aggregate.action_count;
            if (amount.sign > 0) {
                ++aggregate.positive_count;
            }
            aggregate.confidence_bps =
                std::min(aggregate.confidence_bps, action.confidence_bps);
        }
    }

    Json entries = Json::array();
    for (const auto& [key, aggregate] : aggregates) {
        const auto& [first, second, token] = key;
        entries.push_back({
            {"venue_a", first},
            {"venue_a_label", allowlist.venue(first).label},
            {"venue_b", second},
            {"venue_b_label", allowlist.venue(second).label},
            {"token", token},
            {"token_symbol", allowlist.token(token).label},
            {"realized_pnl_raw", amount_string(aggregate.amount)},
            {"action_count", aggregate.action_count},
            {"positive_action_count", aggregate.positive_count},
            {"minimum_confidence_bps", aggregate.confidence_bps},
        });
    }
    return {
        {"schema_version", 1},
        {"chain_id", 137},
        {"as_of_epoch_seconds", as_of_epoch_seconds},
        {"window_days", window_days},
        {"allowlist_revision", allowlist.revision()},
        {"confirmed_only", true},
        {"entries", entries},
    };
}

}  // namespace godbrain::polygon::observer
