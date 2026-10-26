#import "IcliProbe.h"
#import "IcliProbeBridge.h"

#include <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>

// The probe's JavaScript context. JavaScriptCore is the one scripting runtime
// already on an iOS and a tvOS device, so the probe needs nothing installed.
// It is loaded with dlopen and reached through NSClassFromString, so a
// platform without it still builds and loads, and evaluation there fails with
// "This platform has no JavaScriptCore" instead of evaluating. Ported
// from vphoned's context; proc.run and exit() are left out of icli (see the
// prelude), and a host injects its own capabilities through the api handler.

static JSContext *icli_probe_context;
/// The current evaluation's collected output, or nil while output goes
/// straight to the terminal.
static NSMutableString *icli_probe_output;
static char *(*icli_probe_api_handler)(const char *);

/// What one script may collect before its output stops growing, in UTF-16
/// units: 1 MiB of ASCII. A runaway loop must not take the caller's memory
/// with it.
static const NSUInteger icli_probe_output_limit = 1 << 20;

/// Pull JavaScriptCore into the process and resolve the classes the bridge
/// reaches by Class object. dlopen is idempotent, so this is cheap to repeat.
/// A CLI does not have the framework loaded until something asks for it, which
/// is why availability means "can be loaded", not "already loaded".
bool icli_probe_available(void) {
    if (IcliProbeContextClass && IcliProbeValueClass) return true;
    if (!dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_LAZY | RTLD_GLOBAL)) {
        dlopen("JavaScriptCore.framework/JavaScriptCore", RTLD_LAZY | RTLD_GLOBAL);
    }
    IcliProbeContextClass = NSClassFromString(@"JSContext");
    IcliProbeValueClass = NSClassFromString(@"JSValue");
    return IcliProbeContextClass && IcliProbeValueClass;
}

void icli_probe_set_api_handler(char *(*handler)(const char *request)) {
    icli_probe_api_handler = handler;
}

// MARK: - Output

