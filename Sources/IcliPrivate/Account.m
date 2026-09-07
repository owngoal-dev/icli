#import "IcliPrivate.h"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/SecRandom.h>
#include <db.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

// SHA-512 crypt ($6$), the scheme the Procursus bootstrap stores in
// /etc/master.passwd. Follows Drepper's specification (5000 rounds).
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
    for (size_t copied = 0; copied < keyLength; copied += 64) memcpy(pBytes + copied, digestP, MIN((size_t)64, keyLength - copied));

    CC_SHA512_Init(&alt);
    for (int i = 0; i < 16 + digestA[0]; i++) CC_SHA512_Update(&alt, salt, (CC_LONG)saltLength);
    CC_SHA512_Final(digestS, &alt);
    unsigned char sBytes[16];
    for (size_t copied = 0; copied < saltLength; copied += 64) memcpy(sBytes + copied, digestS, MIN((size_t)64, saltLength - copied));

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
    static const int order[21][3] = {{0, 21, 42}, {22, 43, 1}, {44, 2, 23}, {3, 24, 45}, {25, 46, 4}, {47, 5, 26}, {6, 27, 48}, {28, 49, 7}, {50, 8, 29}, {9, 30, 51}, {31, 52, 10}, {53, 11, 32}, {12, 33, 54}, {34, 55, 13}, {56, 14, 35}, {15, 36, 57}, {37, 58, 16}, {59, 17, 38}, {18, 39, 60}, {40, 61, 19}, {62, 20, 41}};
    for (int i = 0; i < 21; i++) cryptBase64(out, digestC[order[i][0]], digestC[order[i][1]], digestC[order[i][2]], 4);
    cryptBase64(out, 0, 0, digestC[63], 2);
    return strdup(out.UTF8String);
}

static char *accountJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : NULL;
}

static NSString *randomSalt(void) {
    unsigned char bytes[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) return nil;
    NSMutableString *salt = [NSMutableString string];
    for (int i = 0; i < 16; i++) [salt appendFormat:@"%c", kCryptAlphabet[bytes[i] & 0x3f]];
    return salt;
}

/// Writes `data` to `path` through a sibling temp file, keeping the original mode and owner.
static NSString *replaceFile(NSString *path, NSData *data, struct stat *original) {
    NSString *temporary = [path stringByAppendingFormat:@".icli-%@", NSUUID.UUID.UUIDString];
    int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, original->st_mode & 07777);
    if (fd < 0) return @(strerror(errno));
    NSString *failure = nil;
    if (write(fd, data.bytes, data.length) != (ssize_t)data.length) failure = @(strerror(errno));
    if (!failure && fchown(fd, original->st_uid, original->st_gid) != 0) failure = @(strerror(errno));
    if (!failure && fsync(fd) != 0) failure = @(strerror(errno));
    close(fd);
    if (!failure && rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) != 0) failure = @(strerror(errno));
    if (failure) unlink(temporary.fileSystemRepresentation);
    return failure;
}

