#import "IcliPrivate.h"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <unistd.h>
#import <errno.h>
#import <sys/sysctl.h>

// This process uses physical paths. Bootstrap tools may use vroot paths.
// Resolve APIs at runtime so both package layouts contain the same Mach-O.
static NSString *bootstrapPrefix;
static NSString *bootstrapLayout;
static NSString *rootfsPrefix;
static NSString *bootstrapSource;
static char *(*convertJB)(const char *, char *);
static char *(*convertRoot)(const char *, char *);

static char *runtimeJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : NULL;
}

static void resolveBootstrap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *libraries = @[@"@executable_path/../lib/libroot.dylib",
            @"@executable_path/.jbroot/usr/lib/libroot.dylib", @"/var/jb/usr/lib/libroot.dylib", @"/usr/lib/libroot.dylib"];
        for (NSString *path in libraries) {
            void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
            if (!handle) continue;
            const char *(*getJB)(void) = dlsym(handle, "libroot_get_jbroot_prefix");
            const char *(*getRoot)(void) = dlsym(handle, "libroot_get_root_prefix");
            const char *prefix = getJB ? getJB() : NULL;
            if (!prefix) { dlclose(handle); continue; }
            bootstrapPrefix = prefix[0] ? @(prefix) : @"/";
            const char *root = getRoot ? getRoot() : NULL;
            rootfsPrefix = root && root[0] ? @(root) : @"/";
            convertJB = dlsym(handle, "libroot_jbrootpath");
            convertRoot = dlsym(handle, "libroot_rootfspath");
            bootstrapSource = @"libroot";
            break; // Keep the library loaded for the conversion functions.
        }
        if (!bootstrapPrefix) {
            for (NSString *path in @[@"@executable_path/.jbroot/usr/lib/libroothide.dylib", @"@executable_path/../lib/libroothide.dylib"]) {
                void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
                if (!handle) continue;
                const char *(*getJB)(const char *) = dlsym(handle, "jbroot");
                const char *prefix = getJB ? getJB("/") : NULL;
                if (prefix && prefix[0] == '/') {
                    bootstrapPrefix = @(prefix);
                    rootfsPrefix = @"/rootfs";
                    bootstrapSource = @"libroothide";
                }
                dlclose(handle);
                if (bootstrapPrefix) break;
            }
        }
        if (!bootstrapPrefix) {
            char executable[PATH_MAX];
            uint32_t size = sizeof(executable);
            if (_NSGetExecutablePath(executable, &size) == 0) {
                NSString *link = [[@(executable) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@".jbroot"];
                char resolved[PATH_MAX];
                if (realpath(link.fileSystemRepresentation, resolved)) {
                    bootstrapPrefix = @(resolved);
                    rootfsPrefix = @"/rootfs";
                    bootstrapSource = @"executable .jbroot";
                }
            }
        }
        if (!bootstrapPrefix) {
            bootstrapPrefix = access("/var/jb", F_OK) == 0 ? @"/var/jb" : @"/";
            rootfsPrefix = @"/";
            bootstrapSource = @"filesystem fallback";
        }
        while (bootstrapPrefix.length > 1 && [bootstrapPrefix hasSuffix:@"/"]) bootstrapPrefix = [bootstrapPrefix substringToIndex:bootstrapPrefix.length - 1];
        bootstrapLayout = [rootfsPrefix isEqual:@"/rootfs"] || [bootstrapPrefix containsString:@".jbroot-"] ? @"roothide" : ([bootstrapPrefix isEqual:@"/"] ? @"rootful" : @"rootless");
    });
}

char *icli_bootstrap_json(void) {
    resolveBootstrap();
    return runtimeJSON(@{@"jbroot": bootstrapPrefix, @"rootfs": rootfsPrefix, @"layout": bootstrapLayout, @"source": bootstrapSource});
}

char *icli_jbroot_path(const char *path) {
    if (!path) return NULL;
    if (path[0] != '/') return strdup(path);
    resolveBootstrap();
    if (convertJB) return convertJB(path, NULL);
    NSString *input = @(path);
    if ([bootstrapPrefix isEqual:@"/"] || [input isEqual:bootstrapPrefix] || [input hasPrefix:[bootstrapPrefix stringByAppendingString:@"/"]]) return strdup(path);
    return strdup([bootstrapPrefix stringByAppendingPathComponent:input].fileSystemRepresentation);
}

char *icli_rootfs_path(const char *path) {
    if (!path) return NULL;
    if (path[0] != '/') return strdup(path);
    resolveBootstrap();
    if (convertRoot) return convertRoot(path, NULL);
    NSString *input = @(path);
    NSString *jb = [bootstrapPrefix stringByAppendingString:@"/"];
    if (![bootstrapPrefix isEqual:@"/"] && [input hasPrefix:jb]) return strdup([input substringFromIndex:bootstrapPrefix.length].UTF8String);
    if ([rootfsPrefix isEqual:@"/"] || [input hasPrefix:[rootfsPrefix stringByAppendingString:@"/"]]) return strdup(path);
    return strdup([rootfsPrefix stringByAppendingPathComponent:input].fileSystemRepresentation);
}

char *icli_processes_json(void) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0)) return runtimeJSON(@{@"error": @(strerror(errno))});
    length += 64 * sizeof(struct kinfo_proc);
    struct kinfo_proc *processes = calloc(1, length);
    if (!processes) return runtimeJSON(@{@"error": @"process allocation failed"});
    if (sysctl(mib, 3, processes, &length, NULL, 0)) {
        int error = errno; free(processes); return runtimeJSON(@{@"error": @(strerror(error))});
    }
    int (*pidPath)(int, void *, uint32_t) = dlsym(RTLD_DEFAULT, "proc_pidpath");
    NSMutableArray *rows = [NSMutableArray array];
    for (size_t i = 0; i < length / sizeof(struct kinfo_proc); i++) {
        pid_t pid = processes[i].kp_proc.p_pid;
        char path[4096] = {0};
        if (pidPath) pidPath(pid, path, sizeof(path));
        NSString *name = [[NSString alloc] initWithBytes:processes[i].kp_proc.p_comm length:strnlen(processes[i].kp_proc.p_comm, sizeof(processes[i].kp_proc.p_comm)) encoding:NSUTF8StringEncoding];
        [rows addObject:@{@"pid": @(pid), @"name": name ?: @"", @"executable": @(path)}];
    }
    free(processes);
    return runtimeJSON(@{@"processes": rows, @"count": @(rows.count)});
}

/// Kernel boot facts for proving a reboot happened: kern.boottime and the
/// per-boot session UUID that launchd regenerates on a userspace reboot.
char *icli_boot_info_json(void) {
    struct timeval boot = {0};
    size_t size = sizeof(boot);
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (sysctlbyname("kern.boottime", &boot, &size, NULL, 0) == 0) {
        info[@"boot_time"] = @((double)boot.tv_sec + boot.tv_usec / 1e6);
        info[@"uptime_seconds"] = @(NSProcessInfo.processInfo.systemUptime);
    }
    char session[64] = {0};
    size = sizeof(session) - 1;
    if (sysctlbyname("kern.bootsessionuuid", session, &size, NULL, 0) == 0) info[@"boot_session_uuid"] = @(session);
    return runtimeJSON(info);
}

char *icli_file_md5(const char *path) {
    NSData *data = [NSData dataWithContentsOfFile:@(path) options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return NULL;
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(data.bytes, (CC_LONG)data.length, digest); // dpkg's md5sums and Conffiles fields are MD5 by definition.
#pragma clang diagnostic pop
    char hex[CC_MD5_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return strdup(hex);
}
