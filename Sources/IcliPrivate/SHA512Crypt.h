#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// SHA-512 crypt ($6$, 5000 rounds), the scheme the Procursus bootstrap stores
/// in /etc/master.passwd. The salt is cut to 16 characters, as Drepper's
/// specification says. NULL for a NULL argument or a salt character outside
/// the crypt alphabet; the caller frees the result.
char *_Nullable icli_sha512_crypt(const char *_Nullable key, const char *_Nullable salt);

/// 16 random characters from the crypt alphabet, or nil when the system
/// random source fails.
NSString *_Nullable icli_sha512_crypt_salt(void);

NS_ASSUME_NONNULL_END
