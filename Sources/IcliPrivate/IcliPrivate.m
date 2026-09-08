#import "IcliPrivate.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

OBJC_EXTERN UIImage *_UICreateScreenUIImage(void);
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <unistd.h>
#import <math.h>
#import <string.h>
#import <stdlib.h>
#import <sys/sysctl.h>
#import <IOKit/IOKitLib.h>

@interface NSObject (IcliLS)
- (NSString *)applicationIdentifier;
- (NSString *)bundleIdentifier;
- (NSString *)localizedName;
- (NSURL *)bundleURL;
- (NSURL *)dataContainerURL;
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(id)options;
- (BOOL)openURL:(NSURL *)url withOptions:(id)options;
- (void)openApplicationWithBundleID:(NSString *)bundleID;
+ (id)defaultWorkspace;
+ (id)applicationProxyForIdentifier:(NSString *)bundleID;
- (NSArray *)allInstalledApplications;
- (NSArray *)applicationsAvailableForOpeningURL:(NSURL *)url;
- (NSArray *)applicationsAvailableForHandlingURLScheme:(NSString *)scheme;
- (BOOL)installApplication:(NSURL *)url withOptions:(id)options error:(NSError **)error;
- (BOOL)installApplication:(NSURL *)url withOptions:(id)options;
- (BOOL)uninstallApplication:(NSString *)bundleID withOptions:(id)options;
- (BOOL)registerApplication:(NSURL *)url;
- (BOOL)unregisterApplication:(NSURL *)url;
- (BOOL)registerApplicationDictionary:(NSDictionary *)dict;
- (id)operationToOpenResource:(NSURL *)url usingApplication:(NSString *)bundleID userInfo:(id)userInfo;
@end

typedef void *IOHIDEventRef;
typedef void *IOHIDEventSystemClientRef;
typedef uint32_t IOOptionBits;
typedef double IOHIDFloat;

static void *sIOKit;
static void *sSBS;
static void *sUIKit;

static IOHIDEventRef (*pIOHIDEventCreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, Boolean, Boolean, IOOptionBits);
static IOHIDEventRef (*pIOHIDEventCreateDigitizerFingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, Boolean, Boolean, IOOptionBits);
static IOHIDEventRef (*pIOHIDEventCreateKeyboardEvent)(CFAllocatorRef, uint64_t, uint16_t, uint16_t, Boolean, IOOptionBits);
static void (*pIOHIDEventAppendEvent)(IOHIDEventRef, IOHIDEventRef, IOOptionBits);
static void (*pIOHIDEventSetSenderID)(IOHIDEventRef, uint64_t);
static void (*pIOHIDEventSetIntegerValue)(IOHIDEventRef, uint32_t, int);
static IOHIDEventSystemClientRef (*pIOHIDEventSystemClientCreate)(CFAllocatorRef);
static IOHIDEventSystemClientRef (*pIOHIDEventSystemClient)(void);
static void (*pIOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef, IOHIDEventRef);

static mach_port_t (*pSBSSpringBoardServerPort)(void);
static void (*pSBGetScreenLockStatus)(mach_port_t, BOOL *, BOOL *);
static NSString *(*pSBSCopyFrontmostApplicationDisplayIdentifier)(void);
static int (*pSBSLaunchApplicationWithIdentifierAndLaunchOptions)(NSString *, NSDictionary *, NSDictionary *, BOOL);
static bool (*pSBSOpenSensitiveURLAndUnlock)(CFURLRef, char);
static void (*pSBSUndimScreen)(void);
static UIImage *(*p_UICreateScreenUIImage)(void);

static IOHIDEventSystemClientRef sHIDClient;
static id lsWorkspace(void);

// Built-in digitizer sender used by witchan/ios-mcp HIDManager.m
static const uint64_t kBuiltInDigitizerSenderID = 0x8000000817319372ULL;

// IOHIDEventTypes.h / USB HID Usage Tables / Apple Wiki Dev:IOHIDFamily / WebKit IOKitSPI.h
enum {
    kIOHIDEventTypeDigitizer = 11,
    kIOHIDDigitizerEventRange = 1 << 0,
    kIOHIDDigitizerEventTouch = 1 << 1,
    kIOHIDDigitizerEventPosition = 1 << 2,
    kIOHIDDigitizerTransducerTypeFinger = 2,
    kIOHIDDigitizerTransducerTypeHand = 3,
    kIOHIDEventOptionNone = 0,
    kHIDPage_KeyboardOrKeypad = 0x07,
    kHIDPage_Consumer = 0x0C,
    kHIDUsage_Csmr_Power = 0x30,
    kHIDUsage_Csmr_Menu = 0x40,
    kHIDUsage_Csmr_Mute = 0xE2,
    kHIDUsage_Csmr_VolumeIncrement = 0xE9,
    kHIDUsage_Csmr_VolumeDecrement = 0xEA,
};

// IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) + offset of IsDisplayIntegrated (25)
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated ((kIOHIDEventTypeDigitizer << 16) + 25)

typedef enum {
    IcliTouchBegan,
    IcliTouchMoved,
    IcliTouchEnded,
} IcliTouchPhase;

static uint64_t hidNow(void) {
    return mach_absolute_time();
}

static void *load(const char *path) {
    void *h = dlopen(path, RTLD_NOW);
    return h;
}

void icli_private_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sIOKit = load("/System/Library/Frameworks/IOKit.framework/IOKit");
        sSBS = load("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices");
        sUIKit = load("/System/Library/Frameworks/UIKit.framework/UIKit");

