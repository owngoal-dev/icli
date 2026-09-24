#import "IcliPrivate.h"
#import "IcliJSON.h"
#import "RegistrationInternal.h"
#import <Foundation/Foundation.h>

@interface NSObject (IcliLS)
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
- (NSArray *)allInstalledApplications;
- (BOOL)uninstallApplication:(NSString *)bundleID withOptions:(id)options;
- (BOOL)registerApplication:(NSURL *)url;
- (BOOL)unregisterApplication:(NSURL *)url;
- (BOOL)registerApplicationDictionary:(NSDictionary *)dict;
- (BOOL)registerContainerizedApplicationWithInfoDictionaries:(NSArray *)infos
                                               operationUUID:(NSUUID *)uuid
                                              requestContext:(id)context
                                                saveObserver:(id)observer
                                           registrationError:(NSError **)error;
@end

BOOL icli_ls_register_containerized(id workspace, NSDictionary *info, NSError **error) {
    SEL containerized = @selector(
    registerContainerizedApplicationWithInfoDictionaries:operationUUID:requestContext:saveObserver:registrationError:);
    if (!info || ![workspace respondsToSelector:containerized]) return NO;
    NSError *registrationError = nil;
    [workspace registerContainerizedApplicationWithInfoDictionaries:@[info]
                                                      operationUUID:[NSUUID UUID]
                                                     requestContext:nil
                                                       saveObserver:nil
                                                  registrationError:&registrationError];
    if (error) *error = registrationError;
    return registrationError == nil;
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
    return [NSFileManager.defaultManager
        fileExistsAtPath:[path stringByAppendingPathComponent:@"Settings.bundle/Root.plist"]];
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

/// What the containerized interface is given for a bundle outside any
/// container: the keys vpregister sends, the set shown to register
/// bootstrap apps on iOS 27, with the dictionary's application type, the
/// settings-bundle mark, and not deletable, as uicache registers them.
static NSDictionary *containerizedRecord(NSDictionary *dict, NSString *bundleID) {
    NSMutableDictionary *record = [@{
        @"Path": dict[@"Path"],
        @"CFBundleIdentifier": bundleID,
        @"CodeInfoIdentifier": bundleID,
        @"ApplicationType": dict[@"ApplicationType"],
        @"CompatibilityState": @0,
        @"SignerIdentity": @"Apple iPhone OS Application Signing",
        @"SignerOrganization": @"Apple Inc.",
        @"IsAdHocSigned": @YES,
        @"SignatureVersion": @132352,
        @"IsDeletable": @NO,
    } mutableCopy];
    if (dict[@"HasSettingsBundle"]) record[@"HasSettingsBundle"] = dict[@"HasSettingsBundle"];
    return record;
}

/// Registers `dict` (an Info.plist with Path and ApplicationType) through the
/// containerized interface, then waits up to a second for LaunchServices to
/// list this build of the bundle at its path.
static BOOL registerContainerized(id ws, NSDictionary *dict) {
    NSString *bundleID = dict[@"CFBundleIdentifier"];
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) return NO;
    if (!icli_ls_register_containerized(ws, containerizedRecord(dict, bundleID), NULL)) return NO;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (![proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)]) return NO;
    NSString *path = normalizedAppPath(dict[@"Path"]);
    for (int attempt = 0; attempt < 10; attempt++) {
        if (attempt) usleep(100 * 1000);
        id proxy = [proxyClass applicationProxyForIdentifier:bundleID];
        NSString *registeredPath = icli_ls_string(icli_ls_value(proxy, @"bundleURL"));
        if (registeredPath && [normalizedAppPath(registeredPath) isEqual:path])
            return registeredBuildIsCurrent(proxy, dict);
    }
    return NO;
}

