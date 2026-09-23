#import "IcliSystemPrivate.h"
#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import <mach/mach.h>
#import <errno.h>
#import <string.h>

// libxpc selects its launchctl client initialization path when this marker is
// present in the main image, matching the system launchctl executable.
__attribute__((used, section("__TEXT,__launchctl")))
static const uint8_t launchctlImageMarker = 1;

// launchd's bootstrap pipe protocol, as used by launchctl(1). iOS 15 and
// later pass these flattened routine selectors directly to libxpc.
enum {
    RoutinePrintService = 708,
    RoutineLoad = 800,
    RoutineUnload = 801,
    RoutineEnable = 808,
    RoutineDisable = 809,
    RoutineKill = 812,
    RoutineStart = 813,
    RoutineStop = 814,
    RoutineList = 815,
    RoutineRemove = 816,
    RoutineSetEnvironment = 819,
    RoutineGetEnvironment = 820,
    RoutinePrint = 828,
};

struct _os_alloc_once_s { long once; void *ptr; };
extern struct _os_alloc_once_s _os_alloc_once_table[];
struct xpc_global_data {
    uint64_t a;
    uint64_t xpc_flags;
    mach_port_t task_bootstrap_port;
    xpc_object_t xpc_bootstrap_pipe;
};
extern int _xpc_pipe_interface_routine(
    xpc_object_t pipe,
    uint64_t routine,
    xpc_object_t message,
    xpc_object_t *reply,
    uint64_t flags
);
extern const char *xpc_strerror(int error);

static char *launchdJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : NULL;
}

static id objectFromXPC(xpc_object_t value) {
    xpc_type_t type = xpc_get_type(value);
    if (type == XPC_TYPE_STRING) return @(xpc_string_get_string_ptr(value));
    if (type == XPC_TYPE_INT64) return @(xpc_int64_get_value(value));
    if (type == XPC_TYPE_UINT64) return @(xpc_uint64_get_value(value));
    if (type == XPC_TYPE_DOUBLE) return @(xpc_double_get_value(value));
    if (type == XPC_TYPE_BOOL) return @(xpc_bool_get_value(value));
    if (type == XPC_TYPE_ARRAY) {
        NSMutableArray *array = [NSMutableArray array];
        xpc_array_apply(value, ^bool(size_t index, xpc_object_t item) {
            [array addObject:objectFromXPC(item)];
            return true;
        });
        return array;
    }
    if (type == XPC_TYPE_DICTIONARY) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        xpc_dictionary_apply(value, ^bool(const char *key, xpc_object_t item) {
            dict[@(key)] = objectFromXPC(item);
            return true;
        });
        return dict;
    }
    return [NSString stringWithFormat:@"<%s>", xpc_type_get_name(type)];
}

extern uint64_t xpc_user_sessions_get_foreground_uid(uint64_t);

// Domain types: 1 = system, 2 = a user (handle = uid), 7 = resolved from the
// caller, which is what launchctl load/unload send on iOS 15 and later.
enum { DomainSystem = 1, DomainUser = 2, DomainCaller = 7 };

/// Returns 0 or an errno / launchd error code.
static int launchdRoutine(
    uint64_t routine,
    uint64_t domain,
    uint64_t handle,
    xpc_object_t message,
    xpc_object_t *reply
) {
    struct xpc_global_data *global = _os_alloc_once_table[1].ptr;
    if (!global || !global->xpc_bootstrap_pipe) return ENXIO;
    xpc_dictionary_set_uint64(message, "type", domain);
    xpc_dictionary_set_uint64(message, "handle", handle);
    xpc_object_t response = NULL;
    int status = _xpc_pipe_interface_routine(global->xpc_bootstrap_pipe, routine, message, &response, 0);
    if (status == 0 && response) status = (int)xpc_dictionary_get_int64(response, "error");
    if (reply) *reply = response;
    return status;
}

const char *icli_launchd_strerror(int error) {
    return xpc_strerror(error);
}

static NSDictionary *errorsFromReply(xpc_object_t reply) {
    NSMutableDictionary *errors = [NSMutableDictionary dictionary];
    xpc_object_t table = reply ? xpc_dictionary_get_value(reply, "errors") : NULL;
    if (table && xpc_get_type(table) == XPC_TYPE_DICTIONARY) {
        xpc_dictionary_apply(table, ^bool(const char *key, xpc_object_t value) {
            if (xpc_get_type(value) == XPC_TYPE_INT64) {
                int code = (int)xpc_int64_get_value(value);
                errors[@(key)] = @{@"code": @(code), @"message": @(xpc_strerror(code))};
            }
            return true;
        });
    }
    return errors;
}

