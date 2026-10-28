#import "IcliPrivate.h"
#import "IcliJSON.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>

// MobileKeyBag, the client library for the AppleKeyStore keybag. Reading the
// lock state and its counters needs no entitlement (on macOS 27 an unsigned
// tool reads them). Unlocking goes through MKBUnlockDevice, which the keystore
// grants to holders of com.apple.keystore.device: SpringBoard, demod and
// sharingd carry it on iOS 27.0.1, and demod imports the WithACM variant of
// the same call. Every symbol is looked up at runtime.

static int (*pMKBGetDeviceLockState)(CFDictionaryRef);
static CFDictionaryRef (*pMKBGetDeviceLockStateInfo)(CFDictionaryRef);
static int (*pMKBUnlockDevice)(CFDataRef, CFDictionaryRef);
static CFStringRef *pInfoLockState;
static CFStringRef *pInfoFailedAttempts;
static CFStringRef *pInfoBackOff;
static CFStringRef *pInfoPermanentlyBlocked;
static CFStringRef *pInfoShouldWipe;
static CFStringRef *pInfoRecoveryCountdown;

static void keybagInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *mkb = dlopen("/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag", RTLD_NOW);
        if (!mkb) return;
#define SYM(p, name) p = (typeof(p))dlsym(mkb, name)
        SYM(pMKBGetDeviceLockState, "MKBGetDeviceLockState");
        SYM(pMKBGetDeviceLockStateInfo, "MKBGetDeviceLockStateInfo");
        SYM(pMKBUnlockDevice, "MKBUnlockDevice");
        SYM(pInfoLockState, "kMKBInfoLockState");
        SYM(pInfoFailedAttempts, "kMKBInfoFailedAttempts");
        SYM(pInfoBackOff, "kMKBInfoBackOff");
        SYM(pInfoPermanentlyBlocked, "kMKBInfoPermanentlyBlocked");
        SYM(pInfoShouldWipe, "kMKBInfoShouldWipe");
        SYM(pInfoRecoveryCountdown, "kMKBInfoRecoveryCountdown");
#undef SYM
    });
}

static void copyInfo(NSMutableDictionary *out, NSDictionary *info, CFStringRef *key, NSString *name) {
    if (!key || !*key) return;
    id value = info[(__bridge NSString *)*key];
    if ([value isKindOfClass:NSNumber.class]) out[name] = value;
}

char *icli_keybag_info_json(void) {
    keybagInit();
    if (!pMKBGetDeviceLockState) {
        return icli_json(@{@"error": @"MobileKeyBag is unavailable."});
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"lock_state"] = @(pMKBGetDeviceLockState(NULL));
    // Named Get, but whether it follows the Create rule is not documented, so
    // the small dictionary is never released rather than risk a double free.
    CFDictionaryRef raw = pMKBGetDeviceLockStateInfo ? pMKBGetDeviceLockStateInfo(NULL) : NULL;
    if (raw && CFGetTypeID(raw) == CFDictionaryGetTypeID()) {
        NSDictionary *info = (__bridge NSDictionary *)raw;
        copyInfo(out, info, pInfoLockState, @"info_lock_state");
        copyInfo(out, info, pInfoFailedAttempts, @"failed_attempts");
        copyInfo(out, info, pInfoBackOff, @"backoff_seconds");
        copyInfo(out, info, pInfoPermanentlyBlocked, @"permanently_blocked");
        copyInfo(out, info, pInfoShouldWipe, @"should_wipe");
        copyInfo(out, info, pInfoRecoveryCountdown, @"recovery_countdown");
    }
    return icli_json(out);
}

int icli_keybag_unlock(const uint8_t *passcode, size_t length, bool *available) {
    keybagInit();
    *available = pMKBUnlockDevice != NULL;
    if (!pMKBUnlockDevice) return -1;
    // No copy: the keystore reads the bytes in place, and the caller wipes them.
    CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, passcode, (CFIndex)length, kCFAllocatorNull);
    if (!data) return -1;
    int result = pMKBUnlockDevice(data, NULL);
    CFRelease(data);
    return result;
}
