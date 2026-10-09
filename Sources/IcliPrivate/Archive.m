#import "IcliPrivate.h"
#import "ArchiveInternal.h"
#import "IcliJSON.h"
#import <Foundation/Foundation.h>
#include <libarchive/archive.h>
#include <libarchive/archive_entry.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#include <xlocale.h>

// Decompression-bomb guards, sized for large games: one entry and the whole
// archive may each expand to 8 GiB, across at most 400,000 entries.
static const uint64_t kArchiveByteLimit = 8ULL * 1024 * 1024 * 1024;
static const NSUInteger kArchiveEntryLimit = 400000;

static NSString *gibibytes(uint64_t bytes) {
    return [NSString stringWithFormat:@"%.2f GiB", (double)bytes / (1024.0 * 1024 * 1024)];
}

static NSString *overLimit(uint64_t bytes) {
    return [NSString stringWithFormat:@"%@, over the %llu GiB limit", gibibytes(bytes), kArchiveByteLimit >> 30];
}

/// Adds the sizes the remaining entries declare to `size`. Their headers are
/// read without their data, so the error can say how far over the limit the
/// archive is.
static uint64_t expandedSize(struct archive *reader, uint64_t size) {
    struct archive_entry *entry;
    while (archive_read_next_header(reader, &entry) == ARCHIVE_OK)
        if (archive_entry_filetype(entry) == AE_IFREG && archive_entry_size(entry) > 0)
            size += (uint64_t)archive_entry_size(entry);
    return size;
}

char *icli_archive_with_utf8_names(char *(^body)(void)) {
    // uselocale, not setlocale: callers such as vphoned read archives on
    // several worker threads at once. Without a UTF-8 locale ASCII names
    // still work, so that case keeps the old behavior instead of failing.
    locale_t previous = uselocale(NULL);
    locale_t base = duplocale(previous);
    locale_t utf8 = base ? newlocale(LC_CTYPE_MASK, "UTF-8", base) : NULL;
    if (!utf8) {
        if (base) freelocale(base);
        return body();
    }
    uselocale(utf8);
    char *result = body();
    uselocale(previous);
    freelocale(utf8);
    return result;
}

/// Parent directories must resolve inside the staging root, so an earlier
/// symlink entry cannot redirect a later file outside it.
static BOOL resolvesInsideRoot(NSString *directory, NSString *realRootPrefix) {
    char resolved[PATH_MAX];
    if (!realpath(directory.fileSystemRepresentation, resolved)) return NO;
    NSString *real = [NSString stringWithUTF8String:resolved];
    return real && [[real stringByAppendingString:@"/"] hasPrefix:realRootPrefix];
}

static BOOL parentInsideRoot(NSString *path, NSString *realRootPrefix) {
    return resolvesInsideRoot(path.stringByDeletingLastPathComponent, realRootPrefix);
}

/// The deepest part of `directory` that already exists must resolve inside
/// the root before any missing part is created, or an earlier symlink entry
/// could have the extractor create directories outside it.
static BOOL existingAncestorInsideRoot(NSString *directory, NSString *realRootPrefix) {
    NSString *existing = directory;
    struct stat info;
    while (existing.length > 1 && lstat(existing.fileSystemRepresentation, &info) != 0)
        existing = existing.stringByDeletingLastPathComponent;
    return resolvesInsideRoot(existing, realRootPrefix);
}

NSDictionary *icli_archive_entry_info(struct archive_entry *entry, NSString *path) {
    mode_t type = archive_entry_filetype(entry);
    return @{
        @"path": path,
        @"type": @(type == AE_IFDIR ? "directory" : type == AE_IFLNK ? "symlink" : type == AE_IFREG ? "file" : "other"),
        @"size": @(archive_entry_size(entry)),
        @"mode": @(archive_entry_perm(entry) & 07777)
    };
}