char *icli_launchd_load_json(const char **paths, int count, bool load, bool override) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t array = xpc_array_create(NULL, 0);
    for (int i = 0; i < count; i++) xpc_array_set_string(array, XPC_ARRAY_APPEND, paths[i]);
    xpc_dictionary_set_value(message, "paths", array);
    xpc_dictionary_set_bool(message, "legacy-load", true);
    xpc_dictionary_set_bool(message, load ? "enable" : "disable", override);
    if (!load) xpc_dictionary_set_bool(message, "no-einprogress", true);
    xpc_object_t reply = NULL;
    int status = launchdRoutine(load ? RoutineLoad : RoutineUnload, DomainCaller, 0, message, &reply);
    return launchdJSON(@{@"status": @(status), @"message": @(xpc_strerror(status)), @"errors": errorsFromReply(reply)});
}

char *icli_launchd_enable_json(const char *label, bool enable) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t names = xpc_array_create(NULL, 0);
    xpc_array_set_string(names, XPC_ARRAY_APPEND, label);
    xpc_dictionary_set_value(message, "names", names);
    xpc_object_t reply = NULL;
    int status = launchdRoutine(enable ? RoutineEnable : RoutineDisable, DomainSystem, 0, message, &reply);
    return launchdJSON(@{@"status": @(status), @"message": @(xpc_strerror(status)), @"errors": errorsFromReply(reply)});
}

/// RoutineList in the system and foreground-user domains. With a label, each
/// domain's record carries that one "service"; without, every "services" entry.
static char *domainListJSON(const char *label) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    uint64_t domains[2][2] = {{DomainSystem, 0}, {DomainUser, xpc_user_sessions_get_foreground_uid(0)}};
    NSString *keys[2] = {@"system", @"user"};
    const char *field = label ? "service" : "services";
    for (int i = 0; i < 2; i++) {
        xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
        if (label) xpc_dictionary_set_string(message, "name", label);
        xpc_object_t reply = NULL;
        int status = launchdRoutine(RoutineList, domains[i][0], domains[i][1], message, &reply);
        xpc_object_t value = status == 0 && reply ? xpc_dictionary_get_value(reply, field) : NULL;
        NSMutableDictionary *record = [@{@"status": @(status), @"message": @(xpc_strerror(status))} mutableCopy];
        if (value && xpc_get_type(value) == XPC_TYPE_DICTIONARY) record[@(field)] = objectFromXPC(value);
        result[keys[i]] = record;
    }
    return launchdJSON(result);
}

/// launchd's view of one label: the system domain record and, because iOS
/// runs LaunchDaemons inside the foreground user's domain behind a system
/// proxy, the user-domain record that carries the real pid. Either may be
/// absent (status 113).
char *icli_launchd_service_json(const char *label) {
    return domainListJSON(label);
}

/// All services visible in the system and foreground-user domains. The raw
/// records are retained so the Swift layer can merge proxy and process state.
char *icli_launchd_services_json(void) {
    return domainListJSON(NULL);
}

/// The system domain's disabled-service overrides: {label: true when disabled}.
char *icli_launchd_disabled_json(void) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    vm_size_t size = 0x100000;
    vm_address_t address = 0;
    if (vm_allocate(mach_task_self(), &address, size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return launchdJSON(@{@"status": @(ENOMEM)});
    xpc_dictionary_set_value(message, "shmem", xpc_shmem_create((void *)address, size));
    xpc_dictionary_set_bool(message, "disabled", true);
    xpc_object_t reply = NULL;
    int status = launchdRoutine(RoutinePrint, DomainSystem, 0, message, &reply);
    NSMutableDictionary *overrides = [NSMutableDictionary dictionary];
    if (status == 0 && reply) {
        uint64_t written = xpc_dictionary_get_uint64(reply, "bytes-written");
        NSString *text = [[NSString alloc] initWithBytes:(void *)address
                                                  length:MIN(written, size)
                                                encoding:NSUTF8StringEncoding] ?: @"";
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSArray *parts = [line componentsSeparatedByString:@"\" => "];
            if (parts.count != 2) continue;
            NSString *name =
                [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\t \""]];
            NSString *state = [parts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            overrides[name] = @([state isEqualToString:@"disabled"]);
        }
    }
    vm_deallocate(mach_task_self(), address, size);
    return launchdJSON(@{@"status": @(status), @"message": @(xpc_strerror(status)), @"disabled": overrides});
}

