#import "IcliSystemPrivate.h"
#import <Foundation/Foundation.h>
#import <errno.h>
#import <string.h>
#import <sys/sysctl.h>

// The kernel's jetsam bands. memorystatus_control(2) and its priority entry
// are not in the public SDK; both are declared here from XNU's
// bsd/sys/kern_memorystatus.h. The list is readable by root and by a process
// holding com.apple.private.memorystatus; anything else gets EPERM, which is
// reported as a field rather than an error so the rest of the snapshot stands.
extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);

#define MEMORYSTATUS_CMD_GET_PRIORITY_LIST 1

typedef struct {
    int32_t pid;
    int32_t priority;
    uint64_t user_data;
    int32_t limit; // MB
    uint32_t state;
} IcliMemorystatusPriorityEntry;

static char *jetsamJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : NULL;
}

/// Every process in a jetsam band, or nil with `error` describing why not.
static NSArray *priorityList(NSString **error) {
    errno = 0;
    int size = memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST, 0, 0, NULL, 0);
    if (size <= 0) {
        *error = @(strerror(errno ?: EINVAL));
        return nil;
    }
    IcliMemorystatusPriorityEntry *entries = calloc(1, (size_t)size);
    if (!entries) {
        *error = @"priority list allocation failed";
        return nil;
    }
    errno = 0;
    int written = memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST, 0, 0, entries, (size_t)size);
    if (written <= 0) {
        *error = @(strerror(errno ?: EINVAL));
        free(entries);
        return nil;
    }
    NSMutableArray *rows = [NSMutableArray array];
    for (size_t i = 0; i < (size_t)written / sizeof(*entries); i++) {
        char name[256] = {0};
        proc_name(entries[i].pid, name, sizeof(name));
        [rows addObject:@{
            @"pid": @(entries[i].pid),
            @"name": @(name),
            @"priority": @(entries[i].priority),
            @"limit_mb": @(entries[i].limit),
            @"state": @(entries[i].state),
            @"user_data": @(entries[i].user_data),
        }];
    }
    free(entries);
    return rows;
}

/// Zero-initialised, so a 32-bit sysctl read into the low half still reads back
/// correctly; a name this kernel does not have is left out.
static void addSysctl(NSMutableDictionary *memory, NSString *key, const char *name) {
    uint64_t value = 0;
    size_t size = sizeof(value);
    if (sysctlbyname(name, &value, &size, NULL, 0) != 0) return;
    memory[key] = @(value);
}

char *icli_jetsam_json(void) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSString *error = nil;
    NSArray *priorities = priorityList(&error);
    if (priorities) {
        result[@"priorities"] = priorities;
    } else {
        result[@"priorities_error"] = error ?: @"unavailable";
    }
    NSMutableDictionary *memory = [NSMutableDictionary dictionary];
    addSysctl(memory, @"hw_memsize", "hw.memsize");
    addSysctl(memory, @"memorystatus_level", "kern.memorystatus_level");
    addSysctl(memory, @"memorystatus_vm_pressure_level", "kern.memorystatus_vm_pressure_level");
    result[@"memory"] = memory;
    return jetsamJSON(result);
}