/// `text`, with what a C string cannot carry made U+FFFD: a NUL, which would
/// end it early, and an unpaired surrogate, the half of an emoji a slice
/// leaves, which gives the whole string no UTF-8 form. Either would lose the
/// output, the value or the error it lands in, and everything after it.
static NSString *icli_probe_c_safe(NSString *text) {
    const char *bytes = text.UTF8String;
    if (bytes && strlen(bytes) == [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) return text;
    return [text stringByReplacingOccurrencesOfString:@"[\\x{0}\\p{Cs}]" withString:@"\uFFFD"
                                              options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
}

static void icli_probe_write(int descriptor, NSString *text) {
    text = icli_probe_c_safe(text);
    if (!text.length) return;
    if (icli_probe_output) {
        // One write can be the runaway, so keep only what fits, cut where a
        // character ends: half a surrogate pair would make the whole buffer
        // unencodable as UTF-8.
        if (icli_probe_output.length >= icli_probe_output_limit) return;
        NSUInteger room = icli_probe_output_limit - icli_probe_output.length;
        if (text.length > room) {
            text = [text substringToIndex:[text rangeOfComposedCharacterSequenceAtIndex:room].location];
        }
        [icli_probe_output appendString:text];
        return;
    }
    FILE *stream = descriptor == 2 ? stderr : stdout;
    fputs(text.UTF8String ?: "", stream);
    fflush(stream);
}

// MARK: - Globals

static void icli_probe_install_files(JSContext *context) {
    context[@"__fs_list"] = ^id(NSString *path) {
        NSError *failure = nil;
        NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path ?: @"" error:&failure];
        if (!names) {
            icli_probe_throw([IcliProbeContextClass currentContext], @"%@", failure.localizedDescription ?: @"Could not list the directory");
            return nil;
        }
        return [names sortedArrayUsingSelector:@selector(compare:)];
    };

    context[@"__fs_read"] = ^id(NSString *path) {
        NSError *failure = nil;
        NSData *data = [NSData dataWithContentsOfFile:path ?: @"" options:0 error:&failure];
        if (!data) {
            icli_probe_throw([IcliProbeContextClass currentContext], @"%@", failure.localizedDescription ?: @"Could not read the file");
            return nil;
        }
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) {
            icli_probe_throw([IcliProbeContextClass currentContext], @"%@ is not UTF-8 text; read it with the files API instead", path);
            return nil;
        }
        return text;
    };

    context[@"__fs_write"] = ^id(NSString *path, NSString *text) {
        NSData *data = [text ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
        NSError *failure = nil;
        if (![data writeToFile:path ?: @"" options:NSDataWritingAtomic error:&failure]) {
            icli_probe_throw([IcliProbeContextClass currentContext], @"%@", failure.localizedDescription ?: @"Could not write the file");
            return nil;
        }
        return @(data.length);
    };

    context[@"__fs_stat"] = ^id(NSString *path) {
        // getFileSystemRepresentation answers NO for a path with no such form,
        // an empty one or one holding a NUL, where fileSystemRepresentation
        // raises and would take the process with it.
        char name[PATH_MAX];
        struct stat info;
        bool named = [path getFileSystemRepresentation:name maxLength:sizeof name];
        if (!named || lstat(name, &info) != 0) {
            int failure = named ? errno : EINVAL;
            icli_probe_throw([IcliProbeContextClass currentContext], @"lstat(%@): %s", path, strerror(failure));
            return nil;
        }
        NSString *kind = @"other";
        switch (info.st_mode & S_IFMT) {
        case S_IFREG: kind = @"file"; break;
        case S_IFDIR: kind = @"directory"; break;
        case S_IFLNK: kind = @"symlink"; break;
        default: break;
        }
        return @{
            @"type": kind,
            @"size": @(info.st_size),
            @"mode": [NSString stringWithFormat:@"%o", info.st_mode & 07777],
            @"uid": @(info.st_uid),
            @"gid": @(info.st_gid),
            @"mtime": @(info.st_mtimespec.tv_sec),
        };
    };
}

/// `request` arrives encoded by the prelude's JSON.stringify, which answers a
/// NaN, a Date or a cycle the way JavaScript does, where NSJSONSerialization
/// would raise and take the process with it. It escapes a lone surrogate too,
/// so the request always has a UTF-8 form.
static void icli_probe_install_api(JSContext *context) {
    context[@"__api"] = ^id(NSString *method, NSString *request) {
        if (!icli_probe_api_handler) {
            icli_probe_throw([IcliProbeContextClass currentContext], @"This probe has no api handler");
            return nil;
        }
        char *reply = icli_probe_api_handler(request.UTF8String);
        if (!reply) {
            icli_probe_throw([IcliProbeContextClass currentContext], @"%@ returned nothing", method);
            return nil;
        }
        NSData *data = [NSData dataWithBytesNoCopy:reply length:strlen(reply) freeWhenDone:YES];
        NSDictionary *object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![object isKindOfClass:[NSDictionary class]]) {
            icli_probe_throw([IcliProbeContextClass currentContext], @"%@ returned a malformed reply", method);
            return nil;
        }
        NSDictionary *failure = object[@"error"];
        if ([failure isKindOfClass:[NSDictionary class]]) {
            icli_probe_throw([IcliProbeContextClass currentContext], @"%@: %@", failure[@"code"] ?: @"error", failure[@"message"] ?: @"failed");
            return nil;
        }
        return object[@"result"] ?: [NSNull null];
    };
}

