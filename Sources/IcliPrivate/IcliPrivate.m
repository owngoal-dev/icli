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

// SpringBoard's passcode flag is set only while the passcode is guarding the
// lock screen, so it reads false on an unlocked device that has a passcode.
static int passcodeSet(void) {
    dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration", RTLD_NOW);
    Class connectionClass = NSClassFromString(@"MCProfileConnection");
    if (![connectionClass respondsToSelector:@selector(sharedConnection)]) {
        return -1;
    }
    id connection = ((id (*)(id, SEL))objc_msgSend)(connectionClass, @selector(sharedConnection));
    if (![connection respondsToSelector:@selector(isPasscodeSet)]) {
        return -1;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(connection, @selector(isPasscodeSet)) ? 1 : 0;
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

bool icli_passcode_set(void) {
    int configured = passcodeSet();
    return configured >= 0 ? configured == 1 : icli_lock_status().passcode_enabled;
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

// CADisplay reports the panel's pixel size and native/current rotation. On an
// iPad the panel is landscape (nativeOrientation rot270) whatever the UI does.
static IcliScreenMetrics panelMetrics(void) {
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

static UIImage *uikitScreenImage(void) {
    UIImage *image = _UICreateScreenUIImage();
    if (!image && p_UICreateScreenUIImage) {
        image = p_UICreateScreenUIImage();
    }
    return image;
}

// UIKit's screen image holds the frame buffer in the fixed (portrait)
// coordinate space that the digitizer and AX hit testing use. Its orientation
// tag follows the physical device, so it goes stale when the interface is
// rotated without turning the device; SpringBoard's interface orientation is
// asked for first. CADisplay's currentOrientation follows neither.
typedef struct {
    bool valid;
    double fixed_width;
    double fixed_height;
    double scale;
    int degrees;
} IcliInterfaceGeometry;

static int degreesForImageOrientation(UIImageOrientation orientation) {
    switch (orientation) {
    case UIImageOrientationLeft:
        return 90;
    case UIImageOrientationDown:
        return 180;
    case UIImageOrientationRight:
        return 270;
    default:
        return 0;
    }
}

static id axSpringBoardServer(void);

// Degrees for SpringBoard's UIInterfaceOrientation, or -1 when it is unknown.
static int springBoardInterfaceDegrees(void) {
    id server = axSpringBoardServer();
    if (![server respondsToSelector:@selector(activeInterfaceOrientation)]) {
        return -1;
    }
    switch (((long (*)(id, SEL))objc_msgSend)(server, @selector(activeInterfaceOrientation))) {
    case 1:
        return 0;
    case 2:
        return 180;
    case 3:
        return 270;
    case 4:
        return 90;
    default:
        return -1;
    }
}

// A capture costs about 35 ms; gestures ask for every event, so reuse it briefly.
static IcliInterfaceGeometry cachedGeometry = {false, 0, 0, 1, 0};
static bool geometryStale = true;
static NSTimeInterval geometryCapturedAt = 0;
static NSLock *geometryLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSLock new];
    });
    return lock;
}

static void invalidateInterfaceGeometry(void) {
    [geometryLock() lock];
    geometryStale = true;
    [geometryLock() unlock];
}

static IcliInterfaceGeometry interfaceGeometry(void) {
    [geometryLock() lock];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (geometryStale || !cachedGeometry.valid || now - geometryCapturedAt > 1) {
        IcliInterfaceGeometry geometry = {false, 0, 0, 1, 0};
        @autoreleasepool {
            UIImage *image = uikitScreenImage();
            CGImageRef cg = image.CGImage;
            double scale = image.scale > 0 ? image.scale : 1;
            if (cg && CGImageGetWidth(cg) > 1 && CGImageGetHeight(cg) > 1) {
                geometry.valid = true;
                geometry.fixed_width = CGImageGetWidth(cg) / scale;
                geometry.fixed_height = CGImageGetHeight(cg) / scale;
                geometry.scale = scale;
                int degrees = springBoardInterfaceDegrees();
                geometry.degrees = degrees >= 0 ? degrees : degreesForImageOrientation(image.imageOrientation);
            }
        }
        cachedGeometry = geometry;
        geometryCapturedAt = now;
        geometryStale = false;
    }
    IcliInterfaceGeometry result = cachedGeometry;
    [geometryLock() unlock];
    return result;
}

IcliScreenMetrics icli_screen_metrics(void) {
    icli_private_init();
    IcliInterfaceGeometry geometry = interfaceGeometry();
    if (!geometry.valid) {
        return panelMetrics();
    }
    bool sideways = geometry.degrees == 90 || geometry.degrees == 270;
    IcliScreenMetrics m = {
        sideways ? geometry.fixed_height : geometry.fixed_width,
        sideways ? geometry.fixed_width : geometry.fixed_height,
        geometry.scale,
        geometry.degrees,
    };
    return m;
}

