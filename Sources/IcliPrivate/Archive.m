#import "IcliPrivate.h"
#import "ArchiveInternal.h"
#import <Foundation/Foundation.h>
#include <libarchive/archive.h>
#include <libarchive/archive_entry.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static const uint64_t kArchiveByteLimit = 1024ULL * 1024 * 1024;

/// Parent directories must resolve inside the staging root, so an earlier
/// symlink entry cannot redirect a later file outside it.
static BOOL parentInsideRoot(NSString *path, NSString *realRootPrefix) {
    char resolved[PATH_MAX];
    if (!realpath(path.stringByDeletingLastPathComponent.fileSystemRepresentation, resolved)) return NO;
    return [[@(resolved) stringByAppendingString:@"/"] hasPrefix:realRootPrefix];
}

NSString *icli_archive_extract(struct archive *reader, NSString *destination, bool allow_absolute_symlinks, NSMutableArray *entries, NSUInteger *count, uint64_t *total) {
    char resolvedRoot[PATH_MAX];
    if (!realpath(destination.fileSystemRepresentation, resolvedRoot)) return @(strerror(errno));
    NSString *realRootPrefix = [@(resolvedRoot) stringByAppendingString:@"/"];
    // Entry paths are standardized the same way as the root, so the prefix
    // test is textual; symlink escapes are caught by parentInsideRoot.
    NSString *root = destination.stringByStandardizingPath;
    NSString *rootPrefix = [root stringByAppendingString:@"/"];
    NSString *failure = nil;
    struct archive_entry *entry;
    int status = ARCHIVE_OK;
    while (!failure && (status = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
        if (++*count > 50000) { failure = @"archive contains too many entries"; break; }
        const char *rawPath = archive_entry_pathname(entry);
        NSString *relative = rawPath ? [NSString stringWithUTF8String:rawPath] : nil;
        if (!relative.length || relative.isAbsolutePath || [relative.pathComponents containsObject:@".."]) { failure = @"archive contains an unsafe entry path"; break; }
        NSString *path = [[root stringByAppendingPathComponent:relative] stringByStandardizingPath];
        mode_t type = archive_entry_filetype(entry);
        if ([path isEqualToString:root]) { if (type == AE_IFDIR) continue; failure = @"archive entry overwrites the staging root"; break; }
        if (![path hasPrefix:rootPrefix]) { failure = @"archive entry escapes its staging directory"; break; }
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:&error]) { failure = error.localizedDescription; break; }
        if (!parentInsideRoot(path, realRootPrefix)) { failure = @"archive entry escapes its staging directory"; break; }
        if (entries) [entries addObject:@{@"path": relative, @"type": @(type == AE_IFDIR ? "directory" : type == AE_IFLNK ? "symlink" : type == AE_IFREG ? "file" : "other"), @"size": @(archive_entry_size(entry)), @"mode": @(archive_entry_perm(entry) & 07777)}];
        if (type == AE_IFDIR) {
            if (![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@(archive_entry_perm(entry) & 0777 ?: 0755)} error:&error]) failure = error.localizedDescription;
        } else if (type == AE_IFLNK) {
            const char *rawTarget = archive_entry_symlink(entry);
            NSString *target = rawTarget ? [NSString stringWithUTF8String:rawTarget] : nil;
            NSString *resolved = [[path.stringByDeletingLastPathComponent stringByAppendingPathComponent:target ?: @""] stringByStandardizingPath];
            BOOL escapes = target.isAbsolutePath ? !allow_absolute_symlinks : ![resolved hasPrefix:rootPrefix];
            if (!target.length || escapes) { failure = @"archive symlink escapes its staging directory"; break; }
            unlink(path.fileSystemRepresentation);
            if (![NSFileManager.defaultManager createSymbolicLinkAtPath:path withDestinationPath:target error:&error]) failure = error.localizedDescription;
        } else if (type == AE_IFREG || archive_entry_hardlink(entry)) {
            if (archive_entry_hardlink(entry)) { failure = @"archive contains a hard link"; break; }
            if (archive_entry_size(entry) < 0 || (uint64_t)archive_entry_size(entry) > kArchiveByteLimit) { failure = @"archive entry exceeds one GiB"; break; }
            int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, archive_entry_perm(entry) & 0777 ?: 0644);
            if (fd < 0) { failure = @(strerror(errno)); break; }
            char buffer[65536];
            la_ssize_t bytes;
            while ((bytes = archive_read_data(reader, buffer, sizeof(buffer))) > 0) {
                *total += (uint64_t)bytes;
                if (*total > kArchiveByteLimit) { failure = @"archive expands beyond one GiB"; break; }
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
        if (!failure && geteuid() == 0 && type != AE_IFLNK) (void)chown(path.fileSystemRepresentation, (uid_t)archive_entry_uid(entry), (gid_t)archive_entry_gid(entry));
    }
    if (!failure && status != ARCHIVE_EOF) failure = @(archive_error_string(reader) ?: "invalid archive");
    return failure;
}

char *icli_extract_ipa_json(const char *source, const char *destination) {
    struct archive *reader = archive_read_new();
    if (!reader) return strdup("{\"error\":\"archive allocation failed\"}");
    archive_read_support_format_zip(reader);
    NSString *failure = nil;
    NSUInteger count = 0;
    uint64_t total = 0;
    if (archive_read_open_filename(reader, source, 65536) != ARCHIVE_OK) failure = @(archive_error_string(reader) ?: "could not open IPA");
    if (!failure) failure = icli_archive_extract(reader, @(destination), false, nil, &count, &total);
    archive_read_free(reader);
    NSDictionary *result = failure ? @{@"error": [@"IPA: " stringByAppendingString:failure]} : @{@"entries": @(count), @"bytes": @(total)};
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return json ? strndup(json.bytes, json.length) : NULL;
}
