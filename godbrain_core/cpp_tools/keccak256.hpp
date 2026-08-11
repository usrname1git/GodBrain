#pragma once
#include <stdint.h>
#include <string.h>
#include <string>
#include <vector>
#include <iomanip>
#include <sstream>

class Keccak256 {
public:
    static void getHash(const uint8_t* data, size_t length, uint8_t hash[32]) {
        uint64_t state[25] = {0};
        uint8_t block[136] = {0};
        size_t block_size = 136; // 1088 bits for Keccak-256
        
        size_t offset = 0;
        while (length >= block_size) {
            for (size_t i = 0; i < block_size / 8; ++i) {
                uint64_t v = 0;
                memcpy(&v, data + offset + i * 8, 8);
                state[i] ^= v;
            }
            keccak_f1600(state);
            offset += block_size;
            length -= block_size;
        }
        
        memcpy(block, data + offset, length);
        block[length] ^= 0x01; // Keccak padding (0x01 for Ethereum Keccak, NOT 0x06 for SHA3)
        block[block_size - 1] ^= 0x80;
        
        for (size_t i = 0; i < block_size / 8; ++i) {
            uint64_t v = 0;
            memcpy(&v, block + i * 8, 8);
            state[i] ^= v;
        }
        keccak_f1600(state);
        
        for (size_t i = 0; i < 4; ++i) {
            memcpy(hash + i * 8, &state[i], 8);
        }
    }

private:
    static uint64_t rotl64(uint64_t x, int i) {
        return (x << i) | (x >> (64 - i));
    }
    
    static void keccak_f1600(uint64_t state[25]) {
        const uint64_t RC[24] = {
            1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44
        };
        const int ROTC[24] = {
            1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14
        };
        const uint64_t RC_CONSTANTS[24] = {
            0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL,
            0x8000000080008000ULL, 0x000000000000808bULL, 0x0000000080000001ULL,
            0x8000000080008081ULL, 0x8000000000008009ULL, 0x000000000000008aULL,
            0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
            0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL,
            0x8000000000008003ULL, 0x8000000000008002ULL, 0x8000000000000080ULL,
            0x000000000000800aULL, 0x800000008000000aULL, 0x8000000080008081ULL,
            0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL
        };

        for (int round = 0; round < 24; ++round) {
            uint64_t C[5], D[5];
            for (int i = 0; i < 5; ++i) {
                C[i] = state[i] ^ state[i + 5] ^ state[i + 10] ^ state[i + 15] ^ state[i + 20];
            }
            for (int i = 0; i < 5; ++i) {
                D[i] = C[(i + 4) % 5] ^ rotl64(C[(i + 1) % 5], 1);
            }
            for (int i = 0; i < 5; ++i) {
                for (int j = 0; j < 25; j += 5) {
                    state[i + j] ^= D[i];
                }
            }
            
            uint64_t x = 1, y = 0, current = state[1];
            for (int i = 0; i < 24; ++i) {
                uint64_t tX = x;
                x = y;
                y = (2 * tX + 3 * y) % 5;
                uint64_t shift = current;
                current = state[x + 5 * y];
                state[x + 5 * y] = rotl64(shift, RC[i]);
            }
            
            for (int j = 0; j < 25; j += 5) {
                uint64_t temp[5];
                for (int i = 0; i < 5; ++i) temp[i] = state[i + j];
                for (int i = 0; i < 5; ++i) {
                    state[i + j] = temp[i] ^ (~temp[(i + 1) % 5] & temp[(i + 2) % 5]);
                }
            }
            state[0] ^= RC_CONSTANTS[round];
        }
    }
};

inline std::string to_hex(const uint8_t* data, size_t length) {
    std::stringstream ss;
    ss << std::hex << std::setfill('0');
    for (size_t i = 0; i < length; ++i) {
        ss << std::setw(2) << static_cast<int>(data[i]);
    }
    return ss.str();
}

inline std::string keccak256(const std::string& input) {
    uint8_t hash[32];
    Keccak256::getHash(reinterpret_cast<const uint8_t*>(input.data()), input.size(), hash);
    return to_hex(hash, 32);
}
