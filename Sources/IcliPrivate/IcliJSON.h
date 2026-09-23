#pragma once
#import <Foundation/Foundation.h>
#include <string.h>

/// A malloc'd JSON string for the bridge's `*_json` functions, or NULL when
/// the value cannot be serialized. The caller frees it.
static inline char *icli_json(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : NULL;
}

/// icli_json, or "{}" when the value cannot be serialized.
static inline char *icli_json_or_empty(NSDictionary *value) {
    return icli_json(value) ?: strdup("{}");
}
