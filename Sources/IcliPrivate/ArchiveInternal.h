#pragma once
#import <Foundation/Foundation.h>
#include <libarchive/archive.h>

/// Extracts every entry of an opened reader below `destination`, rejecting
/// paths, symlinks, and hard links that would leave it. Returns a failure
/// message or nil; `entries` (optional) receives one dictionary per entry.
NSString *icli_archive_extract(struct archive *reader, NSString *destination, bool allow_absolute_symlinks, NSMutableArray *entries, NSUInteger *count, uint64_t *total);
