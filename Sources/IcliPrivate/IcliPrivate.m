#import "IcliPrivate.h"
#import "Settle.h"
#import "IcliJSON.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

// The Create rule: UIKit returns the image from alloc/initWithCGImage without
// autoreleasing it. ARC applies the rule only when told, and without this every
// capture leaked a display-sized image and its surface.
OBJC_EXTERN UIImage *_UICreateScreenUIImage(void) NS_RETURNS_RETAINED;
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <unistd.h>
#import <math.h>
#import <string.h>
#import <stdlib.h>
#import <sys/sysctl.h>
#import <IOKit/IOKitLib.h>

@interface NSObject (IcliLS)
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(id)options;
@end

typedef void *IOHIDEventRef;
typedef void *IOHIDEventSystemClientRef;
typedef uint32_t IOOptionBits;
typedef double IOHIDFloat;

static void *sIOKit;

static IOHIDEventRef (*pIOHIDEventCreateDigitizerEvent)(
    CFAllocatorRef,
    uint64_t,
    uint32_t,
    uint32_t,
    uint32_t,
    uint32_t,
    uint32_t,
    IOHIDFloat,
    IOHIDFloat,
    IOHIDFloat,
    IOHIDFloat,
    IOHIDFloat,
    Boolean,
    Boolean,
    IOOptionBits
);
static IOHIDEventRef (*pIOHIDEventCreateDigitizerFingerEvent)(
    CFAllocatorRef,
    uint64_t,
    uint32_t,
    uint32_t,
    uint32_t,
    IOHIDFloat,
    IOHIDFloat,
    IOHIDFloat,
    IOHIDFloat,
    IOHIDFloat,
    Boolean,
    Boolean,
    IOOptionBits
);
static IOHIDEventRef (*pIOHIDEventCreateKeyboardEvent)(
    CFAllocatorRef,
    uint64_t,
    uint16_t,
    uint16_t,
    Boolean,
    IOOptionBits
);
static void (*pIOHIDEventAppendEvent)(IOHIDEventRef, IOHIDEventRef, IOOptionBits);
static void (*pIOHIDEventSetSenderID)(IOHIDEventRef, uint64_t);
static void (*pIOHIDEventSetIntegerValue)(IOHIDEventRef, uint32_t, int);
static IOHIDEventSystemClientRef (*pIOHIDEventSystemClientCreate)(CFAllocatorRef);
static IOHIDEventSystemClientRef (*pIOHIDEventSystemClient)(void);
static void (*pIOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef, IOHIDEventRef);

static bool (*pSBSOpenSensitiveURLAndUnlock)(CFURLRef, char);
static void (*pSBSUndimScreen)(void);

static IOHIDEventSystemClientRef sHIDClient;

// Built-in digitizer sender used by witchan/ios-mcp HIDManager.m
static const uint64_t kBuiltInDigitizerSenderID = 0x8000000817319372ULL;

