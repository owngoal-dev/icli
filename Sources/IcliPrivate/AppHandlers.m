#import "IcliPrivate.h"
#import "IcliJSON.h"
#import "OpenURLInternal.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>

@interface NSObject (IcliLS)
- (NSArray *)applicationsAvailableForOpeningURL:(NSURL *)url;
- (NSArray *)applicationsAvailableForHandlingURLScheme:(NSString *)scheme;
@end

char *icli_app_handlers_json(const char *url_or_scheme) {
    if (!url_or_scheme) {
        return icli_json_or_empty(@{@"error": @"missing url"});
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
    return icli_json_or_empty(@{
        @"url": arg,
        @"scheme": scheme,
        @"apps": apps,
        @"count": @(apps.count),
    });
}

// Opens `url` through FrontBoard's system service; true only when its
// completion handler reports no error. On tvOS (no SpringBoard) a nil bundle
// id is resolved through LaunchServices. A failure sets `*reason`.
bool icli_frontboard_open_url(NSURL *url, NSString *bundleID, NSString **reason) {
    if (reason) *reason = nil;
    if (!url) {
        if (reason) *reason = @"invalid url";
        return false;
    }
    if (!bundleID.length) {
        id ws = icli_ls_workspace();
        NSArray *proxies = [ws respondsToSelector:@selector(applicationsAvailableForOpeningURL:)]
            ? [ws applicationsAvailableForOpeningURL:url]
            : nil;
        if (!proxies.count && url.scheme && [ws respondsToSelector:@selector(applicationsAvailableForHandlingURLScheme:)])
            proxies = [ws applicationsAvailableForHandlingURLScheme:url.scheme];
        bundleID = proxies.count ? icli_ls_app_dictionary(proxies.firstObject)[@"bundle_id"] : nil;
        if (!bundleID.length) {
            if (reason) *reason = @"no app handles this url";
            return false;
        }
    }
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    Class serviceClass = NSClassFromString(@"FBSSystemService");
    SEL sharedService = NSSelectorFromString(@"sharedService");
    SEL open = NSSelectorFromString(@"openURL:application:options:clientPort:withResult:");
    id service = [serviceClass respondsToSelector:sharedService]
        ? ((id (*)(id, SEL))objc_msgSend)(serviceClass, sharedService)
        : nil;
    if (![service respondsToSelector:open]) {
        if (reason) *reason = @"FrontBoard open service unavailable";
        return false;
    }
    __block NSError *openError = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    ((void (*)(id, SEL, id, id, id, unsigned int, id))objc_msgSend)(service, open, url, bundleID, @{}, 0, ^(NSError *error) {
        openError = error;
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
        if (reason) *reason = @"FrontBoard did not answer the open request";
        return false;
    }
    if (openError) {
        if (reason) *reason = openError.localizedFailureReason ?: openError.localizedDescription ?: @"open failed";
        return false;
    }
    return true;
}

bool icli_open_url_in_app(const char *url, const char *bundle_id, char **reason) {
    if (reason) *reason = NULL;
    if (!url) {
        if (reason) *reason = strdup("invalid url");
        return false;
    }
    if (!bundle_id || !bundle_id[0]) {
        return icli_open_url(url);
    }
    NSString *text = [NSString stringWithUTF8String:url];
    NSURL *u = text ? [NSURL URLWithString:text] : nil;
    NSString *bid = [NSString stringWithUTF8String:bundle_id];
    if (!u || !bid.length) {
        if (reason) *reason = strdup("invalid url");
        return false;
    }
    NSString *r = nil;
    bool ok = icli_frontboard_open_url(u, bid, &r);
    if (!ok && reason && r.length) *reason = strdup(r.UTF8String);
    return ok;
}