/// Rewrites the password field of every record for `user` in a pwd_mkdb hash database.
static NSString *updateHashDatabase(NSString *path, NSString *user, NSString *hash, NSUInteger *updated) {
    struct stat original;
    if (stat(path.fileSystemRepresentation, &original) != 0) return @(strerror(errno));
    NSData *contents = [NSData dataWithContentsOfFile:path];
    if (!contents) return @"database unreadable";
    NSString *temporary = [path stringByAppendingFormat:@".icli-%@", NSUUID.UUID.UUIDString];
    NSString *failure = replaceFile(temporary, contents, &original);
    if (failure) return failure;
    DB *db = dbopen(temporary.fileSystemRepresentation, O_RDWR, 0, DB_HASH, NULL);
    if (!db) { unlink(temporary.fileSystemRepresentation); return [@"dbopen: " stringByAppendingString:@(strerror(errno))]; }
    NSMutableArray *keys = [NSMutableArray array];
    NSMutableArray *values = [NSMutableArray array];
    DBT key, value;
    const char *name = user.UTF8String;
    size_t nameLength = strlen(name);
    for (int flag = R_FIRST; db->seq(db, &key, &value, flag) == 0; flag = R_NEXT) {
        const unsigned char *bytes = value.data;
        // Keys are '1'+name, '2'+record number, '3'+uid (pwd_mkdb writes the ASCII digits).
        unsigned char kind = key.size ? ((unsigned char *)key.data)[0] : 0;
        if (!(kind >= '1' && kind <= '3') || value.size <= nameLength + 1) continue;
        if (memcmp(bytes, name, nameLength) != 0 || bytes[nameLength] != 0) continue;
        const unsigned char *passwordEnd = memchr(bytes + nameLength + 1, 0, value.size - nameLength - 1);
        if (!passwordEnd) continue;
        NSMutableData *record = [NSMutableData dataWithBytes:bytes length:nameLength + 1];
        [record appendBytes:hash.UTF8String length:strlen(hash.UTF8String)];
        [record appendBytes:passwordEnd length:value.size - (size_t)(passwordEnd - bytes)];
        [keys addObject:[NSData dataWithBytes:key.data length:key.size]];
        [values addObject:record];
    }
    for (NSUInteger i = 0; i < keys.count && !failure; i++) {
        DBT k = {.data = (void *)[keys[i] bytes], .size = [keys[i] length]};
        DBT v = {.data = (void *)[values[i] bytes], .size = [values[i] length]};
        if (db->put(db, &k, &v, 0) != 0) failure = @(strerror(errno));
    }
    if (!failure && db->sync(db, 0) != 0) failure = @(strerror(errno));
    if (db->close(db) != 0 && !failure) failure = @(strerror(errno));
    if (!failure && keys.count == 0) failure = @"user has no database record";
    if (!failure && rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) != 0) failure = @(strerror(errno));
    if (failure) unlink(temporary.fileSystemRepresentation);
    *updated = keys.count;
    return failure;
}

char *icli_account_set_password_json(const char *etc_directory, const char *user, const char *password) {
    if (!etc_directory || !user || !password || !*user) return accountJSON(@{@"error": @"invalid account arguments"});
    NSString *etc = @(etc_directory);
    NSString *masterPath = [etc stringByAppendingPathComponent:@"master.passwd"];
    NSString *databasePath = [etc stringByAppendingPathComponent:@"spwd.db"];
    struct stat original;
    if (stat(masterPath.fileSystemRepresentation, &original) != 0) return accountJSON(@{@"error": [@"master.passwd: " stringByAppendingString:@(strerror(errno))]});
    NSString *text = [NSString stringWithContentsOfFile:masterPath encoding:NSUTF8StringEncoding error:nil];
    if (!text) return accountJSON(@{@"error": @"master.passwd unreadable (root required)"});
    NSString *salt = randomSalt();
    char *hashed = salt ? icli_sha512_crypt(password, salt.UTF8String) : NULL;
    if (!hashed) return accountJSON(@{@"error": @"password hashing failed"});
    NSString *hash = @(hashed);
    free(hashed);

    NSMutableArray *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    NSString *prefix = [@(user) stringByAppendingString:@":"];
    NSUInteger matches = 0;
    for (NSUInteger i = 0; i < lines.count; i++) {
        if (![lines[i] hasPrefix:prefix]) continue;
        NSMutableArray *fields = [[lines[i] componentsSeparatedByString:@":"] mutableCopy];
        if (fields.count < 10) return accountJSON(@{@"error": @"master.passwd entry is malformed"});
        fields[1] = hash;
        lines[i] = [fields componentsJoinedByString:@":"];
        matches++;
    }
    if (matches == 0) return accountJSON(@{@"error": [NSString stringWithFormat:@"user not found in master.passwd: %s", user]});
    NSUInteger updated = 0;
    NSString *failure = updateHashDatabase(databasePath, @(user), hash, &updated);
    if (failure) return accountJSON(@{@"error": [@"spwd.db: " stringByAppendingString:failure]});
    failure = replaceFile(masterPath, [[lines componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding], &original);
    if (failure) return accountJSON(@{@"error": [@"master.passwd: " stringByAppendingString:failure], @"spwd_db_updated": @YES});
    return accountJSON(@{@"user": @(user), @"scheme": @"sha512crypt", @"salt": salt, @"master_passwd_entries": @(matches), @"spwd_db_records": @(updated), @"files": @[masterPath, databasePath]});
}