#define SYM(h, p, name) p = (typeof(p))dlsym(h, name)
        if (sIOKit) {
            SYM(sIOKit, pIOHIDEventCreateDigitizerEvent, "IOHIDEventCreateDigitizerEvent");
            SYM(sIOKit, pIOHIDEventCreateDigitizerFingerEvent, "IOHIDEventCreateDigitizerFingerEvent");
            SYM(sIOKit, pIOHIDEventCreateKeyboardEvent, "IOHIDEventCreateKeyboardEvent");
            SYM(sIOKit, pIOHIDEventAppendEvent, "IOHIDEventAppendEvent");
            SYM(sIOKit, pIOHIDEventSetSenderID, "IOHIDEventSetSenderID");
            SYM(sIOKit, pIOHIDEventSetIntegerValue, "IOHIDEventSetIntegerValue");
            SYM(sIOKit, pIOHIDEventSystemClientCreate, "IOHIDEventSystemClientCreate");
            SYM(sIOKit, pIOHIDEventSystemClient, "IOHIDEventSystemClient");
            SYM(sIOKit, pIOHIDEventSystemClientDispatchEvent, "IOHIDEventSystemClientDispatchEvent");
        }
        if (sSBS) {
            SYM(sSBS, pSBSSpringBoardServerPort, "SBSSpringBoardServerPort");
            SYM(sSBS, pSBGetScreenLockStatus, "SBGetScreenLockStatus");
            SYM(sSBS, pSBSCopyFrontmostApplicationDisplayIdentifier, "SBSCopyFrontmostApplicationDisplayIdentifier");
            SYM(sSBS, pSBSLaunchApplicationWithIdentifierAndLaunchOptions, "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
            SYM(sSBS, pSBSOpenSensitiveURLAndUnlock, "SBSOpenSensitiveURLAndUnlock");
            SYM(sSBS, pSBSUndimScreen, "SBSUndimScreen");
        }
        if (sUIKit) {
            SYM(sUIKit, p_UICreateScreenUIImage, "_UICreateScreenUIImage");
        }
#undef SYM
        if (pIOHIDEventSystemClientCreate) {
            sHIDClient = pIOHIDEventSystemClientCreate(kCFAllocatorDefault);
        } else if (pIOHIDEventSystemClient) {
            sHIDClient = pIOHIDEventSystemClient();
        }
    });
}

static bool notifyFlag(const char *name) {
    int token = 0;
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) {
        return false;
    }
    uint64_t state = 0;
    notify_get_state(token, &state);
    notify_cancel(token);
    return state != 0;
}

IcliLockStatus icli_lock_status(void) {
    icli_private_init();
    IcliLockStatus st = {false, false, false};
    st.locked = notifyFlag("com.apple.springboard.lockstate");
    st.screen_off = notifyFlag("com.apple.springboard.hasBlankedScreen");
    if (pSBSSpringBoardServerPort && pSBGetScreenLockStatus) {
        BOOL locked = NO;
        BOOL passcode = NO;
        pSBGetScreenLockStatus(pSBSSpringBoardServerPort(), &locked, &passcode);
        st.locked = st.locked || locked;
        st.passcode_enabled = passcode;
    }
    return st;
}

static int parseRotationDegrees(id value) {
    NSString *text = [value description];
    if ([text containsString:@"270"]) {
        return 270;
    }
    if ([text containsString:@"180"]) {
        return 180;
    }
    if ([text containsString:@"90"]) {
        return 90;
    }
    return 0;
}

// CLI UIScreen.bounds is the process interface orientation (often portrait).
// CADisplay reports the compositor's current pixel size and native/current rotation.
static IcliScreenMetrics compositorMetrics(void) {
    IcliScreenMetrics m = {0, 0, 1, 0};
    UIScreen *screen = [UIScreen mainScreen];
    if (screen) {
        m.width = screen.bounds.size.width;
        m.height = screen.bounds.size.height;
        m.scale = screen.scale > 0 ? screen.scale : 1;
        m.orientation = (int)[[UIDevice currentDevice] orientation];
    }
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    Class displayClass = NSClassFromString(@"CADisplay");
    if (![displayClass respondsToSelector:@selector(mainDisplay)]) {
        return m;
    }
    id display = [displayClass performSelector:@selector(mainDisplay)];
    if (!display) {
        return m;
    }
    @try {
        id scaleValue = [display valueForKey:@"pointScale"];
        if ([scaleValue respondsToSelector:@selector(doubleValue)] && [scaleValue doubleValue] >= 1) {
            m.scale = [scaleValue doubleValue];
        }
    } @catch (NSException *ex) {
        (void)ex;
    }
    @try {
        NSValue *boundsValue = [display valueForKey:@"bounds"];
        CGRect pixels = [boundsValue CGRectValue];
        if (pixels.size.width > 1 && pixels.size.height > 1 && m.scale >= 1) {
            m.width = pixels.size.width / m.scale;
            m.height = pixels.size.height / m.scale;
        }
    } @catch (NSException *ex) {
        (void)ex;
    }
    @try {
        m.orientation = parseRotationDegrees([display valueForKey:@"currentOrientation"]);
    } @catch (NSException *ex) {
        (void)ex;
    }
    return m;
}

static int nativeToCurrentRotation(void) {
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    Class displayClass = NSClassFromString(@"CADisplay");
    if (![displayClass respondsToSelector:@selector(mainDisplay)]) {
        return 0;
    }
    id display = [displayClass performSelector:@selector(mainDisplay)];
    if (!display) {
        return 0;
    }
    int native = 0;
    int current = 0;
    @try {
        native = parseRotationDegrees([display valueForKey:@"nativeOrientation"]);
    } @catch (NSException *ex) {
        (void)ex;
    }
    @try {
        current = parseRotationDegrees([display valueForKey:@"currentOrientation"]);
    } @catch (NSException *ex) {
        (void)ex;
    }
    int delta = native - current;
    while (delta < 0) {
        delta += 360;
    }
    while (delta >= 360) {
        delta -= 360;
    }
    return delta;
}

IcliScreenMetrics icli_screen_metrics(void) {
    icli_private_init();
    return compositorMetrics();
}

// UIInterfaceOrientation for a CADisplay rotation: landscape-left (90) is
// UIInterfaceOrientationLandscapeLeft (4), landscape-right (270) is 3.
static int uiInterfaceOrientationForDegrees(int degrees) {
    switch (degrees) {
    case 90:
        return 4;
    case 180:
        return 2;
    case 270:
        return 3;
    default:
        return 1;
    }
}

static id axSpringBoardServer(void) {
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_NOW);
    Class cls = NSClassFromString(@"AXSpringBoardServer");
    if ([cls respondsToSelector:@selector(server)]) {
        return [cls performSelector:@selector(server)];
    }
    return nil;
}

