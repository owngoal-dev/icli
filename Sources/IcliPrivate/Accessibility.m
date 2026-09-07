#import "IcliPrivate.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

// AXRuntime numeric attributes: verified on the rootless TestHost and compared
// with witchan/ios-mcp (8f46b68). String AX attributes are absent on this runtime.
typedef CFTypeRef AXElement;
static AXElement (*createApp)(pid_t);
static int (*copyAttribute)(AXElement, CFStringRef, CFTypeRef *);
static int (*setTimeout)(AXElement, float);
static Boolean (*getAXValue)(CFTypeRef, int, void *);
static int (*hitTest)(AXElement, AXElement *, float, float);

static char *axJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : NULL;
}

static BOOL prepareAX(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *ax = dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW);
        void *accessibility = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
        void (*enable)(BOOL) = accessibility ? dlsym(accessibility, "_AXSApplicationAccessibilitySetEnabled") : NULL;
        void (*automation)(BOOL) = accessibility ? dlsym(accessibility, "_AXSSetAutomationEnabled") : NULL;
        if (enable) enable(YES);
        if (automation) automation(YES);
        if (!ax) return;
        void (*client)(uint32_t) = dlsym(ax, "__AXSetRequestingClient");
        if (client) client(2);
        uint64_t (*override)(uint64_t) = dlsym(ax, "_AXOverrideRequestingClientType");
        if (override) override(2);
        createApp = dlsym(ax, "_AXUIElementCreateAppElementWithPid");
        copyAttribute = dlsym(ax, "AXUIElementCopyAttributeValue");
        setTimeout = dlsym(ax, "AXUIElementSetMessagingTimeout");
        getAXValue = dlsym(ax, "AXValueGetValue");
        hitTest = dlsym(ax, "AXUIElementCopyElementAtPosition");
    });
    return createApp && copyAttribute && getAXValue;
}

static id attribute(AXElement element, uint32_t key) {
    CFTypeRef value = NULL;
    int error = copyAttribute(element, (CFStringRef)(uintptr_t)key, &value);
    if (error) { if (value) CFRelease(value); return nil; }
    return CFBridgingRelease(value);
}

static NSDictionary *serializeElement(AXElement element) {
    if (setTimeout) setTimeout(element, 0.25f);
    id value = attribute(element, 2003);
    CGRect frame = CGRectZero;
    if (!value || !getAXValue((__bridge CFTypeRef)value, 3, &frame) || !isfinite(frame.origin.x) || !isfinite(frame.origin.y) || !isfinite(frame.size.width) || !isfinite(frame.size.height)) return nil;
    id label = attribute(element, 2001);
    id text = attribute(element, 2006);
    id identifier = attribute(element, 5019);
    id traitsValue = attribute(element, 2004);
    uint64_t traits = [traitsValue respondsToSelector:@selector(unsignedLongLongValue)] ? [traitsValue unsignedLongLongValue] : 0;
    BOOL enabled = (traits & UIAccessibilityTraitNotEnabled) == 0;
    BOOL clickable = enabled && frame.size.width > 0 && frame.size.height > 0 && ((traits & (UIAccessibilityTraitButton | UIAccessibilityTraitLink | UIAccessibilityTraitAdjustable)) != 0 || (traits & UIAccessibilityTraitStaticText) == 0);
    NSString *role = (traits & UIAccessibilityTraitButton) ? @"button" : ((traits & UIAccessibilityTraitStaticText) ? @"text" : @"element");
    IcliScreenMetrics metrics = icli_screen_metrics();
    CGRect screen = CGRectMake(0, 0, metrics.width, metrics.height);
    CGPoint point = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    id pointValue = attribute(element, 2007);
    if (pointValue) getAXValue((__bridge CFTypeRef)pointValue, 1, &point);
    NSMutableDictionary *node = [@{
        @"label": [label isKindOfClass:NSString.class] ? label : @"",
        @"identifier": [identifier isKindOfClass:NSString.class] ? identifier : @"",
        @"value": [text isKindOfClass:NSString.class] || [text isKindOfClass:NSNumber.class] ? text : @"",
        @"role": role, @"traits": @(traits), @"enabled": @(enabled), @"clickable": @(clickable),
        @"visible": @(!CGRectIsEmpty(CGRectIntersection(frame, screen))),
        @"frame": @{@"x": @(frame.origin.x), @"y": @(frame.origin.y), @"width": @(frame.size.width), @"height": @(frame.size.height)},
        @"x": @(point.x), @"y": @(point.y)
    } mutableCopy];
    return node;
}

char *icli_ax_elements_json(int pid, int max_elements) {
    if (pid <= 0 || max_elements < 1 || max_elements > 2000) return axJSON(@{@"error": @"invalid AX query"});
    if (!prepareAX()) return axJSON(@{@"error": @"AX runtime unavailable"});
    AXElement root = createApp(pid);
    if (!root) return axJSON(@{@"error": @"AX application unavailable"});
    if (setTimeout) setTimeout(root, 0.5f);
    CFTypeRef value = NULL;
    int error = copyAttribute(root, (CFStringRef)(uintptr_t)3015, &value);
    CFRelease(root);
    if (error || !value || CFGetTypeID(value) != CFArrayGetTypeID()) {
        if (value) CFRelease(value);
        return axJSON(@{@"error": [NSString stringWithFormat:@"AX element query failed (%d)", error], @"pid": @(pid)});
    }
    NSArray *elements = CFBridgingRelease(value);
    NSMutableArray *rows = [NSMutableArray array];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 5;
    BOOL truncated = NO;
    for (id element in elements) {
        if (rows.count >= (NSUInteger)max_elements || NSProcessInfo.processInfo.systemUptime >= deadline) { truncated = YES; break; }
        NSDictionary *node = serializeElement((__bridge AXElement)element);
        if (node) [rows addObject:node];
    }
    return axJSON(@{@"source": @"ax", @"pid": @(pid), @"elements": rows, @"count": @(rows.count), @"truncated": @(truncated)});
}

char *icli_ax_element_at_json(int pid, double x, double y) {
    if (pid <= 0 || !prepareAX() || !hitTest) return axJSON(@{@"error": @"AX hit testing unavailable"});
    AXElement root = createApp(pid), hit = NULL;
    if (!root) return axJSON(@{@"error": @"AX application unavailable"});
    if (setTimeout) setTimeout(root, 0.5f);
    int error = hitTest(root, &hit, (float)x, (float)y);
    CFRelease(root);
    if (error) { if (hit) CFRelease(hit); return axJSON(@{@"error": [NSString stringWithFormat:@"AX hit testing failed (%d)", error]}); }
    NSDictionary *node = hit ? serializeElement(hit) : nil;
    if (hit) CFRelease(hit);
    return axJSON(@{@"source": @"ax", @"element": node ?: @{}, @"x": @(x), @"y": @(y)});
}
