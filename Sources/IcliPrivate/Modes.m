#import "IcliPrivate.h"
#import "IcliJSON.h"
#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import <objc/message.h>
#import <dlfcn.h>

// amfid's Developer Mode service, as vphoned uses it. The request and reply
// are CF dictionaries wrapped by CoreFoundation's XPC bridge; the reply sits
// under "cfreply". Status needs no privilege; amfid checks arming against
// com.apple.private.amfi.developer-mode-control. The iOS SDK marks
// xpc_connection_create_mach_service unavailable, so it is resolved at runtime.
enum { AMFIActionArm = 0, AMFIActionStatus = 2 };

// Both return a new reference, which ARC then owns.
typedef xpc_connection_t (*CreateMachService)(const char *, dispatch_queue_t, uint64_t) __attribute__((ns_returns_retained));
typedef xpc_object_t (*CreateXPCMessage)(CFTypeRef) __attribute__((ns_returns_retained));

char *icli_amfi_developer_mode_json(bool arm) {
    CreateMachService createService = (CreateMachService)dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    CreateXPCMessage toXPC = (CreateXPCMessage)dlsym(RTLD_DEFAULT, "_CFXPCCreateXPCMessageWithCFObject");
    CFTypeRef (*fromXPC)(xpc_object_t) = dlsym(RTLD_DEFAULT, "_CFXPCCreateCFObjectFromXPCMessage");
    if (!createService || !toXPC || !fromXPC) return icli_json(@{@"error": @"The XPC functions for amfid are unavailable."});
    xpc_connection_t connection = createService("com.apple.amfi.xpc", NULL, 0);
    if (!connection) return icli_json(@{@"error": @"Could not connect to amfid."});
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {});
    xpc_connection_resume(connection);
    xpc_object_t message = toXPC((__bridge CFDictionaryRef)@{@"action": @(arm ? AMFIActionArm : AMFIActionStatus)});
    xpc_object_t reply = message ? xpc_connection_send_message_with_reply_sync(connection, message) : nil;
    xpc_connection_cancel(connection);
    if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
        return icli_json(@{@"error": @"amfid did not answer the Developer Mode request."});
    }
    xpc_object_t wrapped = xpc_dictionary_get_value(reply, "cfreply");
    id object = wrapped ? CFBridgingRelease(fromXPC(wrapped)) : nil;
    if (![object isKindOfClass:NSDictionary.class]) return icli_json(@{@"error": @"amfid sent a Developer Mode reply without a result."});
    return icli_json(object);
}

// powerd's Low Power Mode service (com.apple.powerd.lowpowermode), reached
// through LowPowerMode.framework the way Control Center's toggle reaches it.
// powerd accepts clients with com.apple.powerd.lowpowermode.allow.
static id lowPowerModeService(void) {
    dlopen("/System/Library/PrivateFrameworks/LowPowerMode.framework/LowPowerMode", RTLD_NOW);
    Class cls = NSClassFromString(@"_PMLowPowerMode");
    return [cls respondsToSelector:@selector(sharedInstance)] ? ((id (*)(Class, SEL))objc_msgSend)(cls, @selector(sharedInstance)) : nil;
}

int icli_low_power_mode_get(void) {
    id service = lowPowerModeService();
    SEL get = NSSelectorFromString(@"getPowerMode");
    if (![service respondsToSelector:get]) return -1;
    return ((long (*)(id, SEL))objc_msgSend)(service, get) == 1 ? 1 : 0;
}

bool icli_low_power_mode_set(bool enabled) {
    id service = lowPowerModeService();
    SEL set = NSSelectorFromString(@"setPowerMode:fromSource:");
    if (![service respondsToSelector:set]) return false;
    return ((BOOL (*)(id, SEL, long, NSString *))objc_msgSend)(service, set, enabled ? 1 : 0, @"ControlCenter");
}
