#import "IcliPrivate.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>

// MobileContainerManager containers, the way installd keeps them: an app's
// bundle container under /var/containers/Bundle/Application and its data,
// plug-in and group containers under /var/mobile/Containers. Every call goes
// through containermanagerd; nothing here creates or deletes the directories
// itself.

@interface NSObject (IcliMCM)
+ (id)containerWithIdentifier:(NSString *)identifier createIfNecessary:(BOOL)create existed:(BOOL *)existed error:(NSError **)error;
- (NSURL *)url;
- (id)destroyContainerWithCompletion:(void (^)(id))completion;
- (BOOL)registerApplicationDictionary:(NSDictionary *)dict;
- (BOOL)registerContainerizedApplicationWithInfoDictionaries:(NSArray *)infos operationUUID:(NSUUID *)uuid requestContext:(id)context saveObserver:(id)observer registrationError:(NSError **)error;
@end

static char *containerJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : strdup("{}");
}

static Class containerClass(const char *kind) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_NOW);
    });
    NSDictionary *classes = @{
        @"app": @"MCMAppContainer",
        @"data": @"MCMAppDataContainer",
        @"plugin": @"MCMPluginKitPluginDataContainer",
        @"group": @"MCMSharedDataContainer",
        @"system-group": @"MCMSystemDataContainer",
    };
    NSString *name = kind ? classes[@(kind)] : nil;
    Class cls = name ? NSClassFromString(name) : Nil;
    return [cls respondsToSelector:@selector(containerWithIdentifier:createIfNecessary:existed:error:)] ? cls : Nil;
}

/// The existing container, or nil and no error when there is none.
static id lookupContainer(Class cls, NSString *identifier, BOOL create, BOOL *existed, NSError **error) {
    id container = [cls containerWithIdentifier:identifier createIfNecessary:create existed:existed error:error];
    if (!create && !container) *error = nil;
    return container;
}

char *icli_container_json(const char *kind, const char *identifier, bool create) {
    Class cls = containerClass(kind);
    if (!cls) return containerJSON(@{@"error": @"MobileContainerManager is unavailable"});
    if (!identifier || !identifier[0]) return containerJSON(@{@"error": @"container identifier required"});
    BOOL existed = NO;
    NSError *error = nil;
    id container = lookupContainer(cls, @(identifier), create, &existed, &error);
    NSString *path = [container url].path;
    if (error) return containerJSON(@{@"error": error.localizedDescription ?: @"container lookup failed"});
    if (!container) return containerJSON(@{@"missing": @YES});
    if (!path.length) return containerJSON(@{@"error": @"container has no path"});
    return containerJSON(@{@"path": path, @"existed": @(create ? existed : YES)});
}

char *icli_container_destroy_json(const char *kind, const char *identifier) {
    Class cls = containerClass(kind);
    if (!cls) return containerJSON(@{@"error": @"MobileContainerManager is unavailable"});
    if (!identifier || !identifier[0]) return containerJSON(@{@"error": @"container identifier required"});
    NSError *error = nil;
    id container = lookupContainer(cls, @(identifier), NO, NULL, &error);
    if (error) return containerJSON(@{@"error": error.localizedDescription ?: @"container lookup failed"});
    if (!container) return containerJSON(@{@"missing": @YES});
    if (![container respondsToSelector:@selector(destroyContainerWithCompletion:)]) return containerJSON(@{@"error": @"container deletion is unavailable"});
    NSString *path = [container url].path ?: @"";
    // The completion's arguments are not relied on: the result is read back.
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    id failure = [container destroyContainerWithCompletion:^(id ignored) {
        (void)ignored;
        dispatch_semaphore_signal(done);
    }];
    if ([failure isKindOfClass:NSError.class]) return containerJSON(@{@"error": [failure localizedDescription] ?: @"container deletion failed"});
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    if (lookupContainer(cls, @(identifier), NO, NULL, &error)) return containerJSON(@{@"error": @"container still exists after deletion", @"path": path});
    return containerJSON(@{@"destroyed": @YES, @"path": path});
}

bool icli_register_app_dictionary(const char *plist_xml) {
    icli_private_init();
    if (!plist_xml) return false;
    NSData *data = [NSData dataWithBytes:plist_xml length:strlen(plist_xml)];
    NSDictionary *dict = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    id ws = icli_ls_workspace();
    if (![dict isKindOfClass:NSDictionary.class] || !ws) return false;
    if ([ws respondsToSelector:@selector(registerApplicationDictionary:)] && [ws registerApplicationDictionary:dict]) return true;
    // Newer LaunchServices refuse the call above and take the containerized
    // form, which answers NO even when it succeeds; the caller reads the
    // registration back either way.
    SEL containerized = @selector(registerContainerizedApplicationWithInfoDictionaries:operationUUID:requestContext:saveObserver:registrationError:);
    if (![ws respondsToSelector:containerized]) return false;
    NSError *error = nil;
    [ws registerContainerizedApplicationWithInfoDictionaries:@[dict] operationUUID:[NSUUID UUID] requestContext:nil saveObserver:nil registrationError:&error];
    return error == nil;
}
