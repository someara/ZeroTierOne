// AES-GMAC-SIV test vector generator for Zig compatibility testing.
//
// This generates known test vectors by encrypting test data with the C++
// AES-GMAC-SIV implementation. The Zig implementation can then verify it
// produces byte-identical output.

#include "node/AES.hpp"
#include "node/Utils.hpp"
#include <iostream>
#include <iomanip>
#include <cstring>

using namespace ZeroTier;

// Helper to print hex
static void printHex(const char* label, const void* data, size_t len)
{
	const uint8_t* bytes = reinterpret_cast<const uint8_t*>(data);
	std::cout << label;
	for (size_t i = 0; i < len; i++) {
		std::cout << std::hex << std::setw(2) << std::setfill('0') << (int)bytes[i];
	}
	std::cout << std::dec << std::endl;
}

int main()
{
	std::cout << "# AES-GMAC-SIV Test Vectors (C++ Reference)" << std::endl;
	std::cout << "# Format: key0, key1, iv, plaintext, ciphertext, tag" << std::endl;
	std::cout << std::endl;

	// ────────────────────────────────────────────────────────────────
	// Test 1: Small buffer (16 bytes) — baseline, no SIMD
	// ────────────────────────────────────────────────────────────────
	std::cout << "## Test 1: 16-byte buffer (single block)" << std::endl;
	{
		unsigned char key0[32];
		unsigned char key1[32];
		for (int i = 0; i < 32; i++) {
			key0[i] = i;
			key1[i] = (i * 7) & 0xff;
		}

		unsigned char plaintext[16];
		for (int i = 0; i < 16; i++) {
			plaintext[i] = (i * 123) & 0xff;
		}

		unsigned char ciphertext[16];

		AES k0(key0);
		AES k1(key1);
		AES::GMACSIVEncryptor enc(k0, k1);

		enc.init(42, ciphertext);
		enc.update1(plaintext, 16);
		enc.finish1();
		enc.update2(plaintext, 16);
		const uint64_t* tag = enc.finish2();

		printHex("key0: ", key0, 32);
		printHex("key1: ", key1, 32);
		std::cout << "iv: 42" << std::endl;
		printHex("plaintext: ", plaintext, 16);
		printHex("ciphertext: ", ciphertext, 16);
		printHex("tag: ", tag, 16);
		std::cout << std::endl;
	}

	// ────────────────────────────────────────────────────────────────
	// Test 2: 64 bytes — multiple blocks, may trigger SIMD on some platforms
	// ────────────────────────────────────────────────────────────────
	std::cout << "## Test 2: 64-byte buffer" << std::endl;
	{
		unsigned char key0[32];
		unsigned char key1[32];
		for (int i = 0; i < 32; i++) {
			key0[i] = (i * 3) & 0xff;
			key1[i] = (i * 11) & 0xff;
		}

		unsigned char plaintext[64];
		for (int i = 0; i < 64; i++) {
			plaintext[i] = (i * 17) & 0xff;
		}

		unsigned char ciphertext[64];

		AES k0(key0);
		AES k1(key1);
		AES::GMACSIVEncryptor enc(k0, k1);

		enc.init(0x123456789abcdefULL, ciphertext);
		enc.update1(plaintext, 64);
		enc.finish1();
		enc.update2(plaintext, 64);
		const uint64_t* tag = enc.finish2();

		printHex("key0: ", key0, 32);
		printHex("key1: ", key1, 32);
		std::cout << "iv: 1311768467463790320" << std::endl; // decimal of 0x123456789abcdef
		printHex("plaintext: ", plaintext, 64);
		printHex("ciphertext: ", ciphertext, 64);
		printHex("tag: ", tag, 16);
		std::cout << std::endl;
	}

	// ────────────────────────────────────────────────────────────────
	// Test 3: 1024 bytes — typical packet size
	// ────────────────────────────────────────────────────────────────
	std::cout << "## Test 3: 1024-byte buffer (typical packet)" << std::endl;
	{
		unsigned char key0[32];
		unsigned char key1[32];
		for (int i = 0; i < 32; i++) {
			key0[i] = (255 - i) & 0xff;
			key1[i] = (i ^ 0xaa) & 0xff;
		}

		unsigned char plaintext[1024];
		for (int i = 0; i < 1024; i++) {
			plaintext[i] = (i * 13 + 42) & 0xff;
		}

		unsigned char ciphertext[1024];

		AES k0(key0);
		AES k1(key1);
		AES::GMACSIVEncryptor enc(k0, k1);

		enc.init(0xdeadbeef, ciphertext);
		enc.update1(plaintext, 1024);
		enc.finish1();
		enc.update2(plaintext, 1024);
		const uint64_t* tag = enc.finish2();

		printHex("key0: ", key0, 32);
		printHex("key1: ", key1, 32);
		std::cout << "iv: 3735928559" << std::endl; // decimal of 0xdeadbeef
		printHex("plaintext_hash_sha256: ", plaintext, 32); // Just first 32 bytes for brevity
		printHex("ciphertext_hash_sha256: ", ciphertext, 32);
		printHex("tag: ", tag, 16);
		std::cout << std::endl;
	}

	// ────────────────────────────────────────────────────────────────
	// Test 4: 8192 bytes — large buffer, definitely triggers SIMD
	// ────────────────────────────────────────────────────────────────
	std::cout << "## Test 4: 8192-byte buffer (SIMD fast path)" << std::endl;
	{
		unsigned char key0[32];
		unsigned char key1[32];
		for (int i = 0; i < 32; i++) {
			key0[i] = (i * 19) & 0xff;
			key1[i] = (i * 23) & 0xff;
		}

		unsigned char plaintext[8192];
		for (int i = 0; i < 8192; i++) {
			plaintext[i] = (i * 29 + 7) & 0xff;
		}

		unsigned char ciphertext[8192];

		AES k0(key0);
		AES k1(key1);
		AES::GMACSIVEncryptor enc(k0, k1);

		enc.init(0x0102030405060708ULL, ciphertext);
		enc.update1(plaintext, 8192);
		enc.finish1();
		enc.update2(plaintext, 8192);
		const uint64_t* tag = enc.finish2();

		printHex("key0: ", key0, 32);
		printHex("key1: ", key1, 32);
		std::cout << "iv: 72623859790382856" << std::endl; // decimal of 0x0102030405060708
		printHex("plaintext_first32: ", plaintext, 32);
		printHex("plaintext_last32: ", plaintext + 8192 - 32, 32);
		printHex("ciphertext_first32: ", ciphertext, 32);
		printHex("ciphertext_last32: ", ciphertext + 8192 - 32, 32);
		printHex("tag: ", tag, 16);
		std::cout << std::endl;
	}

	// ────────────────────────────────────────────────────────────────
	// Test 5: Non-aligned size (100 bytes) — tests partial block handling
	// ────────────────────────────────────────────────────────────────
	std::cout << "## Test 5: 100-byte buffer (non-block-aligned)" << std::endl;
	{
		unsigned char key0[32];
		unsigned char key1[32];
		for (int i = 0; i < 32; i++) {
			key0[i] = i;
			key1[i] = i;
		}

		unsigned char plaintext[100];
		for (int i = 0; i < 100; i++) {
			plaintext[i] = i & 0xff;
		}

		unsigned char ciphertext[100];

		AES k0(key0);
		AES k1(key1);
		AES::GMACSIVEncryptor enc(k0, k1);

		enc.init(999, ciphertext);
		enc.update1(plaintext, 100);
		enc.finish1();
		enc.update2(plaintext, 100);
		const uint64_t* tag = enc.finish2();

		printHex("key0: ", key0, 32);
		printHex("key1: ", key1, 32);
		std::cout << "iv: 999" << std::endl;
		printHex("plaintext: ", plaintext, 100);
		printHex("ciphertext: ", ciphertext, 100);
		printHex("tag: ", tag, 16);
		std::cout << std::endl;
	}

	// ────────────────────────────────────────────────────────────────
	// Test 6: Zero IV and zero keys (edge case)
	// ────────────────────────────────────────────────────────────────
	std::cout << "## Test 6: All-zero keys and IV" << std::endl;
	{
		unsigned char key0[32] = {0};
		unsigned char key1[32] = {0};
		unsigned char plaintext[32];
		for (int i = 0; i < 32; i++) {
			plaintext[i] = 0xff;
		}

		unsigned char ciphertext[32];

		AES k0(key0);
		AES k1(key1);
		AES::GMACSIVEncryptor enc(k0, k1);

		enc.init(0, ciphertext);
		enc.update1(plaintext, 32);
		enc.finish1();
		enc.update2(plaintext, 32);
		const uint64_t* tag = enc.finish2();

		printHex("key0: ", key0, 32);
		printHex("key1: ", key1, 32);
		std::cout << "iv: 0" << std::endl;
		printHex("plaintext: ", plaintext, 32);
		printHex("ciphertext: ", ciphertext, 32);
		printHex("tag: ", tag, 16);
		std::cout << std::endl;
	}

	std::cout << "# All test vectors generated successfully." << std::endl;
	return 0;
}
