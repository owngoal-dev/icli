#import "IcliPrivate.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

static id audioController(void) {
    static id controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_NOW);
        Class cls = NSClassFromString(@"AVSystemController");
        SEL shared = NSSelectorFromString(@"sharedAVSystemController");
        if ([cls respondsToSelector:shared]) controller = ((id(*)(id,SEL))objc_msgSend)(cls,shared);
    });
    return controller;
}
static NSDictionary *audioState(id controller) {
    SEL getVolume = NSSelectorFromString(@"getActiveCategoryVolume:andName:");
    SEL getMute = NSSelectorFromString(@"getActiveCategoryMuted:");
    float volume = 0; NSString *category = nil; BOOL muted = NO;
    if (![controller respondsToSelector:getVolume] || ![controller respondsToSelector:getMute] ||
        !((BOOL(*)(id,SEL,float *,NSString **))objc_msgSend)(controller,getVolume,&volume,&category) ||
        !((BOOL(*)(id,SEL,BOOL *))objc_msgSend)(controller,getMute,&muted)) return @{@"error": @"active audio state unavailable"};
    return @{@"active_volume": @(volume), @"active_category": category ?: @"", @"active_muted": @(muted)};
}
static char *audioJSON(NSDictionary *result) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : NULL;
}
char *icli_active_audio_json(void) { return audioJSON(audioState(audioController())); }
char *icli_audio_button_json(const char *button) {
    id controller = audioController();
    NSString *name = @(button);
    BOOL mute = [name isEqual:@"mute"], up = [name isEqual:@"volume-up"];
    if (!mute && !up && ![name isEqual:@"volume-down"]) return audioJSON(@{@"error": @"invalid audio button"});
    NSDictionary *before = audioState(controller);
    if (before[@"error"]) return audioJSON(before);
    if (!icli_hid_button(button)) return audioJSON(@{@"error": @"audio HID event unavailable"});
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    NSDictionary *after = audioState(controller);
    NSString *key = mute ? @"active_muted" : @"active_volume";
    NSString *method = @"hid";
    if ([before[key] isEqual:after[key]]) {
        if (mute) {
            SEL toggle = NSSelectorFromString(@"toggleActiveCategoryMuted");
            if (![controller respondsToSelector:toggle] || !((BOOL(*)(id,SEL))objc_msgSend)(controller,toggle)) return audioJSON(@{@"error": @"audio mute control unavailable"});
        } else {
            SEL change = NSSelectorFromString(@"changeActiveCategoryVolume:");
            if (![controller respondsToSelector:change] || !((BOOL(*)(id,SEL,BOOL))objc_msgSend)(controller,change,up)) return audioJSON(@{@"error": @"audio volume control unavailable"});
        }
        method = @"audio_control";
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        after = audioState(controller);
    }
    if (after[@"error"]) return audioJSON(after);
    BOOL boundary = !mute && (up ? [before[key] doubleValue] >= 1 : [before[key] doubleValue] <= 0);
    if (!boundary && [before[key] isEqual:after[key]]) return audioJSON(@{@"error": @"system did not apply the requested audio change"});
    NSMutableDictionary *result = [after mutableCopy];
    result[@"button"] = name; result[@"method"] = method; result[@"before"] = before;
    return audioJSON(result);
}