// AXSpringBoardServer -setOrientation: is the AssistiveTouch "Rotate Screen"
// path; SpringBoard applies it to the foreground app. The caller reads back.
static bool setCompositorOrientation(int degrees) {
    id server = axSpringBoardServer();
    if (![server respondsToSelector:@selector(setOrientation:)]) {
        return false;
    }
    ((void (*)(id, SEL, long))objc_msgSend)(server, @selector(setOrientation:), uiInterfaceOrientationForDegrees(degrees));
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, false);
    return true;
}

IcliRotation icli_rotation_get(void) {
    icli_private_init();
    IcliScreenMetrics metrics = compositorMetrics();
    IcliRotation rotation = {0, 0, false};
    rotation.degrees = metrics.orientation;
    rotation.device_orientation = (int)[[UIDevice currentDevice] orientation];
    rotation.locked = notifyFlag("com.apple.springboard.orientationlock");
    void *ax = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
    Boolean (*axGet)(void) = ax ? dlsym(ax, "AXSOrientationLockEnabled") : NULL;
    if (!axGet) {
        axGet = ax ? dlsym(ax, "_AXSOrientationLockEnabled") : NULL;
    }
    if (axGet) {
        rotation.locked = rotation.locked || axGet();
    }
    id server = axSpringBoardServer();
    if ([server respondsToSelector:@selector(isOrientationLocked)]) {
        NSMethodSignature *sig = [server methodSignatureForSelector:@selector(isOrientationLocked)];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:@selector(isOrientationLocked)];
        [inv setTarget:server];
        [inv invoke];
        BOOL locked = NO;
        [inv getReturnValue:&locked];
        rotation.locked = rotation.locked || locked;
    }
    return rotation;
}

bool icli_rotation_set(int degrees) {
    icli_private_init();
    int normalized = degrees % 360;
    if (normalized < 0) {
        normalized += 360;
    }
    if (normalized != 0 && normalized != 90 && normalized != 180 && normalized != 270) {
        return false;
    }
    return setCompositorOrientation(normalized);
}

bool icli_rotation_lock_set(bool locked) {
    icli_private_init();
    bool ok = false;
    id server = axSpringBoardServer();
    if ([server respondsToSelector:@selector(setOrientationLocked:)]) {
        NSMethodSignature *sig = [server methodSignatureForSelector:@selector(setOrientationLocked:)];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:@selector(setOrientationLocked:)];
            [inv setTarget:server];
            BOOL value = locked;
            [inv setArgument:&value atIndex:2];
            [inv invoke];
            ok = true;
        }
    }
    void *bks = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
    void (*lockFn)(void) = bks ? dlsym(bks, "BKSHIDServicesLockOrientation") : NULL;
    void (*unlockFn)(void) = bks ? dlsym(bks, "BKSHIDServicesUnlockOrientation") : NULL;
    if (locked && lockFn) {
        lockFn();
        ok = true;
    } else if (!locked && unlockFn) {
        unlockFn();
        ok = true;
    }
    void *ax = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
    void (*axSet)(Boolean) = ax ? dlsym(ax, "AXSOrientationLockSetEnabled") : NULL;
    if (!axSet) {
        axSet = ax ? dlsym(ax, "_AXSOrientationLockSetEnabled") : NULL;
    }
    if (axSet) {
        axSet(locked);
        ok = true;
    }
    int token = 0;
    if (notify_register_check("com.apple.springboard.orientationlock", &token) == NOTIFY_STATUS_OK) {
        notify_set_state(token, locked ? 1 : 0);
        notify_post("com.apple.springboard.orientationlock");
        notify_cancel(token);
        ok = true;
    }
    return ok;
}

static UIImage *screenshotViaRenderServer(void) {
    void *iosurface = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    void *quartz = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    if (!iosurface || !quartz) {
        return nil;
    }
    typedef void *IOSurfaceRef;
    IOSurfaceRef (*pCreate)(CFDictionaryRef) = dlsym(iosurface, "IOSurfaceCreate");
    void *(*pBase)(IOSurfaceRef) = dlsym(iosurface, "IOSurfaceGetBaseAddress");
    size_t (*pBytesPerRow)(IOSurfaceRef) = dlsym(iosurface, "IOSurfaceGetBytesPerRow");
    kern_return_t (*pLock)(IOSurfaceRef, uint32_t, uint32_t *) = dlsym(iosurface, "IOSurfaceLock");
    kern_return_t (*pUnlock)(IOSurfaceRef, uint32_t, uint32_t *) = dlsym(iosurface, "IOSurfaceUnlock");
    void (*pRender)(mach_port_t, CFStringRef, IOSurfaceRef, int, int) = dlsym(quartz, "CARenderServerRenderDisplay");
    CFStringRef *pWidth = dlsym(iosurface, "kIOSurfaceWidth");
    CFStringRef *pHeight = dlsym(iosurface, "kIOSurfaceHeight");
    CFStringRef *pBPE = dlsym(iosurface, "kIOSurfaceBytesPerElement");
    CFStringRef *pBPR = dlsym(iosurface, "kIOSurfaceBytesPerRow");
    CFStringRef *pFmt = dlsym(iosurface, "kIOSurfacePixelFormat");
    if (!pCreate || !pRender || !pBase || !pWidth) {
        return nil;
    }
    IcliScreenMetrics m = icli_screen_metrics();
    int width = (int)(m.width * m.scale);
    int height = (int)(m.height * m.scale);
    if (width <= 0 || height <= 0) {
        return nil;
    }
    NSDictionary *props = @{
        (__bridge id)*pWidth: @(width),
        (__bridge id)*pHeight: @(height),
        (__bridge id)*pBPE: @4,
        (__bridge id)*pBPR: @(width * 4),
        (__bridge id)*pFmt: @(0x42475241),
    };
    IOSurfaceRef surface = pCreate((__bridge CFDictionaryRef)props);
    if (!surface) {
        return nil;
    }
    if (pLock) {
        pLock(surface, 0, NULL);
    }
    pRender(0, CFSTR("LCD"), surface, 0, 0);
    if (pUnlock) {
        pUnlock(surface, 0, NULL);
    }
    void *base = pBase(surface);
    size_t bpr = pBytesPerRow ? pBytesPerRow(surface) : (size_t)width * 4;
    if (!base) {
        CFRelease(surface);
        return nil;
    }
    NSData *pixels = [NSData dataWithBytes:base length:bpr * (size_t)height];
    CFRelease(surface);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGImageRef cg = CGImageCreate(width, height, 8, 32, bpr, space,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
        provider, NULL, true, kCGRenderingIntentDefault);
    UIImage *image = cg ? [UIImage imageWithCGImage:cg scale:m.scale orientation:UIImageOrientationUp] : nil;
    if (cg) {
        CGImageRelease(cg);
    }
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    return image;
}

