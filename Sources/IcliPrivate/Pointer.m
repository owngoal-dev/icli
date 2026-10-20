#import "IcliPrivate.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <unistd.h>

// A virtual pointing device: a mouse with an absolute position, three buttons,
// a wheel and a horizontal pan, as a HID user device. iPadOS shows its pointer
// and puts it where a report says, in the interface's own orientation
// (measured on iPadOS 26 in portrait and landscape); the pointer hides itself
// when it has been still for a few seconds. iOS on an iPhone takes the device
// only through AssistiveTouch's pointer devices.
//
// Reports carry the position only. Buttons and scrolling are dispatched as
// events with the device's event service as their sender: with any other
// sender (the touchscreen's included) they reach nothing, or the view at the
// top-left corner. A button change is a pointer event that has not moved,
// with a button event inside it. backboardd keeps each sender's buttons from
// those button events: a report's button bits press a button there but never
// release it, so the button stayed down for as long as the device lived and
// every later click of every pointing device was lost (iPadOS 26.6.2). A click
// made this way is a pointer click, the same as a trackpad's, and not a touch.
//
// The device is created on first use and lives as long as the process, so a
// pointer that a command leaves behind goes away when the command exits.
// Every entry point is resolved with dlsym.

typedef void *IcliHIDEventSystemClientRef;
typedef void *IcliHIDEventRef;
typedef void *IcliHIDUserDeviceRef;
typedef unsigned int IcliIOObject;

static IcliHIDEventSystemClientRef (*pClientCreate)(CFAllocatorRef);
static void (*pDispatch)(IcliHIDEventSystemClientRef, IcliHIDEventRef);
static void (*pSetSender)(IcliHIDEventRef, uint64_t);
static IcliHIDEventRef (*pScroll)(CFAllocatorRef, uint64_t, double, double, double, uint32_t);
static void (*pSetPhase)(IcliHIDEventRef, uint32_t);
static IcliHIDEventRef (*pRelativePointer)(CFAllocatorRef, uint64_t, double, double, double, uint32_t, uint32_t);
static IcliHIDEventRef (*pButton)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t);
static void (*pAppend)(IcliHIDEventRef, IcliHIDEventRef, uint32_t);
static void (*pSetInteger)(IcliHIDEventRef, uint32_t, long);
static IcliHIDUserDeviceRef (*pDeviceCreate)(CFAllocatorRef, CFDictionaryRef);
static int (*pHandleReport)(IcliHIDUserDeviceRef, const uint8_t *, CFIndex);
static CFMutableDictionaryRef (*pMatching)(const char *);
static int (*pMatchingServices)(unsigned int, CFDictionaryRef, IcliIOObject *);
static IcliIOObject (*pNext)(IcliIOObject);
static CFTypeRef (*pSearchProperty)(IcliIOObject, const char *, CFStringRef, CFAllocatorRef, uint32_t);
static int (*pEntryID)(IcliIOObject, uint64_t *);
static int (*pRelease)(IcliIOObject);

static bool sPointerLoaded;
static IcliHIDEventSystemClientRef sPointerClient;
static IcliHIDUserDeviceRef sPointerDevice;
static uint64_t sPointerSender;
static uint8_t sPointerButtons;
static uint16_t sPointerX, sPointerY;
static uint64_t sPointerReportTime;

// The event service over the device is found again by its product name, and
// buttons and scrolling are sent with that service as their sender. Each
// process names its own device, so one running beside another (vphoned and a
// `screen click`) never sends its clicks as the other's.
static NSString *pointerProduct(void) {
    static NSString *product;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        product = [NSString stringWithFormat:@"icli pointer %d", getpid()];
    });
    return product;
}

// Three buttons, an absolute X and Y within 0...32767, a wheel and a
// horizontal pan (never turned: scrolling is dispatched as scroll events).
// Without the wheel and the pan iPadOS shows the pointer but sends the scroll
// events nowhere.
static const uint8_t kPointerDescriptor[] = {
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x05, 0x81, 0x03,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
    0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
    0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
    0xC0, 0xC0,
};
static const double kPointerMaximum = 32767;

