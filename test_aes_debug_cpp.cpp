// Debug C++ AES-GMAC-SIV to see intermediate values

#include "node/AES.hpp"
#include "node/Utils.hpp"
#include <iostream>
#include <iomanip>
#include <cstring>

using namespace ZeroTier;

static void printHex(const char* label, const void* data, size_t len)
{
	const uint8_t* bytes = reinterpret_cast<const uint8_t*>(data);
	std::cout << label;
	for (size_t i = 0; i < len; i++) {
		std::cout << std::hex << std::setw(2) << std::setfill('0') << (int)bytes[i];
	}
	std::cout << std::dec << std::endl;
}

static void hexToBytes(const char* hex, unsigned char* bytes, size_t len)
{
	for (size_t i = 0; i < len; i++) {
		sscanf(hex + 2*i, "%2hhx", &bytes[i]);
	}
}

int main()
{
	std::cout << "\n=== C++ Step-by-step Test 2 Debug ===\n\n";

	unsigned char key0[32];
	unsigned char key1[32];
	hexToBytes("000306090c0f1215181b1e2124272a2d303336393c3f4245484b4e5154575a5d", key0, 32);
	hexToBytes("000b16212c37424d58636e79848f9aa5b0bbc6d1dce7f2fd08131e29343f4a55", key1, 32);

	printHex("Key0: ", key0, 32);
	printHex("Key1: ", key1, 32);
	std::cout << std::endl;

	unsigned char plaintext[64];
	hexToBytes("00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f2031425364758697a8b9cadbecfd0e1f30415263748596a7b8c9daebfc0d1e2f", plaintext, 64);

	printHex("Plaintext: ", plaintext, 64);
	std::cout << std::endl;

	AES k0(key0);
	AES k1(key1);

	// Test basic AES encryption
	{
		std::cout << "--- Basic AES test ---" << std::endl;
		unsigned char test_block[16] = {0};
		unsigned char encrypted[16];
		k0.encrypt(test_block, encrypted);
		printHex("AES_K0(zeros): ", encrypted, 16);
		std::cout << std::endl;
	}

	unsigned char ciphertext[64];
	AES::GMACSIVEncryptor enc(k0, k1);

	uint64_t iv_value = 1311768467463790320ULL; // 0x123456789abcdef

	std::cout << "--- init(IV=" << iv_value << ") ---" << std::endl;
	enc.init(iv_value, ciphertext);

	// Access internal state (we'll need to look at the structure)
	// Since we can't easily access private members, let's just trace through

	std::cout << "--- update1(plaintext) ---" << std::endl;
	enc.update1(plaintext, 64);

	std::cout << "--- finish1() ---" << std::endl;
	enc.finish1();

	std::cout << "--- update2(plaintext) ---" << std::endl;
	enc.update2(plaintext, 64);

	std::cout << "--- finish2() ---" << std::endl;
	const uint64_t* tag = enc.finish2();

	printHex("Final tag: ", tag, 16);
	printHex("Final ciphertext: ", ciphertext, 64);
	std::cout << std::endl;

	std::cout << "Expected ciphertext: 7d76beb188ae1f8d36da6389d5a481ce0ec6abad1ad1c36083fe7868bb443c4d7a354328ce1e551d747b8ccaa8c35b711f94b64dd52b36c5cd330c0805158734" << std::endl;
	std::cout << "Expected tag:        a2b508638436c16fedb4dcb9988f2d5b" << std::endl;

	return 0;
}