static UIImage *rotateCGImage(CGImageRef src, int degrees) {
    if (!src) {
        return nil;
    }
    if (degrees != 90 && degrees != 180 && degrees != 270) {
        return [UIImage imageWithCGImage:src scale:1 orientation:UIImageOrientationUp];
    }
    size_t width = CGImageGetWidth(src);
    size_t height = CGImageGetHeight(src);
    size_t destWidth = (degrees == 180) ? width : height;
    size_t destHeight = (degrees == 180) ? height : width;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(destWidth, destHeight), YES, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (degrees == 90) {
        CGContextTranslateCTM(ctx, destWidth, 0);
        CGContextRotateCTM(ctx, M_PI_2);
    } else if (degrees == 270) {
        CGContextTranslateCTM(ctx, 0, destHeight);
        CGContextRotateCTM(ctx, -M_PI_2);
    } else {
        CGContextTranslateCTM(ctx, destWidth, destHeight);
        CGContextRotateCTM(ctx, M_PI);
    }
    CGContextTranslateCTM(ctx, 0, (degrees == 180) ? height : width);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), src);
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out;
}

static UIImage *rawScreenImage(void) {
    UIImage *image = _UICreateScreenUIImage();
    if (!image && p_UICreateScreenUIImage) {
        image = p_UICreateScreenUIImage();
    }
    if (!image) {
        image = screenshotViaRenderServer();
    }
    return image;
}

static UIImage *orientedScreenImage(void) {
    UIImage *raw = rawScreenImage();
    if (!raw) {
        return nil;
    }
    int degrees = nativeToCurrentRotation();
    if (degrees == 90 || degrees == 180 || degrees == 270) {
        UIImage *rotated = rotateCGImage(raw.CGImage, degrees);
        if (rotated) {
            return rotated;
        }
    }
    if (raw.imageOrientation == UIImageOrientationUp) {
        return raw;
    }
    UIGraphicsBeginImageContextWithOptions(raw.size, YES, raw.scale);
    [raw drawInRect:CGRectMake(0, 0, raw.size.width, raw.size.height)];
    UIImage *baked = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return baked ?: raw;
}

bool icli_screenshot_jpeg(const char *path, float quality, int max_bytes, bool native_resolution) {
    icli_private_init();
    if (!path) {
        return false;
    }
    UIImage *image = orientedScreenImage();
    if (!image) {
        return false;
    }
    if (!native_resolution) {
        IcliScreenMetrics metrics = icli_screen_metrics();
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(metrics.width, metrics.height), YES, 1);
        [image drawInRect:CGRectMake(0, 0, metrics.width, metrics.height)];
        image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (!image) return false;
    }
    float q = quality > 0 ? quality : 0.7f;
    NSData *data = UIImageJPEGRepresentation(image, q);
    while (data.length == 0 && q > 0.2f) {
        q -= 0.1f;
        data = UIImageJPEGRepresentation(image, q);
    }
    if (max_bytes > 0) {
        while (data.length > (NSUInteger)max_bytes && q > 0.15f) {
            q -= 0.1f;
            data = UIImageJPEGRepresentation(image, q);
        }
    }
    if (data.length == 0) {
        return false;
    }
    return [data writeToFile:[NSString stringWithUTF8String:path] atomically:YES];
}

static bool dispatchHID(IOHIDEventRef event) {
    if (!event || !sHIDClient || !pIOHIDEventSystemClientDispatchEvent) {
        if (event) {
            CFRelease(event);
        }
        return false;
    }
    if (pIOHIDEventSetSenderID) {
        pIOHIDEventSetSenderID(event, kBuiltInDigitizerSenderID);
    }
    pIOHIDEventSystemClientDispatchEvent(sHIDClient, event);
    CFRelease(event);
    return true;
}

static void normalizePoint(double x, double y, double *nx, double *ny) {
    IcliScreenMetrics m = icli_screen_metrics();
    double width = m.width > 1 ? m.width : 1;
    double height = m.height > 1 ? m.height : 1;
    *nx = x / width;
    *ny = y / height;
}

static IOHIDEventRef createDigitizerEvent(double x, double y, IcliTouchPhase phase, uint64_t timestamp) {
    if (!pIOHIDEventCreateDigitizerEvent) {
        return NULL;
    }
    uint32_t mask;
    Boolean range;
    Boolean isTouch;
    switch (phase) {
    case IcliTouchBegan:
        mask = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch;
        range = YES;
        isTouch = YES;
        break;
    case IcliTouchMoved:
        mask = kIOHIDDigitizerEventPosition;
        range = YES;
        isTouch = YES;
        break;
    case IcliTouchEnded:
        mask = kIOHIDDigitizerEventTouch;
        range = NO;
        isTouch = NO;
        break;
    default:
        return NULL;
    }
    double nx, ny;
    normalizePoint(x, y, &nx, &ny);
    IOHIDEventRef parent = pIOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, timestamp, kIOHIDDigitizerTransducerTypeHand,
        0, 0, mask, 0,
        0, 0, 0, 0, 0,
        range, isTouch, kIOHIDEventOptionNone);
    if (!parent) {
        return NULL;
    }
    if (pIOHIDEventSetIntegerValue) {
        pIOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    }
    if (pIOHIDEventCreateDigitizerFingerEvent && pIOHIDEventAppendEvent) {
        IOHIDEventRef finger = pIOHIDEventCreateDigitizerFingerEvent(
            kCFAllocatorDefault, timestamp, 0, 2, mask,
            nx, ny, 0, 0, 0,
            range, isTouch, kIOHIDEventOptionNone);
        if (finger) {
            pIOHIDEventAppendEvent(parent, finger, 0);
            CFRelease(finger);
        }
    }
    return parent;
}

