#pragma once

#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

// The ObjC reflection bridge. JavaScriptCore's classes are reached through the
// Class objects the context file resolves after dlopen, never by name: the
// headers are imported for their declarations, and a direct `[JSValue ...]`
// would make the linker load the framework, which `scripts/verify-binary.py`
// rejects.

/// JSContext and JSValue, resolved once the framework is loaded. Nil before
/// the context has started, which the bridge is never reached before.
extern Class IcliProbeContextClass;
extern Class IcliProbeValueClass;

/// Raise a JavaScript Error with the formatted message in `context`, which a
/// native function the script called then returns from: JSC throws it into
/// the script as that call's exception.
void icli_probe_throw(JSContext *context, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

/// What a script holds for an ObjC object the bridge cannot convert. The
/// prelude wraps each one in a proxy, so a script calls methods by name
/// instead of calling `send` itself.
@protocol IcliProbeObjCHandleExports <JSExport>
@property (nonatomic, readonly) BOOL objcHandle;
@property (nonatomic, readonly) NSString *className;
@property (nonatomic, readonly) BOOL isClassHandle;
- (NSString *)toString;
/// The object as a plain JavaScript value: a collection becomes an array or
/// an object, and anything else its description.
- (JSValue *)plainValue;
JSExportAs(send, - (JSValue *)sendSelectorNamed:(NSString *)name arguments:(JSValue *)arguments);
@end

@interface IcliProbeObjCHandle : NSObject <IcliProbeObjCHandleExports>
@property (nonatomic, readonly, strong) id target;
+ (instancetype)handleFor:(id)target;
@end