void icli_screen_point_to_fixed(double x, double y, double *fx, double *fy) {
    icli_private_init();
    IcliInterfaceGeometry geometry = interfaceGeometry();
    double width = geometry.fixed_width, height = geometry.fixed_height;
    switch (geometry.valid ? geometry.degrees : 0) {
    case 90:
        *fx = y;
        *fy = height - x;
        break;
    case 180:
        *fx = width - x;
        *fy = height - y;
        break;
    case 270:
        *fx = width - y;
        *fy = x;
        break;
    default:
        *fx = x;
        *fy = y;
        break;
    }
}

void icli_screen_fixed_to_point(double fx, double fy, double *x, double *y) {
    icli_private_init();
    IcliInterfaceGeometry geometry = interfaceGeometry();
    double width = geometry.fixed_width, height = geometry.fixed_height;
    switch (geometry.valid ? geometry.degrees : 0) {
    case 90:
        *x = height - fy;
        *y = fx;
        break;
    case 180:
        *x = width - fx;
        *y = height - fy;
        break;
    case 270:
        *x = fy;
        *y = width - fx;
        break;
    default:
        *x = fx;
        *y = fy;
        break;
    }
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
    invalidateInterfaceGeometry();
    return true;
}

IcliRotation icli_rotation_get(void) {
    icli_private_init();
    IcliScreenMetrics metrics = icli_screen_metrics();
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
    IcliScreenMetrics m = panelMetrics();
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

static UIImage *orientedScreenImage(void) {
    UIImage *raw = uikitScreenImage();
    if (!raw) {
        // The render server draws in the panel's orientation, not the UI's.
        raw = screenshotViaRenderServer();
        int degrees = raw ? nativeToCurrentRotation() : 0;
        if (degrees == 90 || degrees == 180 || degrees == 270) {
            UIImage *rotated = rotateCGImage(raw.CGImage, degrees);
            if (rotated) {
                return rotated;
            }
        }
    }
    if (!raw) {
        return nil;
    }
    // The buffer is in the fixed space. Under a landscape-right (270) interface
    // the top of the interface lies along the buffer's right edge, so it turns
    // counter-clockwise to become upright. This matches
    // icli_screen_point_to_fixed, which the digitizer confirms.
    IcliInterfaceGeometry geometry = interfaceGeometry();
    UIImageOrientation upright = UIImageOrientationUp;
    switch (geometry.valid ? geometry.degrees : 0) {
    case 90:
        upright = UIImageOrientationRight;
        break;
    case 180:
        upright = UIImageOrientationDown;
        break;
    case 270:
        upright = UIImageOrientationLeft;
        break;
    default:
        return [UIImage imageWithCGImage:raw.CGImage scale:raw.scale orientation:UIImageOrientationUp];
    }
    UIImage *turned = [UIImage imageWithCGImage:raw.CGImage scale:raw.scale orientation:upright];
    UIGraphicsBeginImageContextWithOptions(turned.size, YES, turned.scale);
    [turned drawInRect:CGRectMake(0, 0, turned.size.width, turned.size.height)];
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

// The digitizer reports in the fixed (portrait) space, whatever the UI shows.
static void normalizePoint(double x, double y, double *nx, double *ny) {
    IcliInterfaceGeometry geometry = interfaceGeometry();
    if (!geometry.valid) {
        IcliScreenMetrics m = panelMetrics();
        *nx = x / (m.width > 1 ? m.width : 1);
        *ny = y / (m.height > 1 ? m.height : 1);
        return;
    }
    double fx = x, fy = y;
    icli_screen_point_to_fixed(x, y, &fx, &fy);
    *nx = fx / (geometry.fixed_width > 1 ? geometry.fixed_width : 1);
    *ny = fy / (geometry.fixed_height > 1 ? geometry.fixed_height : 1);
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
    id ws = icli_ls_workspace();
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
    id ws = icli_ls_workspace();
    if (ws && [ws respondsToSelector:@selector(openSensitiveURL:withOptions:)]) {
        return [ws openSensitiveURL:u withOptions:nil];
    }
    return false;
}

// RunningBoard marks the focused foreground app with a FrontBoard
// "Workspace-ForegroundFocal" assertion. iPadOS 18 answers nil from
// SBSCopyFrontmostApplicationDisplayIdentifier even with an app in front.
static NSString *runningBoardFocalApplication(void) {
    dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_NOW);
    Class handleClass = NSClassFromString(@"RBSProcessHandle");
    Class identifierClass = NSClassFromString(@"RBSProcessIdentifier");
    SEL identifierSelector = NSSelectorFromString(@"identifierWithPid:");
    SEL handleSelector = NSSelectorFromString(@"handleForIdentifier:error:");
    if (![identifierClass respondsToSelector:identifierSelector] || ![handleClass respondsToSelector:handleSelector]) {
        return nil;
    }
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) != 0) {
        return nil;
    }
    length += 64 * sizeof(struct kinfo_proc);
    struct kinfo_proc *processes = calloc(1, length);
    if (!processes || sysctl(mib, 3, processes, &length, NULL, 0) != 0) {
        free(processes);
        return nil;
    }
    int (*pidPath)(int, void *, uint32_t) = dlsym(RTLD_DEFAULT, "proc_pidpath");
    NSString *focal = nil;
    for (size_t i = 0; i < length / sizeof(struct kinfo_proc) && !focal; i++) {
        pid_t pid = processes[i].kp_proc.p_pid;
        char path[4096] = {0};
        // Only app bundles can be the frontmost application.
        if (pid <= 0 || !pidPath || pidPath(pid, path, sizeof(path)) <= 0 || !strstr(path, ".app/")) {
            continue;
        }
        @try {
            id identifier = ((id (*)(id, SEL, int))objc_msgSend)(identifierClass, identifierSelector, pid);
            id handle = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(handleClass, handleSelector, identifier, NULL);
            NSString *bundleID = [[handle valueForKey:@"identity"] valueForKey:@"embeddedApplicationIdentifier"];
            if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length) {
                continue;
            }
            for (id assertion in [[handle valueForKey:@"currentState"] valueForKey:@"assertions"]) {
                NSString *domain = [assertion valueForKey:@"domain"];
                if ([domain isKindOfClass:[NSString class]] && [domain containsString:@"Workspace-ForegroundFocal"]) {
                    focal = bundleID;
                    break;
                }
            }
        } @catch (NSException *ex) {
            (void)ex;
        }
    }
    free(processes);
    return focal;
}