static int launchdServiceRoutine(uint64_t routine, xpc_object_t message, NSString **domainName) {
    uint64_t domains[2][2] = {{DomainUser, xpc_user_sessions_get_foreground_uid(0)}, {DomainSystem, 0}};
    NSString *domainNames[2] = {@"user", @"system"};
    int status = 113;
    for (int i = 0; i < 2 && status == 113; i++) {
        status = launchdRoutine(routine, domains[i][0], domains[i][1], message, NULL);
        *domainName = domainNames[i];
    }
    return status;
}

static xpc_object_t serviceMessage(const char *label) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "name", label);
    return message;
}

static char *serviceActionJSON(uint64_t routine, xpc_object_t message) {
    NSString *domain = nil;
    int status = launchdServiceRoutine(routine, message, &domain);
    return launchdJSON(@{@"status": @(status), @"message": @(xpc_strerror(status)), @"domain": domain});
}

char *icli_launchd_start_json(const char *label) {
    return serviceActionJSON(RoutineStart, serviceMessage(label));
}

char *icli_launchd_stop_json(const char *label) {
    return serviceActionJSON(RoutineStop, serviceMessage(label));
}

char *icli_launchd_remove_json(const char *label) {
    return serviceActionJSON(RoutineRemove, serviceMessage(label));
}

char *icli_launchd_kill_json(const char *label, int signal) {
    xpc_object_t message = serviceMessage(label);
    xpc_dictionary_set_int64(message, "signal", signal);
    return serviceActionJSON(RoutineKill, message);
}

char *icli_launchd_print_json(const char *label) {
    vm_size_t size = 0x100000;
    vm_address_t address = 0;
    if (vm_allocate(mach_task_self(), &address, size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        return launchdJSON(@{@"status": @(ENOMEM), @"message": @(xpc_strerror(ENOMEM))});
    }
    uint64_t domains[2][2] = {{DomainUser, xpc_user_sessions_get_foreground_uid(0)}, {DomainSystem, 0}};
    NSString *domainNames[2] = {@"user", @"system"};
    int status = 113;
    uint64_t written = 0;
    NSString *domainName = @"system";
    for (int i = 0; i < 2 && status == 113; i++) {
        memset((void *)address, 0, size);
        xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(message, "name", label);
        xpc_dictionary_set_value(message, "shmem", xpc_shmem_create((void *)address, size));
        xpc_object_t reply = NULL;
        status = launchdRoutine(RoutinePrintService, domains[i][0], domains[i][1], message, &reply);
        written = status == 0 && reply ? xpc_dictionary_get_uint64(reply, "bytes-written") : 0;
        domainName = domainNames[i];
    }
    NSString *text = [[NSString alloc] initWithBytes:(void *)address
                                              length:MIN(written, size)
                                            encoding:NSUTF8StringEncoding] ?: @"";
    vm_deallocate(mach_task_self(), address, size);
    return launchdJSON(@{
        @"status": @(status),
        @"message": @(xpc_strerror(status)),
        @"domain": domainName,
        @"description": text
    });
}

char *icli_launchd_getenv_json(const char *key) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "envvar", key);
    xpc_object_t reply = NULL;
    int status = launchdRoutine(RoutineGetEnvironment, DomainCaller, 0, message, &reply);
    const char *value = status == 0 && reply ? xpc_dictionary_get_string(reply, "value") : NULL;
    NSMutableDictionary *result = [@{
        @"status": @(status),
        @"message": @(xpc_strerror(status)),
        @"exists": @(value != NULL)
    } mutableCopy];
    if (value) result[@"value"] = @(value);
    return launchdJSON(result);
}

char *icli_launchd_setenv_json(const char *key, const char *value, bool unset) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t environment = xpc_dictionary_create(NULL, NULL, 0);
    if (unset) {
        xpc_dictionary_set_value(environment, key, xpc_null_create());
    } else {
        xpc_dictionary_set_string(environment, key, value);
    }
    xpc_dictionary_set_value(message, "envvars", environment);
    int status = launchdRoutine(RoutineSetEnvironment, DomainCaller, 0, message, NULL);
    return launchdJSON(@{@"status": @(status), @"message": @(xpc_strerror(status))});
}

/// `launchctl stop` for a system-domain label; launchd relaunches KeepAlive
/// services such as SpringBoard.
int icli_launchd_stop(const char *label) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "name", label);
    return launchdRoutine(RoutineStop, DomainSystem, 0, message, NULL);
}