static bool hidTouch(double x, double y, IcliTouchPhase phase) {
    icli_private_init();
    return dispatchHID(createDigitizerEvent(x, y, phase, hidNow()));
}

bool icli_hid_tap(double x, double y) {
    if (!hidTouch(x, y, IcliTouchBegan)) return false;
    usleep(50000);
    return hidTouch(x, y, IcliTouchEnded);
}

bool icli_hid_double_tap(double x, double y, double interval) {
    if (!icli_hid_tap(x, y)) return false;
    usleep((useconds_t)(interval * 1000000));
    return icli_hid_tap(x, y);
}

bool icli_hid_long_press(double x, double y, double seconds) {
    if (!hidTouch(x, y, IcliTouchBegan)) return false;
    usleep((useconds_t)(seconds * 1000000));
    return hidTouch(x, y, IcliTouchEnded);
}

bool icli_hid_drag(const double *xs, const double *ys, int count, double hold, double seconds, int steps) {
    if (!xs || !ys || count < 2 || steps < count - 1) return false;
    if (!hidTouch(xs[0], ys[0], IcliTouchBegan)) return false;
    usleep((useconds_t)(hold * 1000000));
    for (int segment = 0; segment < count - 1; segment++) {
        int samples = steps / (count - 1) + (segment < steps % (count - 1) ? 1 : 0);
        for (int step = 1; step <= samples; step++) {
            double t = (double)step / samples;
            double x = xs[segment] + (xs[segment + 1] - xs[segment]) * t;
            double y = ys[segment] + (ys[segment + 1] - ys[segment]) * t;
            if (!hidTouch(x, y, IcliTouchMoved)) { hidTouch(x, y, IcliTouchEnded); return false; }
            usleep((useconds_t)(seconds * 1000000 / steps));
        }
    }
    return hidTouch(xs[count - 1], ys[count - 1], IcliTouchEnded);
}

bool icli_hid_swipe(double x1, double y1, double x2, double y2, double seconds, int steps) {
    double xs[] = {x1, x2}, ys[] = {y1, y2};
    return icli_hid_drag(xs, ys, 2, 0, seconds, steps);
}

bool icli_hid_key(uint16_t usage_page, uint16_t usage, bool down) {
    icli_private_init();
    if (!pIOHIDEventCreateKeyboardEvent) return false;
    IOHIDEventRef event = pIOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, hidNow(), usage_page, usage, down, 0);
    if (event && pIOHIDEventSetIntegerValue) pIOHIDEventSetIntegerValue(event, 4, 1);
    return dispatchHID(event);
}