NSString *icli_archive_extract(
    struct archive *reader,
    NSString *destination,
    bool allow_absolute_symlinks,
    bool skip_mac_metadata,
    NSMutableArray *entries,
    NSUInteger *count,
    uint64_t *total
) {
    char resolvedRoot[PATH_MAX];
    if (!realpath(destination.fileSystemRepresentation, resolvedRoot)) return @(strerror(errno));
    NSString *realRoot = [NSString stringWithUTF8String:resolvedRoot];
    if (!realRoot) return @"staging directory path is not UTF-8";
    NSString *realRootPrefix = [realRoot stringByAppendingString:@"/"];
    // Entry paths are standardized the same way as the root, so the prefix
    // test is textual; symlink escapes are caught by parentInsideRoot.
    NSString *root = destination.stringByStandardizingPath;
    NSString *rootPrefix = [root stringByAppendingString:@"/"];
    NSString *failure = nil;
    struct archive_entry *entry;
    int status = ARCHIVE_OK;
    while (!failure && (status = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
        if (++*count > kArchiveEntryLimit) {
            failure = [NSString stringWithFormat:@"archive contains more than %lu entries", (unsigned long)kArchiveEntryLimit];
            break;
        }
        const char *rawPath = archive_entry_pathname(entry);
        NSString *relative = rawPath ? [NSString stringWithUTF8String:rawPath] : nil;
        if (!relative.length || relative.isAbsolutePath || [relative.pathComponents containsObject:@".."]) {
            failure = @"archive contains an unsafe entry path";
            break;
        }
        NSString *path = [[root stringByAppendingPathComponent:relative] stringByStandardizingPath];
        mode_t type = archive_entry_filetype(entry);
        if (skip_mac_metadata
            && ([relative.pathComponents.firstObject isEqualToString:@"__MACOSX"]
                || (type == AE_IFREG && [relative.lastPathComponent hasPrefix:@"._"])))
            continue;
        if ([path isEqualToString:root]) {
            if (type == AE_IFDIR) continue;
            failure = @"archive entry overwrites the staging root";
            break;
        }
        if (![path hasPrefix:rootPrefix]) { failure = @"archive entry escapes its staging directory"; break; }
        NSError *error = nil;
        if (!existingAncestorInsideRoot(path.stringByDeletingLastPathComponent, realRootPrefix)) {
            failure = @"archive entry escapes its staging directory";
            break;
        }
        if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:&error]) { failure = error.localizedDescription; break; }
        if (!parentInsideRoot(path, realRootPrefix)) {
            failure = @"archive entry escapes its staging directory";
            break;
        }
        if (entries) [entries addObject:icli_archive_entry_info(entry, relative)];
        if (type == AE_IFDIR) {
            if (![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@(archive_entry_perm(entry) & 0777 ?: 0755)} error:&error]) failure = error.localizedDescription;
        } else if (type == AE_IFLNK) {
            const char *rawTarget = archive_entry_symlink(entry);
            NSString *target = rawTarget ? [NSString stringWithUTF8String:rawTarget] : nil;
            NSString *resolved = [[path.stringByDeletingLastPathComponent
                stringByAppendingPathComponent:target ?: @""] stringByStandardizingPath];
            BOOL escapes = target.isAbsolutePath ? !allow_absolute_symlinks : ![resolved hasPrefix:rootPrefix];
            if (!target.length || escapes) { failure = @"archive symlink escapes its staging directory"; break; }
            unlink(path.fileSystemRepresentation);
            if (![NSFileManager.defaultManager createSymbolicLinkAtPath:path withDestinationPath:target error:&error])
                failure = error.localizedDescription;
        } else if (type == AE_IFREG || archive_entry_hardlink(entry)) {
            if (archive_entry_hardlink(entry)) { failure = @"archive contains a hard link"; break; }
            if (archive_entry_size(entry) < 0) { failure = @"archive entry has an invalid size"; break; }
            if ((uint64_t)archive_entry_size(entry) > kArchiveByteLimit) {
                failure = [NSString stringWithFormat:@"archive entry %@ is %@",
                    relative, overLimit((uint64_t)archive_entry_size(entry))];
                break;
            }
            int fd = open(
                path.fileSystemRepresentation,
                O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW,
                archive_entry_perm(entry) & 0777 ?: 0644
            );
            if (fd < 0) { failure = @(strerror(errno)); break; }
            char buffer[65536];
            la_ssize_t bytes;
            // An entry streamed with a data descriptor may declare no size.
            uint64_t declared = *total + (uint64_t)archive_entry_size(entry);
            while ((bytes = archive_read_data(reader, buffer, sizeof(buffer))) > 0) {
                *total += (uint64_t)bytes;
                if (*total > kArchiveByteLimit) {
                    failure = [@"archive expands to " stringByAppendingString:
                        overLimit(expandedSize(reader, MAX(declared, *total)))];
                    break;
                }
                size_t offset = 0;
                while (offset < (size_t)bytes) {
                    ssize_t written = write(fd, buffer + offset, (size_t)bytes - offset);
                    if (written < 0 && errno == EINTR) continue;
                    if (written <= 0) { failure = @(strerror(errno)); break; }
                    offset += (size_t)written;
                }
                if (failure) break;
            }
            if (bytes < 0 && !failure) failure = @(archive_error_string(reader) ?: "archive data could not be read");
            if (close(fd) && !failure) failure = @(strerror(errno));
            if (!failure) chmod(path.fileSystemRepresentation, archive_entry_perm(entry) & 07777 ?: 0644);
        } else { failure = @"archive contains an unsupported special file"; }
        // lchown: a directory entry may name an existing symlink, and chown
        // would follow it to change the owner of whatever it points at.
        if (!failure && geteuid() == 0 && type != AE_IFLNK)
            (void)lchown(
                path.fileSystemRepresentation,
                (uid_t)archive_entry_uid(entry),
                (gid_t)archive_entry_gid(entry)
            );
    }
    if (!failure && status != ARCHIVE_EOF) failure = @(archive_error_string(reader) ?: "invalid archive");
    return failure;
}

static char *extractIPA(const char *source, const char *destination) {
    struct archive *reader = archive_read_new();
    if (!reader) return strdup("{\"error\":\"archive allocation failed\"}");
    archive_read_support_format_zip(reader);
    NSString *failure = nil;
    NSUInteger count = 0;
    uint64_t total = 0;
    if (archive_read_open_filename(reader, source, 65536) != ARCHIVE_OK)
        failure = @(archive_error_string(reader) ?: "could not open IPA");
    if (!failure) failure = icli_archive_extract(reader, @(destination), false, true, nil, &count, &total);
    archive_read_free(reader);
    NSDictionary *result = failure
        ? @{@"error": [@"IPA: " stringByAppendingString:failure]}
        : @{@"entries": @(count), @"bytes": @(total)};
    return icli_json(result);
}

char *icli_extract_ipa_json(const char *source, const char *destination) {
    return icli_archive_with_utf8_names(^{ return extractIPA(source, destination); });
}
