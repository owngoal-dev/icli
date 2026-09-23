#pragma once
#import <Foundation/Foundation.h>
#include <libarchive/archive.h>

/// The listing row for one entry: its path, type name, size and permission bits.
NSDictionary *icli_archive_entry_info(struct archive_entry *entry, NSString *path);

/// Extracts every entry of an opened reader below `destination`, rejecting
/// paths, symlinks, and hard links that would leave it. Returns a failure
/// message or nil; `entries` (optional) receives one dictionary per entry.
NSString *icli_archive_extract(struct archive *reader, NSString *destination, bool allow_absolute_symlinks, NSMutableArray *entries, NSUInteger *count, uint64_t *total);
