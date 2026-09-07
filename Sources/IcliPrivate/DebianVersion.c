// Debian version parsing and comparison with dpkg semantics
// (epoch, upstream, revision; '~' sorts before everything).
#include "IcliPrivate.h"
#include <errno.h>
#include <limits.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const char *bytes; size_t length; } VersionPart;
typedef struct { unsigned int epoch; VersionPart upstream; VersionPart revision; } ParsedVersion;

static int sign(int value) { return (value > 0) - (value < 0); }
static int isBlank(unsigned char c) { return c == ' ' || c == '\t'; }
static int isDigit(unsigned char c) { return c >= '0' && c <= '9'; }
static int isAlpha(unsigned char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'); }
static unsigned char at(VersionPart part, size_t index) { return index < part.length ? (unsigned char)part.bytes[index] : '\0'; }

static size_t find(VersionPart part, unsigned char c) {
    for (size_t i = 0; i < part.length; i++) if ((unsigned char)part.bytes[i] == c) return i;
    return part.length;
}

static size_t findLast(VersionPart part, unsigned char c) {
    for (size_t i = part.length; i > 0; i--) if ((unsigned char)part.bytes[i - 1] == c) return i - 1;
    return part.length;
}

static int parseVersion(const char *string, ParsedVersion *version) {
    if (!string) return 0;
    while (*string && isBlank((unsigned char)*string)) string++;
    if (!*string) return 0;
    const char *end = string;
    while (*end && !isBlank((unsigned char)*end)) end++;
    for (const char *trailing = end; *trailing; trailing++) if (!isBlank((unsigned char)*trailing)) return 0;

    VersionPart remainder = {string, (size_t)(end - string)};
    size_t colon = find(remainder, ':');
    if (colon != remainder.length) {
        char *epochEnd = NULL;
        errno = 0;
        long epoch = strtol(string, &epochEnd, 10);
        if (epochEnd == string || epochEnd != string + colon || epoch < 0 || epoch > INT_MAX || errno == ERANGE || colon + 1 == remainder.length) return 0;
        version->epoch = (unsigned int)epoch;
        remainder.bytes += colon + 1;
        remainder.length -= colon + 1;
    } else {
        version->epoch = 0;
    }
    size_t hyphen = findLast(remainder, '-');
    if (hyphen != remainder.length) {
        if (hyphen + 1 == remainder.length) return 0;
        version->upstream = (VersionPart){remainder.bytes, hyphen};
        version->revision = (VersionPart){remainder.bytes + hyphen + 1, remainder.length - hyphen - 1};
    } else {
        version->upstream = remainder;
        version->revision = (VersionPart){remainder.bytes + remainder.length, 0};
    }
    if (version->upstream.length == 0 || !isDigit(at(version->upstream, 0))) return 0;
    for (size_t i = 1; i < version->upstream.length; i++) {
        unsigned char c = at(version->upstream, i);
        if (!isDigit(c) && !isAlpha(c) && !strchr(".-+~:", c)) return 0;
    }
    for (size_t i = 0; i < version->revision.length; i++) {
        unsigned char c = at(version->revision, i);
        if (!isDigit(c) && !isAlpha(c) && !strchr(".+~", c)) return 0;
    }
    return 1;
}

static int order(unsigned char c) {
    if (isDigit(c)) return 0;
    if (isAlpha(c)) return c;
    if (c == '~') return -1;
    return c == '\0' ? 0 : c + 256;
}

static int compareParts(VersionPart left, VersionPart right) {
    size_t l = 0, r = 0;
    while (l < left.length || r < right.length) {
        int firstDigitDifference = 0;
        unsigned char lc = at(left, l), rc = at(right, r);
        while ((lc != '\0' && !isDigit(lc)) || (rc != '\0' && !isDigit(rc))) {
            int difference = order(lc) - order(rc);
            if (difference != 0) return sign(difference);
            lc = at(left, ++l);
            rc = at(right, ++r);
        }
        while (lc == '0') lc = at(left, ++l);
        while (rc == '0') rc = at(right, ++r);
        while (isDigit(lc) && isDigit(rc)) {
            if (firstDigitDifference == 0) firstDigitDifference = lc - rc;
            lc = at(left, ++l);
            rc = at(right, ++r);
        }
        if (isDigit(lc)) return 1;
        if (isDigit(rc)) return -1;
        if (firstDigitDifference != 0) return sign(firstDigitDifference);
    }
    return 0;
}

int icli_compare_debian_versions(const char *left, const char *right, int *comparison) {
    ParsedVersion a, b;
    if (!comparison || !parseVersion(left, &a) || !parseVersion(right, &b)) return 0;
    if (a.epoch != b.epoch) { *comparison = a.epoch > b.epoch ? 1 : -1; return 1; }
    *comparison = compareParts(a.upstream, b.upstream);
    if (*comparison == 0) *comparison = compareParts(a.revision, b.revision);
    return 1;
}
