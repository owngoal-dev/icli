#import "SHA512Crypt.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/SecRandom.h>

static const char kCryptAlphabet[] = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

static void cryptBase64(NSMutableString *out, unsigned b2, unsigned b1, unsigned b0, int n) {
    unsigned w = (b2 << 16) | (b1 << 8) | b0;
    while (n-- > 0) { [out appendFormat:@"%c", kCryptAlphabet[w & 0x3f]]; w >>= 6; }
}

char *icli_sha512_crypt(const char *key, const char *salt) {
    if (!key || !salt) return NULL;
    size_t keyLength = strlen(key);
    size_t saltLength = MIN(strlen(salt), (size_t)16);
    for (size_t i = 0; i < saltLength; i++) if (!strchr(kCryptAlphabet, salt[i]) || salt[i] == '$') return NULL;
    unsigned char digestA[64], digestB[64], digestP[64], digestS[64];
    CC_SHA512_CTX ctx, alt;

    CC_SHA512_Init(&alt);
    CC_SHA512_Update(&alt, key, (CC_LONG)keyLength);
    CC_SHA512_Update(&alt, salt, (CC_LONG)saltLength);
    CC_SHA512_Update(&alt, key, (CC_LONG)keyLength);
    CC_SHA512_Final(digestB, &alt);

    CC_SHA512_Init(&ctx);
    CC_SHA512_Update(&ctx, key, (CC_LONG)keyLength);
    CC_SHA512_Update(&ctx, salt, (CC_LONG)saltLength);
    size_t remaining = keyLength;
    for (; remaining > 64; remaining -= 64) CC_SHA512_Update(&ctx, digestB, 64);
    CC_SHA512_Update(&ctx, digestB, (CC_LONG)remaining);
    for (size_t bits = keyLength; bits > 0; bits >>= 1) {
        if (bits & 1) CC_SHA512_Update(&ctx, digestB, 64);
        else CC_SHA512_Update(&ctx, key, (CC_LONG)keyLength);
    }
    CC_SHA512_Final(digestA, &ctx);

    CC_SHA512_Init(&alt);
    for (size_t i = 0; i < keyLength; i++) CC_SHA512_Update(&alt, key, (CC_LONG)keyLength);
    CC_SHA512_Final(digestP, &alt);
    unsigned char *pBytes = malloc(keyLength ?: 1);
    for (size_t copied = 0; copied < keyLength; copied += 64)
        memcpy(pBytes + copied, digestP, MIN((size_t)64, keyLength - copied));

    CC_SHA512_Init(&alt);
    for (int i = 0; i < 16 + digestA[0]; i++) CC_SHA512_Update(&alt, salt, (CC_LONG)saltLength);
    CC_SHA512_Final(digestS, &alt);
    unsigned char sBytes[16];
    for (size_t copied = 0; copied < saltLength; copied += 64)
        memcpy(sBytes + copied, digestS, MIN((size_t)64, saltLength - copied));

    unsigned char digestC[64];
    memcpy(digestC, digestA, 64);
    for (int round = 0; round < 5000; round++) {
        CC_SHA512_Init(&ctx);
        if (round & 1) CC_SHA512_Update(&ctx, pBytes, (CC_LONG)keyLength);
        else CC_SHA512_Update(&ctx, digestC, 64);
        if (round % 3) CC_SHA512_Update(&ctx, sBytes, (CC_LONG)saltLength);
        if (round % 7) CC_SHA512_Update(&ctx, pBytes, (CC_LONG)keyLength);
        if (round & 1) CC_SHA512_Update(&ctx, digestC, 64);
        else CC_SHA512_Update(&ctx, pBytes, (CC_LONG)keyLength);
        CC_SHA512_Final(digestC, &ctx);
    }
    free(pBytes);

    NSMutableString *out = [NSMutableString stringWithFormat:@"$6$%.*s$", (int)saltLength, salt];
    static const int order[21][3] = {
        {0, 21, 42},
        {22, 43, 1},
        {44, 2, 23},
        {3, 24, 45},
        {25, 46, 4},
        {47, 5, 26},
        {6, 27, 48},
        {28, 49, 7},
        {50, 8, 29},
        {9, 30, 51},
        {31, 52, 10},
        {53, 11, 32},
        {12, 33, 54},
        {34, 55, 13},
        {56, 14, 35},
        {15, 36, 57},
        {37, 58, 16},
        {59, 17, 38},
        {18, 39, 60},
        {40, 61, 19},
        {62, 20, 41}
    };
    for (int i = 0; i < 21; i++) cryptBase64(out, digestC[order[i][0]], digestC[order[i][1]], digestC[order[i][2]], 4);
    cryptBase64(out, 0, 0, digestC[63], 2);
    return strdup(out.UTF8String);
}

NSString *icli_sha512_crypt_salt(void) {
    unsigned char bytes[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) return nil;
    NSMutableString *salt = [NSMutableString string];
    for (int i = 0; i < 16; i++) [salt appendFormat:@"%c", kCryptAlphabet[bytes[i] & 0x3f]];
    return salt;
}
