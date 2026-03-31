// Test a single vector in isolation

#include "node/AES.hpp"
#include <iostream>
#include <iomanip>

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

int main()
{
	unsigned char key0[32];
	unsigned char key1[32];

	// Generate keys exactly as in test_aes_vectors.cpp
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
	printHex("plaintext: ", plaintext, 64);
	printHex("ciphertext: ", ciphertext, 64);
	printHex("tag: ", tag, 16);

	return 0;
}