bool icli_hid_text(const char *text) {
    icli_private_init();
    if (!text) return false;
    IOHIDEventRef (*createUnicode)(CFAllocatorRef, uint64_t, const uint8_t *, uint32_t, uint32_t, IOOptionBits) = sIOKit ? dlsym(sIOKit, "IOHIDEventCreateUnicodeEvent") : NULL;
    if (!createUnicode) return false;
    NSData *payload = [@(text) dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    if (!payload.length || payload.length > UINT32_MAX) return false;
    IOHIDEventRef event = createUnicode(kCFAllocatorDefault, hidNow(), payload.bytes, (uint32_t)payload.length, 1, 0);
    if (event && pIOHIDEventSetIntegerValue) pIOHIDEventSetIntegerValue(event, 4, 1);
    return dispatchHID(event);
}

bool icli_hid_button(const char *name) {
    if (!name) {
        return false;
    }
    uint16_t page = kHIDPage_Consumer;
    uint16_t usage = 0;
    if (strcmp(name, "home") == 0) {
        usage = kHIDUsage_Csmr_Menu;
    } else if (strcmp(name, "power") == 0) {
        usage = kHIDUsage_Csmr_Power;
    } else if (strcmp(name, "volume-up") == 0) {
        usage = kHIDUsage_Csmr_VolumeIncrement;
    } else if (strcmp(name, "volume-down") == 0) {
        usage = kHIDUsage_Csmr_VolumeDecrement;
    } else if (strcmp(name, "mute") == 0) {
        usage = kHIDUsage_Csmr_Mute;
    } else {
        return false;
    }
    if (!icli_hid_key(page, usage, true)) {
        return false;
    }
    usleep(100000);
    return icli_hid_key(page, usage, false);
}

bool icli_launch_app(const char *bundle_id) {
    icli_private_init();
    if (!bundle_id) {
        return false;
    }
    NSString *bid = [NSString stringWithUTF8String:bundle_id];
    if (pSBSLaunchApplicationWithIdentifierAndLaunchOptions) {
        int rc = pSBSLaunchApplicationWithIdentifierAndLaunchOptions(bid, nil, nil, NO);
        if (rc == 0) {
            return true;
        }
    }
    id ws = lsWorkspace();
    if (ws && [ws respondsToSelector:@selector(openApplicationWithBundleID:)]) {
        [ws performSelector:@selector(openApplicationWithBundleID:) withObject:bid];
        return true;
    }
    return false;
}

bool icli_open_url(const char *url) {
    icli_private_init();
    if (!url) {
        return false;
    }
    NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
    if (!u) {
        return false;
    }
    if (pSBSOpenSensitiveURLAndUnlock) {
        return pSBSOpenSensitiveURLAndUnlock((__bridge CFURLRef)u, 1);
    }
    id ws = lsWorkspace();
    if (ws && [ws respondsToSelector:@selector(openSensitiveURL:withOptions:)]) {
        return [ws openSensitiveURL:u withOptions:nil];
    }
    return false;
}

char *icli_frontmost_bundle_id(void) {
    icli_private_init();
    NSString *bid = nil;
    if (pSBSCopyFrontmostApplicationDisplayIdentifier) {
        bid = pSBSCopyFrontmostApplicationDisplayIdentifier();
    }
    if (!bid.length) {
        return NULL;
    }
    return strdup(bid.UTF8String);
}

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

// backboardd honours BKSDisplayBrightnessSet only from clients holding
// com.apple.backboard.displaybrightness; the request is sent asynchronously,
// so spin the run loop before the caller reads the value back.
bool icli_brightness_set(double value) {
    icli_private_init();
    double v = value;
    if (v < 0) v = 0;
    if (v > 1) v = 1;
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

static id lsWorkspace(void) {
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (![wsClass respondsToSelector:@selector(defaultWorkspace)]) {
        return nil;
    }
    return [wsClass performSelector:@selector(defaultWorkspace)];
}

static id proxyValue(id proxy, NSString *key) {
    if (!proxy) {
        return nil;
    }
    @try {
        return [proxy valueForKey:key];
    } @catch (NSException *ex) {
        (void)ex;
        return nil;
    }
}

static NSString *stringFromValue(id value) {
    if (!value || value == [NSNull null]) {
        return nil;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = value;
        return text.length ? text : nil;
    }
    if ([value isKindOfClass:[NSURL class]]) {
        return [(NSURL *)value path];
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    }
    NSString *text = [value description];
    return text.length ? text : nil;
}

static NSDictionary *appDictForProxy(id proxy) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSString *bundleID = stringFromValue(proxyValue(proxy, @"applicationIdentifier")) ?: stringFromValue(proxyValue(proxy, @"bundleIdentifier"));
    NSString *name = stringFromValue(proxyValue(proxy, @"localizedName"));
    NSString *bundlePath = stringFromValue(proxyValue(proxy, @"bundleURL"));
    NSString *dataPath = stringFromValue(proxyValue(proxy, @"dataContainerURL"));
    NSString *version = stringFromValue(proxyValue(proxy, @"shortVersionString"));
    NSString *build = stringFromValue(proxyValue(proxy, @"bundleVersion"));
    NSString *type = stringFromValue(proxyValue(proxy, @"applicationType"));
    NSString *signer = stringFromValue(proxyValue(proxy, @"signerIdentity")) ?: stringFromValue(proxyValue(proxy, @"teamID"));
    if (bundleID) d[@"bundle_id"] = bundleID;
    if (name) d[@"name"] = name;
    if (bundlePath) d[@"bundle_path"] = bundlePath;
    if (dataPath) d[@"data_path"] = dataPath;
    id groups = proxyValue(proxy, @"groupContainerURLs");
    NSMutableDictionary *groupPaths = [NSMutableDictionary dictionary];
    if ([groups isKindOfClass:NSDictionary.class]) {
        for (NSString *key in groups) {
            NSString *path = stringFromValue(groups[key]);
            if (path) groupPaths[key] = path;
        }
    }
    d[@"group_containers"] = groupPaths;
    if (version) d[@"version"] = version;
    if (build) d[@"build"] = build;
    if (type) d[@"type"] = type;
    if (signer) d[@"signer"] = signer;
    id running = proxyValue(proxy, @"isRunning");
    if ([running respondsToSelector:@selector(boolValue)]) {
        d[@"running"] = @([running boolValue]);
    }
    id schemes = proxyValue(proxy, @"claimedURLSchemes");
    if ([schemes isKindOfClass:[NSArray class]] && [schemes count] > 0) {
        d[@"schemes"] = schemes;
    }
    return d;
}

char *icli_apps_json(void) {
    icli_private_init();
    id ws = lsWorkspace();
    NSArray *apps = nil;
    if ([ws respondsToSelector:@selector(allInstalledApplications)]) {
        apps = [ws performSelector:@selector(allInstalledApplications)];
    }
    NSMutableArray *out = [NSMutableArray array];
    for (id proxy in apps) {
        [out addObject:appDictForProxy(proxy)];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
    if (!json) {
        return strdup("[]");
    }
    char *copy = malloc(json.length + 1);
    memcpy(copy, json.bytes, json.length);
    copy[json.length] = 0;
    return copy;
}

static void icliWalkRegistry(io_registry_entry_t entry, const char *planeName, int depth, NSMutableArray *entries) {
    if (depth > 5 || entries.count >= 300) {
        return;
    }
    io_name_t name = {0};
    io_name_t cls = {0};
    IORegistryEntryGetName(entry, name);
    IOObjectGetClass(entry, cls);
    [entries addObject:@{
        @"name": @(name),
        @"class": @(cls),
        @"depth": @(depth),
    }];
    io_iterator_t children = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildIterator(entry, planeName, &children) != KERN_SUCCESS) {
        return;
    }
    io_registry_entry_t child;
    while ((child = IOIteratorNext(children))) {
        icliWalkRegistry(child, planeName, depth + 1, entries);
        IOObjectRelease(child);
    }
    IOObjectRelease(children);
}

char *icli_ioreg_json(const char *plane) {
    icli_private_init();
    const char *planeName = (plane && plane[0]) ? plane : kIOServicePlane;
    mach_port_t master = MACH_PORT_NULL;
#if defined(kIOMainPortDefault)
    master = kIOMainPortDefault;
#elif defined(kIOMasterPortDefault)
    master = kIOMasterPortDefault;
#else
    IOMainPort(MACH_PORT_NULL, &master);
#endif
    io_registry_entry_t root = IORegistryGetRootEntry(master);
    if (!root) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"entries": @[], @"error": @"no io registry"} options:0 error:nil];
        return strndup((const char *)json.bytes, json.length);
    }
    NSMutableArray *entries = [NSMutableArray array];
    icliWalkRegistry(root, planeName, 0, entries);
    IOObjectRelease(root);
    NSDictionary *payload = @{@"plane": @(planeName), @"entries": entries, @"count": @(entries.count)};
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    return strndup((const char *)json.bytes, json.length);
}

void icli_string_free(char *s) {
    free(s);
}

static char *jsonDup(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json) {
        return strdup("{}");
    }
    return strndup((const char *)json.bytes, json.length);
}

bool icli_uninstall_app(const char *bundle_id) {
    icli_private_init();
    if (!bundle_id || !bundle_id[0]) {
        return false;
    }
    id ws = lsWorkspace();
    if (![ws respondsToSelector:@selector(uninstallApplication:withOptions:)]) {
        return false;
    }
    return [ws uninstallApplication:[NSString stringWithUTF8String:bundle_id] withOptions:nil];
}