/// The ergonomic layer, written in the language it serves: a proxy per ObjC
/// object so a script calls methods by name, `console` over the one write
/// primitive, `api` over its primitive with the request encoded here, and
/// `fs` and `sleep` as the primitives installed above under the names a script
/// uses. A method name's underscores become colons (`setValue_forKey_`), or a
/// bare name takes one colon per argument; a name
/// that already has colons is used as it stands. Leading underscores are a
/// private method's own (`_init`, `_setFlag_`), never colons. proc.run and
/// exit() are deliberately absent: the probe runs inline, so exit() would end
/// the caller, and proc.run belongs to the host that spawns `icli probe`,
/// which injects it through the api handler.
static NSString *const icli_probe_prelude =
    @"(function (global) {\n"
    @"  'use strict';\n"
    @"  function describe(value) {\n"
    @"    if (typeof value === 'string') return value;\n"
    @"    if (value === null) return 'null';\n"
    @"    if (value === undefined) return 'undefined';\n"
    @"    if (typeof value === 'function') return String(value);\n"
    @"    if (typeof value === 'object') {\n"
    @"      if (value.objcHandle === true || value.$handle !== undefined) return String(value);\n"
    @"      try { return JSON.stringify(value); } catch (error) { return String(value); }\n"
    @"    }\n"
    @"    return String(value);\n"
    @"  }\n"
    @"  function selectorFor(name, count) {\n"
    @"    if (name.indexOf(':') >= 0) return name;\n"
    @"    var lead = /^_*/.exec(name)[0], rest = name.slice(lead.length);\n"
    @"    if (rest.indexOf('_') >= 0) return lead + rest.replace(/_/g, ':');\n"
    @"    return lead + (count > 0 ? rest + ':'.repeat(count) : rest);\n"
    @"  }\n"
    @"  function unwrap(value) {\n"
    @"    if (value !== null && typeof value === 'object' && value.$handle !== undefined) return value.$handle;\n"
    @"    return value;\n"
    @"  }\n"
    @"  function box(value) {\n"
    @"    if (value !== null && typeof value === 'object' && value.objcHandle === true) return wrap(value);\n"
    @"    return value;\n"
    @"  }\n"
    @"  function wrap(handle) {\n"
    @"    return new Proxy({}, {\n"
    @"      get: function (_, property) {\n"
    @"        if (typeof property === 'symbol') {\n"
    @"          if (property === Symbol.toPrimitive) return function () { return handle.toString(); };\n"
    @"          if (property === Symbol.toStringTag) return handle.className;\n"
    @"          return undefined;\n"
    @"        }\n"
    @"        if (property === '$handle') return handle;\n"
    @"        if (property === '$class') return handle.className;\n"
    @"        if (property === '$isClass') return handle.isClassHandle;\n"
    @"        if (property === '$value') return handle.plainValue();\n"
    @"        if (property === 'toString' || property === 'inspect') {\n"
    @"          return function () { return handle.toString(); };\n"
    @"        }\n"
    @"        return function () {\n"
    @"          var args = Array.prototype.slice.call(arguments).map(unwrap);\n"
    @"          return box(handle.send(selectorFor(property, args.length), args));\n"
    @"        };\n"
    @"      },\n"
    @"    });\n"
    @"  }\n"
    @"  var ObjC = {\n"
    @"    use: function (name) {\n"
    @"      var handle = global.__objc_class(name);\n"
    @"      if (!handle) throw new Error('No ObjC class named ' + name);\n"
    @"      return wrap(handle);\n"
    @"    },\n"
    @"    wrap: box,\n"
    @"    classes: new Proxy({}, {\n"
    @"      get: function (_, name) { return typeof name === 'string' ? ObjC.use(name) : undefined; },\n"
    @"    }),\n"
    @"  };\n"
    @"  function writeLine(descriptor, values) {\n"
    @"    global.__write(descriptor, values.map(describe).join(' ') + '\\n');\n"
    @"  }\n"
    @"  function toList(values) { return Array.prototype.slice.call(values); }\n"
    @"  global.console = {\n"
    @"    log: function () { writeLine(1, toList(arguments)); },\n"
    @"    info: function () { writeLine(1, toList(arguments)); },\n"
    @"    warn: function () { writeLine(2, toList(arguments)); },\n"
    @"    error: function () { writeLine(2, toList(arguments)); },\n"
    @"  };\n"
    @"  global.print = global.console.log;\n"
    @"  global.fs = {\n"
    @"    ls: global.__fs_list, read: global.__fs_read, write: global.__fs_write, stat: global.__fs_stat,\n"
    @"  };\n"
    @"  global.api = function (method, params) {\n"
    @"    if (params === undefined || params === null) params = {};\n"
    @"    else if (Object.prototype.toString.call(params) !== '[object Object]') {\n"
    @"      throw new TypeError('api() params must be an object');\n"
    @"    }\n"
    @"    method = String(method);\n"
    @"    return global.__api(method, JSON.stringify({method: method, params: params}));\n"
    @"  };\n"
    @"  global.sleep = global.__sleep;\n"
    @"  global.ObjC = ObjC;\n"
    @"  global.__describe = describe;\n"
    @"})(this);\n";

