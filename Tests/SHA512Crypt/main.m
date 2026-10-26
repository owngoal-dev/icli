// Host-side known-answer test for icli's SHA-512 crypt: account set-password
// writes this hash into master.passwd, so a wrong digest locks the account.
#import "SHA512Crypt.h"
#include <stdio.h>
#include <stdlib.h>

static int failures;

static void expect(BOOL condition, NSString *what) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", what.UTF8String);
        failures++;
    }
}

static NSString *hashed(const char *key, const char *salt) {
    char *hash = icli_sha512_crypt(key, salt);
    NSString *result = hash ? @(hash) : nil;
    free(hash);
    return result;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: sha512-crypt-tests <vectors.json>\n");
            return 64;
        }
        NSArray<NSDictionary *> *vectors = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
        expect(vectors.count > 0, @"vectors.json has no vectors");
        for (NSDictionary *vector in vectors) {
            NSString *hash = hashed([vector[@"key"] UTF8String], [vector[@"salt"] UTF8String]);
            expect([hash isEqualToString:vector[@"hash"]],
                   [NSString stringWithFormat:@"salt %@: got %@, expected %@", vector[@"salt"], hash, vector[@"hash"]]);
        }

        expect(hashed(NULL, "salt") == nil, @"NULL key hashes");
        expect(hashed("key", NULL) == nil, @"NULL salt hashes");
        expect(hashed("key", "has$dollar") == nil, @"a salt with $ hashes");
        expect(hashed("key", "has space") == nil, @"a salt outside the crypt alphabet hashes");

        NSString *alphabet = @"./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
        NSCharacterSet *outside = [NSCharacterSet characterSetWithCharactersInString:alphabet].invertedSet;
        NSString *salt = icli_sha512_crypt_salt();
        expect(salt.length == 16 && [salt rangeOfCharacterFromSet:outside].location == NSNotFound,
               [NSString stringWithFormat:@"generated salt %@ is not 16 crypt characters", salt]);
        expect(![salt isEqualToString:icli_sha512_crypt_salt()], @"two generated salts are equal");
        NSString *hash = hashed("alpine", salt.UTF8String);
        NSString *pattern = [NSString stringWithFormat:@"^\\$6\\$%@\\$[./0-9A-Za-z]{86}$", salt];
        expect([hash rangeOfString:pattern options:NSRegularExpressionSearch].location == 0,
               [NSString stringWithFormat:@"hash with a generated salt is malformed: %@", hash]);

        if (failures) return 1;
        printf("sha512 crypt: %lu known answers, invalid input and generated salts\n", (unsigned long)vectors.count);
        return 0;
    }
}