static BOOL registerAppAtPath(NSString *path) {
    id ws = lsWorkspace();
    if (!ws || path.length == 0) {
        return NO;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    if ([ws respondsToSelector:@selector(registerApplication:)] && [ws registerApplication:url]) {
        return YES;
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    if (info && [ws respondsToSelector:@selector(registerApplicationDictionary:)]) {
        NSMutableDictionary *dict = [info mutableCopy];
        dict[@"Path"] = path;
        if (!dict[@"ApplicationType"]) {
            dict[@"ApplicationType"] = @"System";
        }
        if ([ws registerApplicationDictionary:dict]) {
            return YES;
        }
    }
    return NO;
}

bool icli_register_app(const char *path) {
    icli_private_init();
    if (!path) {
        return false;
    }
    return registerAppAtPath([NSString stringWithUTF8String:path]);
}

static NSString *normalizedAppPath(NSString *path);
static NSDictionary<NSString *, id> *registeredAppsByPath(void);

bool icli_unregister_app(const char *path) {
    icli_private_init();
    if (!path) {
        return false;
    }
    id ws = lsWorkspace();
    if (![ws respondsToSelector:@selector(unregisterApplication:)]) {
        return false;
    }
    // Keep LaunchServices' exact directory URL, including after the bundle
    // disappears. Rebuilding it from a missing path produces a file URL.
    id proxy = registeredAppsByPath()[normalizedAppPath(@(path))];
    NSURL *url = proxyValue(proxy, @"bundleURL");
    if (!url) url = [[NSURL fileURLWithPath:@(path) isDirectory:YES] URLByResolvingSymlinksInPath];
    return [ws unregisterApplication:url];
}

/// Comparable form of a bundle path. LaunchServices reports resolved paths
/// (a bootstrap behind a symlinked /var/jb appears under its real location),
/// so every existing component is resolved and /private/var becomes /var.
static NSString *normalizedAppPath(NSString *path) {
    path = [NSURL fileURLWithPath:path].path.stringByStandardizingPath;
    // Foundation can leave /tmp or /var/jb unresolved when the final bundle
    // has already been removed. Resolve the longest surviving ancestor so
    // stale registrations still match LaunchServices' physical paths.
    NSString *ancestor = path;
    NSMutableArray *suffix = [NSMutableArray array];
    while (ancestor.length) {
        char *resolved = realpath(ancestor.fileSystemRepresentation, NULL);
        if (resolved) {
            path = @(resolved);
            free(resolved);
            for (NSString *component in suffix.reverseObjectEnumerator) path = [path stringByAppendingPathComponent:component];
            break;
        }
        NSString *parent = ancestor.stringByDeletingLastPathComponent;
        if ([parent isEqual:ancestor]) break;
        [suffix addObject:ancestor.lastPathComponent];
        ancestor = parent;
    }
    if ([path hasPrefix:@"/private/var/"]) path = [path substringFromIndex:8];
    return path;
}

/// Registered application proxies keyed by normalized bundle path.
static NSDictionary<NSString *, id> *registeredAppsByPath(void) {
    id ws = lsWorkspace();
    NSArray *apps = [ws respondsToSelector:@selector(allInstalledApplications)] ? [ws performSelector:@selector(allInstalledApplications)] : nil;
    if (!apps) return nil;
    NSMutableDictionary *byPath = [NSMutableDictionary dictionary];
    for (id proxy in apps) {
        NSString *path = stringFromValue(proxyValue(proxy, @"bundleURL"));
        if (path) byPath[normalizedAppPath(path)] = proxy;
    }
    return byPath;
}

char *icli_app_registration_json(const char *path) {
    icli_private_init();
    if (!path) return jsonDup(@{@"registered": @NO});
    NSDictionary *apps = registeredAppsByPath();
    if (!apps) return jsonDup(@{@"error": @"LaunchServices application list unavailable"});
    id proxy = apps[normalizedAppPath(@(path))];
    if (!proxy) return jsonDup(@{@"registered": @NO, @"path": @(path)});
    NSMutableDictionary *result = [appDictForProxy(proxy) mutableCopy];
    result[@"registered"] = @YES;
    return jsonDup(result);
}

static NSArray<NSString *> *appBundlesInDirectory(NSString *directory, NSError **error) {
    NSMutableArray *paths = [NSMutableArray array];
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:error];
    if (!names) return nil;
    for (NSString *name in names) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        if ([name hasSuffix:@".app"] && [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"Info.plist"]]) [paths addObject:path];
    }
    return [paths sortedArrayUsingSelector:@selector(compare:)];
}