// kIORegistryIterateRecursively | kIORegistryIterateParents
#define ICLI_SEARCH_UP 3u

static bool loadPointerSymbols(void) {
    if (sPointerLoaded) return true;
    void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!ioKit) return false;
#define SYM(p, name) p = (typeof(p))dlsym(ioKit, name)
    SYM(pClientCreate, "IOHIDEventSystemClientCreate");
    SYM(pDispatch, "IOHIDEventSystemClientDispatchEvent");
    SYM(pSetSender, "IOHIDEventSetSenderID");
    SYM(pScroll, "IOHIDEventCreateScrollEvent");
    SYM(pSetPhase, "IOHIDEventSetPhase");
    SYM(pRelativePointer, "IOHIDEventCreateRelativePointerEvent");
    SYM(pButton, "IOHIDEventCreateButtonEvent");
    SYM(pAppend, "IOHIDEventAppendEvent");
    SYM(pSetInteger, "IOHIDEventSetIntegerValue");
    SYM(pDeviceCreate, "IOHIDUserDeviceCreate");
    SYM(pHandleReport, "IOHIDUserDeviceHandleReport");
    SYM(pMatching, "IOServiceMatching");
    SYM(pMatchingServices, "IOServiceGetMatchingServices");
    SYM(pNext, "IOIteratorNext");
    SYM(pSearchProperty, "IORegistryEntrySearchCFProperty");
    SYM(pEntryID, "IORegistryEntryGetRegistryEntryID");
    SYM(pRelease, "IOObjectRelease");
#undef SYM
    sPointerLoaded = pClientCreate && pDispatch && pSetSender && pScroll && pSetPhase && pRelativePointer &&
                     pButton && pAppend && pSetInteger && pDeviceCreate && pHandleReport && pMatching &&
                     pMatchingServices && pNext && pSearchProperty && pEntryID && pRelease;
    return sPointerLoaded;
}

// The registry ID of the event service iOS put over the device, which is the
// sender its own events carry.
static uint64_t findPointerSender(void) {
    IcliIOObject iterator = 0;
    if (pMatchingServices(0, pMatching("IOHIDEventService"), &iterator) != 0) return 0;
    uint64_t found = 0;
    IcliIOObject service;
    while ((service = pNext(iterator))) {
        CFTypeRef product = pSearchProperty(service, "IOService", CFSTR("Product"), kCFAllocatorDefault, ICLI_SEARCH_UP);
        if (!found && product && CFGetTypeID(product) == CFStringGetTypeID() &&
            CFStringCompare(product, (__bridge CFStringRef)pointerProduct(), 0) == kCFCompareEqualTo) {
            pEntryID(service, &found);
        }
        if (product) CFRelease(product);
        pRelease(service);
    }
    pRelease(iterator);
    return found;
}

// On the pointer queue. The event service appears a moment after the device;
// waits up to a second for it.
static int ensurePointer(void) {
    if (sPointerSender) return ICLI_POINTER_OK;
    if (!loadPointerSymbols()) return ICLI_POINTER_UNAVAILABLE;
    if (!sPointerClient) sPointerClient = pClientCreate(kCFAllocatorDefault);
    if (!sPointerClient) return ICLI_POINTER_UNAVAILABLE;
    if (!sPointerDevice) {
        NSDictionary *properties = @{
            @"ReportDescriptor": [NSData dataWithBytes:kPointerDescriptor length:sizeof(kPointerDescriptor)],
            @"VendorID": @0x05AC,
            @"ProductID": @0x7650,
            @"Product": pointerProduct(),
            @"SerialNumber": [NSString stringWithFormat:@"%d", getpid()],
            @"Transport": @"USB",
            @"PrimaryUsagePage": @1,
            @"PrimaryUsage": @2,
        };
        sPointerDevice = pDeviceCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)properties);
        if (!sPointerDevice) return ICLI_POINTER_REFUSED;
    }
    for (int attempt = 0; attempt < 50 && !sPointerSender; attempt++) {
        sPointerSender = findPointerSender();
        if (!sPointerSender) usleep(20000);
    }
    return sPointerSender ? ICLI_POINTER_OK : ICLI_POINTER_NOT_READY;
}