char *icli_frontmost_bundle_id(void) {
    icli_private_init();
    NSString *bid = nil;
    if (pSBSCopyFrontmostApplicationDisplayIdentifier) {
        bid = pSBSCopyFrontmostApplicationDisplayIdentifier();
    }
    if (!bid.length) {
        bid = runningBoardFocalApplication();
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
    id value = client ? ((id (*)(id, SEL, id))objc_msgSend)(client, @selector(copyPropertyForKey:), @"DisplayBrightnessAuto") : nil;
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
    return ((BOOL (*)(id, SEL, id, id))objc_msgSend)(client, @selector(setProperty:forKey:), request, @"DisplayBrightness");
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
    id ws = icli_ls_workspace();
    if (![ws respondsToSelector:@selector(uninstallApplication:withOptions:)]) {
        return false;
    }
    return [ws uninstallApplication:[NSString stringWithUTF8String:bundle_id] withOptions:nil];
}

static BOOL bundleHasSettingsBundle(NSString *path) {
    return [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"Settings.bundle/Root.plist"]];
}

/// Whether LaunchServices' record is of the build on disk; a build that is
/// not a string, on either side, cannot be told apart and counts as current.
/// The proxy's bundleVersion is the string as written; LSApplicationRecord's
/// is not.
static BOOL registeredBuildIsCurrent(id proxy, NSDictionary *info) {
    id build = info[@"CFBundleVersion"];
    NSString *registeredBuild = icli_ls_string(icli_ls_value(proxy, @"bundleVersion"));
    return ![build isKindOfClass:NSString.class] || !registeredBuild || [registeredBuild isEqual:build];
}

/// Whether a registration from the Info.plist can stand in for this record:
/// it spells out no data container, group containers or plug-ins, so a
/// record that has any is kept. No record is replaceable.
static BOOL recordIsReplaceable(id proxy) {
    return ![icli_ls_value(proxy, @"isContainerized") boolValue] && !icli_ls_value(proxy, @"dataContainerURL") &&
        ![icli_ls_value(proxy, @"groupContainerURLs") count] && ![icli_ls_value(proxy, @"plugInKitPlugins") count];
}

static NSString *normalizedAppPath(NSString *path);
static NSDictionary<NSString *, id> *registeredAppsByPath(void);

