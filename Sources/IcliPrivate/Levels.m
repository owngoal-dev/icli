#import "IcliPrivate.h"
#import "Settle.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>

// tvOS has no battery: report what UIDevice reports for an unknown one.
double icli_battery_fraction(void) {
#if TARGET_OS_TV
    return -1;
#else
    UIDevice *device = [UIDevice currentDevice];
    device.batteryMonitoringEnabled = YES;
    return device.batteryLevel;
#endif
}

int icli_battery_state(void) {
#if TARGET_OS_TV
    return 0;
#else
    UIDevice *device = [UIDevice currentDevice];
    device.batteryMonitoringEnabled = YES;
    return (int)device.batteryState;
#endif
}

double icli_brightness_get(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
    float (*get)(void) = handle ? dlsym(handle, "BKSDisplayBrightnessGetCurrent") : NULL;
    if (get) return get();
#if TARGET_OS_TV
    return -1;
#else
    return [UIScreen mainScreen].brightness;
#endif
}

static id brightnessClient(void) {
    dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW);
    Class clientClass = NSClassFromString(@"BrightnessSystemClient");
    if (![clientClass instancesRespondToSelector:@selector(setProperty:forKey:)] ||
        ![clientClass instancesRespondToSelector:@selector(copyPropertyForKey:)]) {
        return nil;
    }
    return [[clientClass alloc] init];
}

// A copy-family method returns +1; through a plain objc_msgSend cast ARC
// would take it as +0 and leak it on every call.
typedef id (*CopyProperty)(id, SEL, id) NS_RETURNS_RETAINED;

int icli_auto_brightness(void) {
    id client = brightnessClient();
    id value = client
        ? ((CopyProperty)objc_msgSend)(client, @selector(copyPropertyForKey:), @"DisplayBrightnessAuto")
        : nil;
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : -1;
}

// CoreBrightness takes a committed value as the user's own setting, the way
// Control Center's slider does. A raw backboardd level is pulled back to the
// ambient-light curve within seconds; with auto-brightness on, a committed
// value can still drift as ambient light changes.
static bool setUserBrightness(double value) {
    id client = brightnessClient();
    if (!client) {
        return false;
    }
    NSDictionary *request = @{@"Brightness": @(value), @"Commit": @YES};
    return ((BOOL (*)(id, SEL, id, id))objc_msgSend)(
        client,
        @selector(setProperty:forKey:),
        request,
        @"DisplayBrightness"
    );
}

// backboardd honours BKSDisplayBrightnessSet only from clients holding
// com.apple.backboard.displaybrightness; the request is sent asynchronously,
// so wait before the caller reads the value back.
bool icli_brightness_set(double value) {
    double v = value;
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    if (setUserBrightness(v)) {
        icli_settle(0.3);
        return true;
    }
    void *handle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
    void (*set)(float, int) = handle ? dlsym(handle, "BKSDisplayBrightnessSet") : NULL;
    if (!set) {
        return false;
    }
    set((float)v, 1);
    icli_settle(0.3);
    return true;
}

static id avSystemController(void) {
    Class c = NSClassFromString(@"AVSystemController");
    if (!c) {
        dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_NOW);
        c = NSClassFromString(@"AVSystemController");
    }
    if (!c) {
        dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_NOW);
        c = NSClassFromString(@"AVSystemController");
    }
    if ([c respondsToSelector:@selector(sharedAVSystemController)]) {
        return [c performSelector:@selector(sharedAVSystemController)];
    }
    return nil;
}

static NSString *volumeCategory(const char *category) {
    if (category && category[0]) {
        return [NSString stringWithUTF8String:category];
    }
    return @"Audio/Video";
}

double icli_volume_get(const char *category) {
    id ctl = avSystemController();
    if (![ctl respondsToSelector:@selector(getVolume:forCategory:)]) {
        return -1;
    }
    float vol = 0;
    ((BOOL (*)(id, SEL, float *, NSString *))objc_msgSend)(
        ctl,
        @selector(getVolume:forCategory:),
        &vol,
        volumeCategory(category)
    );
    return vol;
}

bool icli_volume_set(double value, const char *category) {
    id ctl = avSystemController();
    if (!ctl) {
        return false;
    }
    float v = (float)value;
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    NSString *cat = volumeCategory(category);
    SEL sel = @selector(setVolume:forCategory:);
    if (![ctl respondsToSelector:sel]) {
        sel = @selector(setVolumeTo:forCategory:);
    }
    // The setter's return type is not established; the runtime signature says
    // whether there is a BOOL to read.
    NSMethodSignature *sig = [ctl methodSignatureForSelector:sel];
    if (!sig) {
        return false;
    }
    if (sig.methodReturnLength >= sizeof(BOOL)) {
        return ((BOOL (*)(id, SEL, float, NSString *))objc_msgSend)(ctl, sel, v, cat);
    }
    ((void (*)(id, SEL, float, NSString *))objc_msgSend)(ctl, sel, v, cat);
    return true;
}