/// On iOS 26, registerApplication: refused a new bundle (Saily's) and
/// answered YES for one it already had without reading it again, and it never
/// records HasSettingsBundle, without which the Settings app shows no page
/// for the app. So the record is read back, and one that is missing, of
/// another build or wrong about the settings bundle is registered from the
/// Info.plist instead, unless it holds what that registration would drop. A
/// registration whose record cannot be read back is left as it is, and one
/// that leaves a record of another build has failed.
///
/// iOS 27 answers registerApplicationDictionary: with NO and registers
/// nothing, so when that leaves no record of this build, the dictionary is
/// registered through the containerized interface, which works where lsd lets
/// the caller through. A current record wrong only about the settings bundle
/// is kept rather than replaced this way.
static BOOL registerAppAtPath(NSString *path) {
    id ws = icli_ls_workspace();
    if (!ws || path.length == 0) {
        return NO;
    }
    NSDictionary *info = [NSDictionary
        dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    BOOL hasSettingsBundle = bundleHasSettingsBundle(path);
    BOOL registered = [ws respondsToSelector:@selector(registerApplication:)]
        && [ws registerApplication:[NSURL fileURLWithPath:path]];
    id proxy = registeredAppsByPath()[normalizedAppPath(path)];
    if (proxy ? !recordIsReplaceable(proxy) : registered) {
        return registered;
    }
    BOOL current = registered && registeredBuildIsCurrent(proxy, info);
    if (current && [icli_ls_value(proxy, @"hasSettingsBundle") boolValue] == hasSettingsBundle) {
        return YES;
    }
    if (!info) {
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
    if ([ws respondsToSelector:@selector(registerApplicationDictionary:)] && [ws registerApplicationDictionary:dict]) {
        return YES;
    }
    return current || registerContainerized(ws, dict);
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
            for (NSString *component in suffix.reverseObjectEnumerator)
                path = [path stringByAppendingPathComponent:component];
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
    NSArray *apps = [ws respondsToSelector:@selector(allInstalledApplications)]
        ? [ws performSelector:@selector(allInstalledApplications)]
        : nil;
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
    if (!path) return icli_json_or_empty(@{@"registered": @NO});
    NSDictionary *apps = registeredAppsByPath();
    if (!apps) return icli_json_or_empty(@{@"error": @"LaunchServices application list unavailable"});
    id proxy = apps[normalizedAppPath(@(path))];
    if (!proxy) return icli_json_or_empty(@{@"registered": @NO, @"path": @(path)});
    NSMutableDictionary *result = [icli_ls_app_dictionary(proxy) mutableCopy];
    result[@"registered"] = @YES;
    return icli_json_or_empty(result);
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

static NSString *proxyBundleID(id proxy) {
    return icli_ls_string(icli_ls_value(proxy, @"applicationIdentifier"))
        ?: icli_ls_string(icli_ls_value(proxy, @"bundleIdentifier"));
}

/// Whether `path` is directly inside the directory that `prefix` (ending in "/") names.
static BOOL isDirectChild(NSString *path, NSString *prefix) {
    return [path hasPrefix:prefix] && ![[path substringFromIndex:prefix.length] containsString:@"/"];
}

/// Reconcile by bundle ID, resolved path and build, so an app updated in
/// place is registered again when registerAppAtPath can replace its record.
/// Re-registering unchanged apps can terminate them (upstream uikittools-ng
/// 627e1ee). A moved app must be
/// registered before removing stale paths, since both records share an ID.
char *icli_apps_refresh_json(const char *directory) {
    icli_private_init();
    if (!directory) return icli_json_or_empty(@{@"error": @"directory required"});
    NSString *root = normalizedAppPath(@(directory));
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory)
        return icli_json_or_empty(@{@"error": [@"not a directory: " stringByAppendingString:root]});
    NSError *error = nil;
    NSArray *paths = appBundlesInDirectory(root, &error);
    if (!paths)
        return icli_json_or_empty(@{@"error": error.localizedDescription ?: @"could not list application directory"});
    NSDictionary *before = registeredAppsByPath();
    if (!before) return icli_json_or_empty(@{@"error": @"LaunchServices application list unavailable"});
    NSMutableDictionary *installed = [NSMutableDictionary dictionary];
    NSMutableDictionary *infos = [NSMutableDictionary dictionary];
    for (NSString *path in paths) {
        NSDictionary *info = [NSDictionary
            dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
        NSString *bundleID = info[@"CFBundleIdentifier"];
        if (![bundleID isKindOfClass:NSString.class] || !bundleID.length)
            return icli_json_or_empty(@{@"error": [@"missing bundle identifier: " stringByAppendingString:path]});
        if (installed[bundleID])
            return icli_json_or_empty(@{@"error": [@"duplicate bundle identifier: " stringByAppendingString:bundleID]});
        installed[bundleID] = path;
        infos[bundleID] = info;
    }
    NSMutableArray *registered = [NSMutableArray array],
        *failed = [NSMutableArray array],
        *unregistered = [NSMutableArray array],
        *unchanged = [NSMutableArray array];
    for (NSString *bundleID in [[installed allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *path = installed[bundleID];
        id proxy = before[normalizedAppPath(path)];
        NSString *registeredID = proxyBundleID(proxy);
        if ([registeredID isEqual:bundleID] && (registeredBuildIsCurrent(proxy, infos[bundleID]) || !recordIsReplaceable(proxy))) {
            [unchanged addObject:path];
            continue;
        }
        if (registerAppAtPath(path)) [registered addObject:path];
        else [failed addObject:path];
    }
    NSString *prefix = [root stringByAppendingString:@"/"];
    NSDictionary *byPath = registeredAppsByPath();
    if (!byPath)
        return icli_json_or_empty(@{@"error": @"LaunchServices application list unavailable after registration"});
    for (NSString *path in [[byPath allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (!isDirectChild(path, prefix) || [NSFileManager.defaultManager fileExistsAtPath:path]) continue;
        NSString *bundleID = proxyBundleID(byPath[path]);
        // Do not unregister the same ID we just moved (or failed to move).
        if (bundleID && installed[bundleID]) continue;
        if (icli_unregister_app(path.UTF8String)) [unregistered addObject:path];
        else [failed addObject:path];
    }
    NSDictionary *after = registeredAppsByPath();
    if (!after)
        return icli_json_or_empty(@{@"error": @"LaunchServices application list unavailable during verification"});
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *bundleID in installed) {
        NSString *path = installed[bundleID];
        id proxy = after[normalizedAppPath(path)];
        NSString *registeredID = proxyBundleID(proxy);
        if (![registeredID isEqual:bundleID]) [missing addObject:path];
    }
    for (NSString *path in unregistered) if (after[path]) [missing addObject:path];
    return icli_json_or_empty(@{
        @"directory": root,
        @"registered": registered,
        @"unchanged": unchanged,
        @"unregistered": unregistered,
        @"failed": failed,
        @"unverified": missing
    });
}

/// Unregisters every registered application whose bundle lives directly in `directory`.
char *icli_apps_unregister_directory_json(const char *directory) {
    icli_private_init();
    if (!directory) return icli_json_or_empty(@{@"error": @"directory required"});
    NSString *root = normalizedAppPath(@(directory));
    NSString *prefix = [root stringByAppendingString:@"/"];
    NSMutableArray *unregistered = [NSMutableArray array], *failed = [NSMutableArray array];
    for (NSString *path in registeredAppsByPath()) {
        if (!isDirectChild(path, prefix)) continue;
        if (icli_unregister_app(path.UTF8String)) [unregistered addObject:path];
        else [failed addObject:path];
    }
    NSDictionary *after = registeredAppsByPath();
    NSMutableArray *remaining = [NSMutableArray array];
    for (NSString *path in unregistered) if (after[path]) [remaining addObject:path];
    return icli_json_or_empty(@{
        @"directory": root,
        @"unregistered": unregistered,
        @"failed": failed,
        @"unverified": remaining
    });
}