static dispatch_queue_t pointerQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        queue = dispatch_queue_create("icli.pointer", attributes);
    });
    return queue;
}

// On the pointer queue. The position; the button bits stay clear.
static int sendPointerReport(void) {
    const uint8_t report[7] = {0, sPointerX & 0xFF, sPointerX >> 8, sPointerY & 0xFF, sPointerY >> 8, 0, 0};
    int result = pHandleReport(sPointerDevice, report, sizeof(report)) == 0 ? ICLI_POINTER_OK : ICLI_POINTER_FAILED;
    sPointerReportTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    return result;
}

// A report reaches backboardd through the device's driver, an event straight
// from here, so a button pressed right after a move could land where the
// pointer was before it. A button change waits until the last report is this
// old: twice the device's 8 ms report interval.
static const uint64_t kPointerReportSettleNanoseconds = 20 * NSEC_PER_MSEC;

// On the pointer queue. Holds `buttons` from now on, where the pointer is.
static int setPointerButtons(uint8_t buttons) {
    if (buttons == sPointerButtons) return ICLI_POINTER_OK;
    uint64_t since = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - sPointerReportTime;
    if (since < kPointerReportSettleNanoseconds) {
        usleep((useconds_t)((kPointerReportSettleNanoseconds - since) / NSEC_PER_USEC));
    }
    uint64_t now = mach_absolute_time();
    IcliHIDEventRef pointer = pRelativePointer(kCFAllocatorDefault, now, 0, 0, 0, buttons, 0);
    IcliHIDEventRef button = pButton(kCFAllocatorDefault, now, buttons, buttons ? 1 : 0, 0);
    int result = ICLI_POINTER_FAILED;
    if (pointer && button) {
        // kIOHIDEventFieldButtonMask: what backboardd reads the buttons from.
        pSetInteger(button, 2u << 16, buttons);
        pAppend(pointer, button, 0);
        pSetSender(pointer, sPointerSender);
        pDispatch(sPointerClient, pointer);
        sPointerButtons = buttons;
        result = ICLI_POINTER_OK;
    }
    if (button) CFRelease(button);
    if (pointer) CFRelease(pointer);
    return result;
}

int icli_pointer_move(double x, double y, int buttons) {
    __block int result;
    dispatch_sync(pointerQueue(), ^{
        result = ensurePointer();
        if (result != ICLI_POINTER_OK) return;
        sPointerX = (uint16_t)lround(fmin(fmax(x, 0), 1) * kPointerMaximum);
        sPointerY = (uint16_t)lround(fmin(fmax(y, 0), 1) * kPointerMaximum);
        result = sendPointerReport();
        if (result == ICLI_POINTER_OK && buttons >= 0) result = setPointerButtons((uint8_t)(buttons & 0x7));
    });
    return result;
}

int icli_pointer_buttons(int buttons) {
    __block int result;
    dispatch_sync(pointerQueue(), ^{
        result = ensurePointer();
        if (result != ICLI_POINTER_OK) return;
        result = setPointerButtons((uint8_t)(buttons & 0x7));
    });
    return result;
}

int icli_pointer_scroll(int phase, double dx, double dy) {
    __block int result;
    dispatch_sync(pointerQueue(), ^{
        result = ensurePointer();
        if (result != ICLI_POINTER_OK) return;
        IcliHIDEventRef event = pScroll(kCFAllocatorDefault, mach_absolute_time(), dx, dy, 0, 0);
        if (!event) {
            result = ICLI_POINTER_FAILED;
            return;
        }
        pSetPhase(event, (uint32_t)phase);
        pSetSender(event, sPointerSender);
        pDispatch(sPointerClient, event);
        CFRelease(event);
    });
    return result;
}
