#import "IcliSystemPrivate.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>

// LaunchServices' application registrations, read through LSApplicationWorkspace
// and its proxies. The class is looked up at runtime and its framework is
// dlopened, so nothing here links MobileCoreServices; a platform without the
// class reports an empty list instead of failing.

@interface NSObject (IcliSystemLS)
+ (id)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

void icli_string_free(char *s) {
    free(s);
}

id icli_ls_workspace(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    });
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (![wsClass respondsToSelector:@selector(defaultWorkspace)]) {
        return nil;
    }
    return [wsClass performSelector:@selector(defaultWorkspace)];
}

id icli_ls_value(id proxy, NSString *key) {
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

NSString *icli_ls_string(id value) {
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

NSDictionary *icli_ls_app_dictionary(id proxy) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSString *bundleID = icli_ls_string(icli_ls_value(proxy, @"applicationIdentifier")) ?: icli_ls_string(icli_ls_value(proxy, @"bundleIdentifier"));
    NSString *name = icli_ls_string(icli_ls_value(proxy, @"localizedName"));
    NSString *bundlePath = icli_ls_string(icli_ls_value(proxy, @"bundleURL"));
    NSString *dataPath = icli_ls_string(icli_ls_value(proxy, @"dataContainerURL"));
    NSString *version = icli_ls_string(icli_ls_value(proxy, @"shortVersionString"));
    NSString *build = icli_ls_string(icli_ls_value(proxy, @"bundleVersion"));
    NSString *type = icli_ls_string(icli_ls_value(proxy, @"applicationType"));
    NSString *signer = icli_ls_string(icli_ls_value(proxy, @"signerIdentity")) ?: icli_ls_string(icli_ls_value(proxy, @"teamID"));
    if (bundleID) d[@"bundle_id"] = bundleID;
    if (name) d[@"name"] = name;
    if (bundlePath) d[@"bundle_path"] = bundlePath;
    if (dataPath) d[@"data_path"] = dataPath;
    id groups = icli_ls_value(proxy, @"groupContainerURLs");
    NSMutableDictionary *groupPaths = [NSMutableDictionary dictionary];
    if ([groups isKindOfClass:NSDictionary.class]) {
        for (NSString *key in groups) {
            NSString *path = icli_ls_string(groups[key]);
            if (path) groupPaths[key] = path;
        }
    }
    d[@"group_containers"] = groupPaths;
    if (version) d[@"version"] = version;
    if (build) d[@"build"] = build;
    if (type) d[@"type"] = type;
    if (signer) d[@"signer"] = signer;
    id running = icli_ls_value(proxy, @"isRunning");
    if ([running respondsToSelector:@selector(boolValue)]) {
        d[@"running"] = @([running boolValue]);
    }
    id schemes = icli_ls_value(proxy, @"claimedURLSchemes");
    if ([schemes isKindOfClass:[NSArray class]] && [schemes count] > 0) {
        d[@"schemes"] = schemes;
    }
    return d;
}

char *icli_apps_json(void) {
    id ws = icli_ls_workspace();
    NSArray *apps = nil;
    if ([ws respondsToSelector:@selector(allInstalledApplications)]) {
        apps = [ws performSelector:@selector(allInstalledApplications)];
    }
    NSMutableArray *out = [NSMutableArray array];
    for (id proxy in apps) {
        [out addObject:icli_ls_app_dictionary(proxy)];
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