/// Reconcile by bundle ID and resolved path. Re-registering unchanged apps
/// can terminate them (upstream uikittools-ng 627e1ee). A moved app must be
/// registered before removing stale paths, since both records share an ID.
char *icli_apps_refresh_json(const char *directory) {
    icli_private_init();
    if (!directory) return jsonDup(@{@"error": @"directory required"});
    NSString *root = normalizedAppPath(@(directory));
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) return jsonDup(@{@"error": [@"not a directory: " stringByAppendingString:root]});
    NSError *error = nil;
    NSArray *paths = appBundlesInDirectory(root, &error);
    if (!paths) return jsonDup(@{@"error": error.localizedDescription ?: @"could not list application directory"});
    NSDictionary *before = registeredAppsByPath();
    if (!before) return jsonDup(@{@"error": @"LaunchServices application list unavailable"});
    NSMutableDictionary *installed = [NSMutableDictionary dictionary];
    for (NSString *path in paths) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
        NSString *bundleID = info[@"CFBundleIdentifier"];
        if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) return jsonDup(@{@"error": [@"missing bundle identifier: " stringByAppendingString:path]});
        if (installed[bundleID]) return jsonDup(@{@"error": [@"duplicate bundle identifier: " stringByAppendingString:bundleID]});
        installed[bundleID] = path;
    }
    NSMutableArray *registered = [NSMutableArray array], *failed = [NSMutableArray array], *unregistered = [NSMutableArray array], *unchanged = [NSMutableArray array];
    for (NSString *bundleID in [[installed allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *path = installed[bundleID];
        id proxy = before[normalizedAppPath(path)];
        NSString *registeredID = stringFromValue(proxyValue(proxy, @"applicationIdentifier")) ?: stringFromValue(proxyValue(proxy, @"bundleIdentifier"));
        if ([registeredID isEqual:bundleID]) {
            [unchanged addObject:path];
            continue;
        }
        if (registerAppAtPath(path)) [registered addObject:path];
        else [failed addObject:path];
    }
    NSString *prefix = [root stringByAppendingString:@"/"];
    NSDictionary *byPath = registeredAppsByPath();
    if (!byPath) return jsonDup(@{@"error": @"LaunchServices application list unavailable after registration"});
    for (NSString *path in [[byPath allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![path hasPrefix:prefix] || [[path substringFromIndex:prefix.length] containsString:@"/"] || [NSFileManager.defaultManager fileExistsAtPath:path]) continue;
        NSString *bundleID = stringFromValue(proxyValue(byPath[path], @"applicationIdentifier")) ?: stringFromValue(proxyValue(byPath[path], @"bundleIdentifier"));
        // Do not unregister the same ID we just moved (or failed to move).
        if (bundleID && installed[bundleID]) continue;
        if (icli_unregister_app(path.UTF8String)) [unregistered addObject:path];
        else [failed addObject:path];
    }
    NSDictionary *after = registeredAppsByPath();
    if (!after) return jsonDup(@{@"error": @"LaunchServices application list unavailable during verification"});
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *bundleID in installed) {
        NSString *path = installed[bundleID];
        id proxy = after[normalizedAppPath(path)];
        NSString *registeredID = stringFromValue(proxyValue(proxy, @"applicationIdentifier")) ?: stringFromValue(proxyValue(proxy, @"bundleIdentifier"));
        if (![registeredID isEqual:bundleID]) [missing addObject:path];
    }
    for (NSString *path in unregistered) if (after[path]) [missing addObject:path];
    return jsonDup(@{@"directory": root, @"registered": registered, @"unchanged": unchanged, @"unregistered": unregistered, @"failed": failed, @"unverified": missing});
}

/// Unregisters every registered application whose bundle lives directly in `directory`.
char *icli_apps_unregister_directory_json(const char *directory) {
    icli_private_init();
    if (!directory) return jsonDup(@{@"error": @"directory required"});
    NSString *root = normalizedAppPath(@(directory));
    NSString *prefix = [root stringByAppendingString:@"/"];
    NSMutableArray *unregistered = [NSMutableArray array], *failed = [NSMutableArray array];
    for (NSString *path in registeredAppsByPath()) {
        if (![path hasPrefix:prefix] || [[path substringFromIndex:prefix.length] containsString:@"/"]) continue;
        if (icli_unregister_app(path.UTF8String)) [unregistered addObject:path];
        else [failed addObject:path];
    }
    NSDictionary *after = registeredAppsByPath();
    NSMutableArray *remaining = [NSMutableArray array];
    for (NSString *path in unregistered) if (after[path]) [remaining addObject:path];
    return jsonDup(@{@"directory": root, @"unregistered": unregistered, @"failed": failed, @"unverified": remaining});
}

char *icli_app_handlers_json(const char *url_or_scheme) {
    icli_private_init();
    if (!url_or_scheme) {
        return jsonDup(@{@"error": @"missing url"});
    }
    NSString *arg = [NSString stringWithUTF8String:url_or_scheme];
    id ws = lsWorkspace();
    NSArray *proxies = nil;
    NSString *scheme = arg;
    if ([arg containsString:@"://"]) {
        NSURL *url = [NSURL URLWithString:arg];
        scheme = url.scheme ?: arg;
        if ([ws respondsToSelector:@selector(applicationsAvailableForOpeningURL:)]) {
            proxies = [ws applicationsAvailableForOpeningURL:url];
        }
    }
    if (!proxies && [ws respondsToSelector:@selector(applicationsAvailableForHandlingURLScheme:)]) {
        proxies = [ws applicationsAvailableForHandlingURLScheme:scheme];
    }
    NSMutableArray *apps = [NSMutableArray array];
    for (id proxy in proxies) {
        [apps addObject:appDictForProxy(proxy)];
    }
    return jsonDup(@{
        @"url": arg,
        @"scheme": scheme,
        @"apps": apps,
        @"count": @(apps.count),
    });
}

bool icli_open_url_in_app(const char *url, const char *bundle_id) {
    icli_private_init();
    if (!url) {
        return false;
    }
    if (!bundle_id || !bundle_id[0]) {
        return icli_open_url(url);
    }
    NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
    NSString *bid = [NSString stringWithUTF8String:bundle_id];
    if (!u || !bid.length) {
        return false;
    }
    id ws = lsWorkspace();
    SEL opSel = @selector(operationToOpenResource:usingApplication:userInfo:);
    if ([ws respondsToSelector:opSel]) {
        NSMethodSignature *sig = [ws methodSignatureForSelector:opSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:opSel];
        [inv setTarget:ws];
        id userInfo = nil;
        [inv setArgument:&u atIndex:2];
        [inv setArgument:&bid atIndex:3];
        [inv setArgument:&userInfo atIndex:4];
        [inv invoke];
        __unsafe_unretained id op = nil;
        [inv getReturnValue:&op];
        if ([op respondsToSelector:@selector(start)]) {
            [op performSelector:@selector(start)];
            return true;
        }
    }
    NSDictionary *opts = @{@"LSApplicationIdentifier": bid, @"bundleid": bid};
    if ([ws respondsToSelector:@selector(openSensitiveURL:withOptions:)]) {
        return [ws openSensitiveURL:u withOptions:opts];
    }
    if ([ws respondsToSelector:@selector(openURL:withOptions:)]) {
        return [ws openURL:u withOptions:opts];
    }
    return false;
}

bool icli_wake(void) {
    icli_private_init();
    if (pSBSUndimScreen) {
        pSBSUndimScreen();
    }
    return icli_hid_button("home");
}