static bool icli_probe_start(void) {
    if (icli_probe_context) return true;
    if (!icli_probe_available()) return false;
    // No exception handler of its own: JSC's default leaves an uncaught
    // exception in context.exception, which is where the prelude check below
    // and each evaluation read it.
    JSContext *context = [[IcliProbeContextClass alloc] init];
    if (!context) return false;
    context.name = @"icli-probe";

    context[@"__write"] = ^(double descriptor, NSString *text) {
        icli_probe_write((int)descriptor, text ?: @"");
    };
    context[@"__objc_class"] = ^id(NSString *name) {
        Class owner = name.length ? NSClassFromString(name) : Nil;
        return owner ? [IcliProbeObjCHandle handleFor:owner] : nil;
    };
    context[@"__sleep"] = ^(double milliseconds) {
        if (milliseconds > 0 && milliseconds < 600000) usleep((useconds_t)(milliseconds * 1000));
    };
    icli_probe_install_files(context);
    icli_probe_install_api(context);

    [context evaluateScript:icli_probe_prelude withSourceURL:[NSURL URLWithString:@"icli-probe://prelude.js"]];
    if (context.exception) {
        NSLog(@"icli probe: the prelude failed: %@", [context.exception toString]);
        return false;
    }
    icli_probe_context = context;
    return true;
}

// MARK: - Evaluation

static NSString *icli_probe_describe(JSValue *value) {
    if (!value) return @"undefined";
    JSValue *describe = icli_probe_context[@"__describe"];
    if (describe.isObject) {
        JSValue *text = [describe callWithArguments:@[value]];
        if (text.isString) return [text toString];
    }
    return [value toString] ?: @"undefined";
}

/// An uncaught error, with the stack JSC recorded when there is one: a script
/// on a device cannot be stepped through, so the trace is all there is.
static NSString *icli_probe_describe_exception(JSValue *exception) {
    NSString *message = [exception toString] ?: @"Unknown error";
    if (!exception.isObject) return message;
    JSValue *stack = exception[@"stack"];
    if (!stack.isString) return message;
    NSString *trace = [[stack toString] stringByTrimmingCharactersInSet:
                                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trace.length ? [NSString stringWithFormat:@"%@\n%@", message, trace] : message;
}

char *icli_probe_evaluate(const char *source, char **error, char **output) {
    if (error) *error = NULL;
    if (output) *output = NULL;
    if (!icli_probe_start()) {
        if (error) {
            *error = strdup(icli_probe_available() ? "The probe could not start" : "This platform has no JavaScriptCore");
        }
        return NULL;
    }
    NSMutableString *collected = output ? [NSMutableString string] : nil;
    icli_probe_output = collected;
    icli_probe_context.exception = nil;
    JSValue *value = [icli_probe_context evaluateScript:@(source ?: "")
                                          withSourceURL:[NSURL URLWithString:@"icli-probe://probe.js"]];
    JSValue *exception = icli_probe_context.exception;
    icli_probe_context.exception = nil;
    // Described while output is still collected: describing runs the value's
    // own toString or toJSON, which may print too.
    NSString *described = exception ? nil : icli_probe_describe(value);
    icli_probe_output = nil;
    if (output) *output = strdup(collected.UTF8String ?: "");
    if (exception) {
        if (error) *error = strdup(icli_probe_c_safe(icli_probe_describe_exception(exception)).UTF8String ?: "Unknown error");
        return NULL;
    }
    return strdup(icli_probe_c_safe(described).UTF8String ?: "undefined");
}
