#import "IcliPrivate.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>

double icli_battery_fraction(void) {
    icli_private_init();
    UIDevice *device = [UIDevice currentDevice];
    device.batteryMonitoringEnabled = YES;
    return device.batteryLevel;
}

int icli_battery_state(void) {
    icli_private_init();
    UIDevice *device = [UIDevice currentDevice];
    device.batteryMonitoringEnabled = YES;
    return (int)device.batteryState;
}

double icli_brightness_get(void) {
    icli_private_init();
    void *handle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
    float (*get)(void) = handle ? dlsym(handle, "BKSDisplayBrightnessGetCurrent") : NULL;
    if (get) return get();
    return [UIScreen mainScreen].brightness;
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

int icli_auto_brightness(void) {
    id client = brightnessClient();
    id value = client
        ? ((id (*)(id, SEL, id))objc_msgSend)(client, @selector(copyPropertyForKey:), @"DisplayBrightnessAuto")
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
// so spin the run loop before the caller reads the value back.
bool icli_brightness_set(double value) {
    icli_private_init();
    double v = value;
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    if (setUserBrightness(v)) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, false);
        return true;
    }
    void *handle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
    void (*set)(float, int) = handle ? dlsym(handle, "BKSDisplayBrightnessSet") : NULL;
    if (!set) {
        return false;
    }
    set((float)v, 1);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, false);
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
    icli_private_init();
    id ctl = avSystemController();
    if (!ctl) {
        return -1;
    }
    float vol = 0;
    NSString *cat = volumeCategory(category);
    NSMethodSignature *sig = [ctl methodSignatureForSelector:@selector(getVolume:forCategory:)];
    if (!sig) {
        return -1;
    }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:@selector(getVolume:forCategory:)];
    [inv setTarget:ctl];
    float *outp = &vol;
    [inv setArgument:&outp atIndex:2];
    [inv setArgument:&cat atIndex:3];
    [inv invoke];
    return vol;
}

bool icli_volume_set(double value, const char *category) {
    icli_private_init();
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
    NSMethodSignature *sig = [ctl methodSignatureForSelector:sel];
    if (!sig) {
        return false;
    }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:sel];
    [inv setTarget:ctl];
    [inv setArgument:&v atIndex:2];
    [inv setArgument:&cat atIndex:3];
    [inv invoke];
    if (sig.methodReturnLength >= sizeof(BOOL)) {
        BOOL ok = NO;
        [inv getReturnValue:&ok];
        return ok;
    }
    return true;
}