/// On iOS 26, registerApplication: refused a new bundle (Saily's) and
/// answered YES for one it already had without reading it again, and it never
/// records HasSettingsBundle, without which the Settings app shows no page
/// for the app. So the record is read back, and one that is missing, of
/// another build or wrong about the settings bundle is registered from the
/// Info.plist instead, unless it holds what that registration would drop. A
/// registration whose record cannot be read back is left as it is, and one
/// that leaves a record of another build has failed.
static BOOL registerAppAtPath(NSString *path) {
    id ws = icli_ls_workspace();
    if (!ws || path.length == 0) {
        return NO;
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    BOOL hasSettingsBundle = bundleHasSettingsBundle(path);
    BOOL registered = [ws respondsToSelector:@selector(registerApplication:)] && [ws registerApplication:[NSURL fileURLWithPath:path]];
    id proxy = registeredAppsByPath()[normalizedAppPath(path)];
    if (proxy ? !recordIsReplaceable(proxy) : registered) {
        return registered;
    }
    BOOL current = registered && registeredBuildIsCurrent(proxy, info);
    if (current && [icli_ls_value(proxy, @"hasSettingsBundle") boolValue] == hasSettingsBundle) {
        return YES;
    }
    if (!info || ![ws respondsToSelector:@selector(registerApplicationDictionary:)]) {
        return current;
    }
    NSMutableDictionary *dict = [info mutableCopy];
    dict[@"Path"] = path;
    if (!dict[@"ApplicationType"]) {
        dict[@"ApplicationType"] = @"System";
    }
    if (hasSettingsBundle) {
        dict[@"HasSettingsBundle"] = @YES;
    }
    return [ws registerApplicationDictionary:dict] || current;
}

bool icli_register_app(const char *path) {
    icli_private_init();
    if (!path) {
        return false;
    }
    return registerAppAtPath([NSString stringWithUTF8String:path]);
}

bool icli_unregister_app(const char *path) {
    icli_private_init();
    if (!path) {
        return false;
    }
    id ws = icli_ls_workspace();
    if (![ws respondsToSelector:@selector(unregisterApplication:)]) {
        return false;
    }
    // Keep LaunchServices' exact directory URL, including after the bundle
    // disappears. Rebuilding it from a missing path produces a file URL.
    id proxy = registeredAppsByPath()[normalizedAppPath(@(path))];
    NSURL *url = icli_ls_value(proxy, @"bundleURL");
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
    id ws = icli_ls_workspace();
    NSArray *apps = [ws respondsToSelector:@selector(allInstalledApplications)] ? [ws performSelector:@selector(allInstalledApplications)] : nil;
    if (!apps) return nil;
    NSMutableDictionary *byPath = [NSMutableDictionary dictionary];
    for (id proxy in apps) {
        NSString *path = icli_ls_string(icli_ls_value(proxy, @"bundleURL"));
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
    NSMutableDictionary *result = [icli_ls_app_dictionary(proxy) mutableCopy];
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

/// Reconcile by bundle ID, resolved path and build, so an app updated in
/// place is registered again when registerAppAtPath can replace its record.
/// Re-registering unchanged apps can terminate them (upstream uikittools-ng
/// 627e1ee). A moved app must be
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
    NSMutableDictionary *infos = [NSMutableDictionary dictionary];
    for (NSString *path in paths) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
        NSString *bundleID = info[@"CFBundleIdentifier"];
        if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) return jsonDup(@{@"error": [@"missing bundle identifier: " stringByAppendingString:path]});
        if (installed[bundleID]) return jsonDup(@{@"error": [@"duplicate bundle identifier: " stringByAppendingString:bundleID]});
        installed[bundleID] = path;
        infos[bundleID] = info;
    }
    NSMutableArray *registered = [NSMutableArray array], *failed = [NSMutableArray array], *unregistered = [NSMutableArray array], *unchanged = [NSMutableArray array];
    for (NSString *bundleID in [[installed allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *path = installed[bundleID];
        id proxy = before[normalizedAppPath(path)];
        NSString *registeredID = icli_ls_string(icli_ls_value(proxy, @"applicationIdentifier")) ?: icli_ls_string(icli_ls_value(proxy, @"bundleIdentifier"));
        if ([registeredID isEqual:bundleID] && (registeredBuildIsCurrent(proxy, infos[bundleID]) || !recordIsReplaceable(proxy))) {
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
        NSString *bundleID = icli_ls_string(icli_ls_value(byPath[path], @"applicationIdentifier")) ?: icli_ls_string(icli_ls_value(byPath[path], @"bundleIdentifier"));
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
        NSString *registeredID = icli_ls_string(icli_ls_value(proxy, @"applicationIdentifier")) ?: icli_ls_string(icli_ls_value(proxy, @"bundleIdentifier"));
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
    id ws = icli_ls_workspace();
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
        [apps addObject:icli_ls_app_dictionary(proxy)];
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
    id ws = icli_ls_workspace();
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
