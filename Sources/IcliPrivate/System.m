#import "IcliPrivate.h"
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <objc/message.h>
#import <unistd.h>

static char *systemJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : NULL;
}

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

bool icli_platform_binary(void) {
    uint32_t flags = 0;
    return csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, sizeof(flags)) == 0 && (flags & 0x04000000 /* CS_PLATFORM_BINARY */) != 0;
}

// reboot3(2) accepts the request; completion is only provable by reconnecting.
extern int reboot3(uint64_t flags, ...);
#define RB2_USERREBOOT 0x2000000000000000ULL
#define RB2_FULLREBOOT 0x8000000000000000ULL

int icli_reboot(bool userspace) {
    errno = 0;
    if (reboot3(userspace ? RB2_USERREBOOT : RB2_FULLREBOOT, 0) == 0) return 0;
    return errno ?: EIO;
}

// FrontBoard's relaunch action: the graceful respring (fade to black,
// restart the render server) that sbreload sends.
enum { RelaunchRestartRenderServer = 1 << 0, RelaunchFadeToBlack = 1 << 2 };

bool icli_springboard_relaunch(void) {
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    Class actionClass = NSClassFromString(@"SBSRelaunchAction");
    Class serviceClass = NSClassFromString(@"FBSSystemService");
    SEL actionSelector = NSSelectorFromString(@"actionWithReason:options:targetURL:");
    SEL sendSelector = NSSelectorFromString(@"sendActions:withResult:");
    if (![actionClass respondsToSelector:actionSelector] || ![serviceClass respondsToSelector:@selector(sharedService)]) return false;
    id action = ((id (*)(Class, SEL, NSString *, NSUInteger, NSURL *))objc_msgSend)(actionClass, actionSelector, @"respring", RelaunchRestartRenderServer | RelaunchFadeToBlack, nil);
    id service = ((id (*)(Class, SEL))objc_msgSend)(serviceClass, @selector(sharedService));
    if (!action || ![service respondsToSelector:sendSelector]) return false;
    ((void (*)(id, SEL, NSSet *, id))objc_msgSend)(service, sendSelector, [NSSet setWithObject:action], nil);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
    return true;
}

// CoreTelephony's per-app data policy: the "Wireless Data" switch that can
// leave a sideloaded app without Wi-Fi or cellular access.
static NSString *const kAlwaysAllow = @"kCTCellularDataUsagePolicyAlwaysAllow";

char *icli_app_network_policy_json(const char *bundle_id, bool repair) {
    if (!bundle_id || !*bundle_id) return systemJSON(@{@"error": @"bundle identifier required"});
    void *handle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_NOW);
    CFTypeRef (*create)(CFAllocatorRef, void *, void *) = handle ? dlsym(handle, "_CTServerConnectionCreate") : NULL;
    int64_t (*copyPolicy)(CFTypeRef, CFStringRef, CFDictionaryRef *) = handle ? dlsym(handle, "_CTServerConnectionCopyCellularUsagePolicy") : NULL;
    int64_t (*setPolicy)(CFTypeRef, CFStringRef, CFDictionaryRef) = handle ? dlsym(handle, "_CTServerConnectionSetCellularUsagePolicy") : NULL;
    if (!create || !copyPolicy || !setPolicy) return systemJSON(@{@"error": @"CoreTelephony usage policy SPI unavailable"});
    CFTypeRef connection = create(kCFAllocatorDefault, NULL, NULL);
    if (!connection) return systemJSON(@{@"error": @"CoreTelephony server connection failed"});
    NSString *bundle = @(bundle_id);
    NSMutableDictionary *result = [@{@"bundle_id": bundle} mutableCopy];
    CFDictionaryRef before = NULL;
    int64_t status = copyPolicy(connection, (__bridge CFStringRef)bundle, &before);
    NSDictionary *policy = before ? CFBridgingRelease(before) : nil;
    if (status != 0) { CFRelease(connection); return systemJSON(@{@"error": [NSString stringWithFormat:@"CoreTelephony policy query failed (status %lld)", status]}); }
    result[@"policy"] = policy ?: @{};
    BOOL allowed = [policy[@"kCTCellularDataUsagePolicy"] isEqual:kAlwaysAllow] && [policy[@"kCTWiFiDataUsagePolicy"] isEqual:kAlwaysAllow];
    result[@"allowed"] = @(allowed);
    if (repair) {
        NSDictionary *wanted = @{@"kCTCellularDataUsagePolicy": kAlwaysAllow, @"kCTWiFiDataUsagePolicy": kAlwaysAllow};
        status = allowed ? 0 : setPolicy(connection, (__bridge CFStringRef)bundle, (__bridge CFDictionaryRef)wanted);
        if (status != 0) { CFRelease(connection); return systemJSON(@{@"error": [NSString stringWithFormat:@"CoreTelephony policy update failed (status %lld)", status], @"policy": policy ?: @{}}); }
        CFDictionaryRef after = NULL;
        status = copyPolicy(connection, (__bridge CFStringRef)bundle, &after);
        NSDictionary *verified = after ? CFBridgingRelease(after) : nil;
        result[@"policy"] = verified ?: @{};
        result[@"changed"] = allowed ? @NO : @YES;
        BOOL nowAllowed = [verified[@"kCTCellularDataUsagePolicy"] isEqual:kAlwaysAllow] && [verified[@"kCTWiFiDataUsagePolicy"] isEqual:kAlwaysAllow];
        result[@"allowed"] = nowAllowed ? @YES : @NO;
    }
    CFRelease(connection);
    return systemJSON(result);
}

// SpringBoard's SBShowNonDefaultSystemApps preference, mediated by cfprefsd
// for the mobile user. SpringBoard reads it at launch.
static CFStringRef const kSpringBoardDomain = CFSTR("com.apple.springboard");
static CFStringRef const kVisibilityKey = CFSTR("SBShowNonDefaultSystemApps");

static CFStringRef preferencesUser(void) {
    return geteuid() == 0 ? CFSTR("mobile") : kCFPreferencesCurrentUser;
}

static NSNumber *visibilityValue(void) {
    CFPropertyListRef value = CFPreferencesCopyValue(kVisibilityKey, kSpringBoardDomain, preferencesUser(), kCFPreferencesAnyHost);
    NSNumber *number = value && CFGetTypeID(value) == CFBooleanGetTypeID() ? CFBridgingRelease(value) : nil;
    if (value && !number) CFRelease(value);
    return number;
}

char *icli_system_apps_visible_json(int desired) {
    NSNumber *before = visibilityValue();
    NSMutableDictionary *result = [@{@"visible": @(before.boolValue), @"configured": before ? @YES : @NO} mutableCopy];
    if (desired < 0) return systemJSON(result);
    BOOL wanted = desired > 0;
    if (before && before.boolValue == wanted) { result[@"changed"] = @NO; return systemJSON(result); }
    CFPreferencesSetValue(kVisibilityKey, wanted ? kCFBooleanTrue : kCFBooleanFalse, kSpringBoardDomain, preferencesUser(), kCFPreferencesAnyHost);
    Boolean synced = CFPreferencesSynchronize(kSpringBoardDomain, preferencesUser(), kCFPreferencesAnyHost);
    NSNumber *after = visibilityValue();
    if (!synced || !after || after.boolValue != wanted) return systemJSON(@{@"error": @"SpringBoard preference did not persist", @"visible": @(after.boolValue)});
    result[@"visible"] = after;
    result[@"configured"] = @YES;
    result[@"changed"] = @YES;
    result[@"requires_respring"] = @YES;
    return systemJSON(result);
}