// IOHIDEventTypes.h / USB HID Usage Tables / Apple Wiki Dev:IOHIDFamily / WebKit IOKitSPI.h
enum {
    kIOHIDEventTypeDigitizer = 11,
    kIOHIDDigitizerEventRange = 1 << 0,
    kIOHIDDigitizerEventTouch = 1 << 1,
    kIOHIDDigitizerEventPosition = 1 << 2,
    kIOHIDDigitizerTransducerTypeHand = 3,
    kIOHIDEventOptionNone = 0,
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

void icli_private_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        void *sbs = dlopen(
            "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            RTLD_NOW
        );

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
        if (sbs) {
            SYM(sbs, pSBSOpenSensitiveURLAndUnlock, "SBSOpenSensitiveURLAndUnlock");
            SYM(sbs, pSBSUndimScreen, "SBSUndimScreen");
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

static id mainDisplay(void) {
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    Class displayClass = NSClassFromString(@"CADisplay");
    if (![displayClass respondsToSelector:@selector(mainDisplay)]) {
        return nil;
    }
    return [displayClass performSelector:@selector(mainDisplay)];
}

/// The display's rotation under `key`, or `fallback` when it cannot be read.
static int displayRotation(id display, NSString *key, int fallback) {
    @try {
        return parseRotationDegrees([display valueForKey:key]);
    } @catch (NSException *ex) {
        (void)ex;
        return fallback;
    }
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
    }
    // orientation is in degrees. UIDevice's orientation is an enum, not
    // degrees, and stays unknown in a host that never asked for device
    // orientation notifications, so the fallback is the panel's own 0.
    id display = mainDisplay();
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
    m.orientation = displayRotation(display, @"currentOrientation", m.orientation);
    return m;
}

static int nativeToCurrentRotation(void) {
    id display = mainDisplay();
    if (!display) {
        return 0;
    }
    int native = displayRotation(display, @"nativeOrientation", 0);
    int current = displayRotation(display, @"currentOrientation", 0);
    return ((native - current) % 360 + 360) % 360;
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

// _UICreateScreenUIImage sizes its surface from the screen and passes it to
// CFGetTypeID without a nil check. While the display has no size yet, as
// during boot, the surface is NULL and the caller crashes, so it is not asked.
static bool screenCaptureReady(void) {
    CGSize size = [UIScreen mainScreen].bounds.size;
    if (size.width < 1 || size.height < 1) {
        return false;
    }
    id display = mainDisplay();
    if (!display) {
        return true;
    }
    @try {
        CGRect pixels = [[display valueForKey:@"bounds"] CGRectValue];
        return pixels.size.width >= 1 && pixels.size.height >= 1;
    } @catch (NSException *ex) {
        (void)ex;
        return true;
    }
}

static IcliInterfaceGeometry interfaceGeometry(void) {
    [geometryLock() lock];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (geometryStale || !cachedGeometry.valid || now - geometryCapturedAt > 1) {
        IcliInterfaceGeometry geometry = {false, 0, 0, 1, 0};
        @autoreleasepool {
            UIImage *image = screenCaptureReady() ? _UICreateScreenUIImage() : nil;
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
    IcliInterfaceGeometry geometry = interfaceGeometry();
    double width = geometry.fixed_width, height = geometry.fixed_height;
    switch (geometry.degrees) {
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
    IcliInterfaceGeometry geometry = interfaceGeometry();
    double width = geometry.fixed_width, height = geometry.fixed_height;
    switch (geometry.degrees) {
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

// AXIPCClient learns that SpringBoard died from a run loop source on the main
// thread. A long-lived caller whose main thread never runs its run loop, such
// as a daemon, keeps the old SpringBoard's port after a respring: the client
// still reports itself connected and every message fails with
// MACH_SEND_INVALID_DEST. A dead port is dropped here, so the next message
// looks up the new SpringBoard.
static void disconnectIfServerDied(id server) {
    if (![server respondsToSelector:@selector(client)]) {
        return;
    }
    id client = [server performSelector:@selector(client)];
    if (![client respondsToSelector:@selector(isConnected)]
        || ![client respondsToSelector:@selector(serviceMachPort)]
        || ![client respondsToSelector:@selector(disconnectWithError:)]
        || !((BOOL (*)(id, SEL))objc_msgSend)(client, @selector(isConnected))) {
        return;
    }
    mach_port_t port = ((mach_port_t (*)(id, SEL))objc_msgSend)(client, @selector(serviceMachPort));
    mach_port_type_t type = 0;
    kern_return_t kr = mach_port_type(mach_task_self(), port, &type);
    if (kr == KERN_SUCCESS && !(type & MACH_PORT_TYPE_DEAD_NAME)) {
        return;
    }
    ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(client, @selector(disconnectWithError:), NULL);
}

static id axSpringBoardServer(void) {
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_NOW);
    Class cls = NSClassFromString(@"AXSpringBoardServer");
    if (![cls respondsToSelector:@selector(server)]) {
        return nil;
    }
    id server = [cls performSelector:@selector(server)];
    disconnectIfServerDied(server);
    return server;
}

// AXSpringBoardServer -setOrientation: is the AssistiveTouch "Rotate Screen"
// path; SpringBoard applies it to the foreground app. The caller reads back.
static bool setCompositorOrientation(int degrees) {
    id server = axSpringBoardServer();
    if (![server respondsToSelector:@selector(setOrientation:)]) {
        return false;
    }
    ((void (*)(id, SEL, long))objc_msgSend)(
        server,
        @selector(setOrientation:),
        uiInterfaceOrientationForDegrees(degrees)
    );
    icli_settle(0.3);
    invalidateInterfaceGeometry();
    return true;
}

int icli_interface_degrees(void) {
    return springBoardInterfaceDegrees();
}

IcliRotation icli_rotation_get(void) {
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
        rotation.locked = rotation.locked || ((BOOL (*)(id, SEL))objc_msgSend)(server, @selector(isOrientationLocked));
    }
    return rotation;
}

bool icli_rotation_set(int degrees) {
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
    bool ok = false;
    id server = axSpringBoardServer();
    if ([server respondsToSelector:@selector(setOrientationLocked:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(server, @selector(setOrientationLocked:), locked);
        ok = true;
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
    if (!pCreate || !pBase || !pBytesPerRow || !pLock || !pUnlock || !pRender || !pWidth || !pHeight || !pBPE || !pBPR
        || !pFmt) {
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
    // The render server cannot draw into a surface this process holds
    // locked, so render first and lock only to read.
    pRender(0, CFSTR("LCD"), surface, 0, 0);
    pLock(surface, 1 /* kIOSurfaceLockReadOnly */, NULL);
    void *base = pBase(surface);
    size_t bpr = pBytesPerRow(surface);
    NSData *pixels = base ? [NSData dataWithBytes:base length:bpr * (size_t)height] : nil;
    pUnlock(surface, 1 /* kIOSurfaceLockReadOnly */, NULL);
    CFRelease(surface);
    if (!pixels) {
        return nil;
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGImageRef cg = CGImageCreate(
        width,
        height,
        8,
        32,
        bpr,
        space,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
        provider,
        NULL,
        true,
        kCGRenderingIntentDefault
    );
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
    UIImage *raw = screenCaptureReady() ? _UICreateScreenUIImage() : nil;
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
    switch (geometry.degrees) {
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
void icli_screen_point_to_digitizer(double x, double y, double *nx, double *ny) {
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

// nx and ny are 0…1 in the fixed digitizer space.
static IOHIDEventRef createDigitizerEvent(double nx, double ny, IcliTouchPhase phase) {
    if (!pIOHIDEventCreateDigitizerEvent) {
        return NULL;
    }
    uint64_t timestamp = mach_absolute_time();
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
    }
    IOHIDEventRef parent = pIOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,
        timestamp,
        kIOHIDDigitizerTransducerTypeHand,
        0,
        0,
        mask,
        0,
        0,
        0,
        0,
        0,
        0,
        range,
        isTouch,
        kIOHIDEventOptionNone
    );
    if (!parent) {
        return NULL;
    }
    if (pIOHIDEventSetIntegerValue) {
        pIOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    }
    if (pIOHIDEventCreateDigitizerFingerEvent && pIOHIDEventAppendEvent) {
        IOHIDEventRef finger = pIOHIDEventCreateDigitizerFingerEvent(
            kCFAllocatorDefault,
            timestamp,
            0,
            2,
            mask,
            nx,
            ny,
            0,
            0,
            0,
            range,
            isTouch,
            kIOHIDEventOptionNone
        );
        if (finger) {
            pIOHIDEventAppendEvent(parent, finger, 0);
            CFRelease(finger);
        }
    }
    return parent;
}

static bool hidTouch(double x, double y, IcliTouchPhase phase) {
    icli_private_init();
    double nx, ny;
    icli_screen_point_to_digitizer(x, y, &nx, &ny);
    return dispatchHID(createDigitizerEvent(nx, ny, phase));
}

bool icli_hid_touch(int phase, double nx, double ny) {
    icli_private_init();
    // UITouchPhase numbering, which vphoned's host protocol also uses.
    IcliTouchPhase touchPhase;
    switch (phase) {
    case 0: touchPhase = IcliTouchBegan; break;
    case 1: touchPhase = IcliTouchMoved; break;
    case 3: touchPhase = IcliTouchEnded; break;
    default: return false;
    }
    return dispatchHID(createDigitizerEvent(nx, ny, touchPhase));
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
    IOHIDEventRef event = pIOHIDEventCreateKeyboardEvent(
        kCFAllocatorDefault,
        mach_absolute_time(),
        usage_page,
        usage,
        down,
        0
    );
    if (event && pIOHIDEventSetIntegerValue) pIOHIDEventSetIntegerValue(event, 4, 1);
    return dispatchHID(event);
}

bool icli_hid_text(const char *text) {
    icli_private_init();
    if (!text) return false;
    IOHIDEventRef (*createUnicode)(
        CFAllocatorRef,
        uint64_t,
        const uint8_t *,
        uint32_t,
        uint32_t,
        IOOptionBits
    ) = sIOKit ? dlsym(sIOKit, "IOHIDEventCreateUnicodeEvent") : NULL;
    if (!createUnicode) return false;
    NSData *payload = [@(text) dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    if (!payload.length || payload.length > UINT32_MAX) return false;
    IOHIDEventRef event = createUnicode(
        kCFAllocatorDefault,
        mach_absolute_time(),
        payload.bytes,
        (uint32_t)payload.length,
        1,
        0
    );
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

bool icli_open_url(const char *url) {
    icli_private_init();
    if (!url) {
        return false;
    }
    NSString *text = [NSString stringWithUTF8String:url];
    NSURL *u = text ? [NSURL URLWithString:text] : nil;
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

bool icli_wake(void) {
    icli_private_init();
    if (pSBSUndimScreen) {
        pSBSUndimScreen();
    }
    return icli_hid_button("home");
}
