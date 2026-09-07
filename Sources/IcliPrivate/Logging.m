#import "IcliPrivate.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

// OSLogEventLiveStream is the diagnosticd live stream, not dmesg/history.
// The API was cross-checked against witchan/ios-mcp's MIT logreader.
static id logProperty(id event, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    // Live events are forwarding proxies: respondsToSelector: returns NO for
    // properties that the proxy nevertheless implements through forwarding.
    return ((id (*)(id, SEL))objc_msgSend)(event, selector);
}

static char *logJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : NULL;
}

char *icli_syslog_json(double seconds, const char *process, const char *level, int max_lines) {
    dlopen("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport", RTLD_NOW);
    Class streamClass = NSClassFromString(@"OSLogEventLiveStream");
    id stream = streamClass ? [[streamClass alloc] init] : nil;
    SEL setHandler = NSSelectorFromString(@"setEventHandler:");
    SEL activate = NSSelectorFromString(@"activate");
    SEL invalidate = NSSelectorFromString(@"invalidate");
    if (!stream || ![stream respondsToSelector:setHandler] || ![stream respondsToSelector:activate] || ![stream respondsToSelector:invalidate]) {
        return logJSON(@{@"error": @"unified log stream unavailable"});
    }
    NSMutableArray *entries = [NSMutableArray array];
    NSLock *lock = [NSLock new];
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    NSString *processFilter = process ? @(process) : nil;
    NSString *levelFilter = level ? @(level) : @"all";
    __block BOOL truncated = NO;
    void (^handler)(id) = ^(id event) {
        NSString *message = logProperty(event, @"composedMessage");
        NSString *name = logProperty(event, @"process");
        if (![message isKindOfClass:NSString.class]) return;
        if (processFilter.length && (![name isKindOfClass:NSString.class] || [name rangeOfString:processFilter options:NSCaseInsensitiveSearch].location == NSNotFound)) return;
        SEL typeSelector = NSSelectorFromString(@"logType");
        unsigned long long type = ((unsigned long long (*)(id, SEL))objc_msgSend)(event, typeSelector);
        if ([levelFilter isEqual:@"error"] && type != 0x10 && type != 0x11) return;
        if ([levelFilter isEqual:@"fault"] && type != 0x11) return;
        SEL pidSelector = NSSelectorFromString(@"processIdentifier");
        int pid = ((int (*)(id, SEL))objc_msgSend)(event, pidSelector);
        NSString *severity = @{@0: @"notice", @1: @"info", @2: @"debug", @16: @"error", @17: @"fault"}[@(type)] ?: @"default";
        id date = logProperty(event, @"date");
        [lock lock];
        if (entries.count >= (NSUInteger)max_lines) { truncated = YES; [lock unlock]; return; }
        [entries addObject:@{@"process": name ?: @"", @"pid": @(pid), @"message": message,
            @"subsystem": logProperty(event, @"subsystem") ?: @"", @"category": logProperty(event, @"category") ?: @"",
            @"level": severity, @"date": [date isKindOfClass:NSDate.class] ? [formatter stringFromDate:date] : @""}];
        [lock unlock];
    };
    ((void (*)(id, SEL, id))objc_msgSend)(stream, setHandler, handler);
    ((void (*)(id, SEL))objc_msgSend)(stream, activate);
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + seconds;
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:MIN(0.1, deadline - NSProcessInfo.processInfo.systemUptime)]];
    }
    ((void (*)(id, SEL))objc_msgSend)(stream, invalidate);
    [lock lock];
    NSArray *snapshot = [entries copy];
    BOOL wasTruncated = truncated;
    [lock unlock];
    return logJSON(@{@"entries": snapshot, @"count": @(snapshot.count), @"truncated": @(wasTruncated), @"source": @"unified_log", @"seconds": @(seconds)});
}
