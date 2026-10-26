#import "IcliPrivate.h"
#import "IcliJSON.h"
#import "OpenURLInternal.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>

@interface NSObject (IcliLS)
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(id)options;
- (NSArray *)applicationsAvailableForOpeningURL:(NSURL *)url;
- (NSArray *)applicationsAvailableForHandlingURLScheme:(NSString *)scheme;
- (id)operationToOpenResource:(NSURL *)url usingApplication:(NSString *)bundleID userInfo:(id)userInfo;
- (BOOL)openURL:(NSURL *)url withOptions:(id)options;
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

#if TARGET_OS_TV
// LaunchServices hands a URL to SpringBoard, which tvOS does not run, so
// there FrontBoard's system service opens it in the app that handles it
// (LaunchServices still answers which one), through PineBoard.
bool icli_frontboard_open_url(NSURL *url, NSString *bundleID) {
    if (!url) return false;
    if (!bundleID.length) {
        id ws = icli_ls_workspace();
        NSArray *proxies = [ws respondsToSelector:@selector(applicationsAvailableForOpeningURL:)]
            ? [ws applicationsAvailableForOpeningURL:url]
            : nil;
        if (!proxies.count && url.scheme && [ws respondsToSelector:@selector(applicationsAvailableForHandlingURLScheme:)])
            proxies = [ws applicationsAvailableForHandlingURLScheme:url.scheme];
        bundleID = proxies.count ? icli_ls_app_dictionary(proxies.firstObject)[@"bundle_id"] : nil;
        if (!bundleID.length) return false;
    }
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    Class serviceClass = NSClassFromString(@"FBSSystemService");
    SEL sharedService = NSSelectorFromString(@"sharedService");
    SEL open = NSSelectorFromString(@"openURL:application:options:clientPort:withResult:");
    id service = [serviceClass respondsToSelector:sharedService]
        ? ((id (*)(id, SEL))objc_msgSend)(serviceClass, sharedService)
        : nil;
    if (![service respondsToSelector:open]) return false;
    __block BOOL opened = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    ((void (*)(id, SEL, id, id, id, unsigned int, id))objc_msgSend)(service, open, url, bundleID, @{}, 0, ^(NSError *error) {
        opened = error == nil;
        dispatch_semaphore_signal(done);
    });
    return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0 && opened;
}
#endif

bool icli_open_url_in_app(const char *url, const char *bundle_id) {
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
#if TARGET_OS_TV
    return icli_frontboard_open_url(u, bid);
#endif
    id ws = icli_ls_workspace();
    if ([ws respondsToSelector:@selector(operationToOpenResource:usingApplication:userInfo:)]) {
        id op = [ws operationToOpenResource:u usingApplication:bid userInfo:nil];
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
