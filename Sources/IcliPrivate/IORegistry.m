#import "IcliPrivate.h"
#import "IcliJSON.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

static void icliWalkRegistry(io_registry_entry_t entry, const char *planeName, int depth, NSMutableArray *entries) {
    if (depth > 5 || entries.count >= 300) {
        return;
    }
    io_name_t name = {0};
    io_name_t cls = {0};
    IORegistryEntryGetName(entry, name);
    IOObjectGetClass(entry, cls);
    [entries addObject:@{
        @"name": @(name),
        @"class": @(cls),
        @"depth": @(depth),
    }];
    io_iterator_t children = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildIterator(entry, planeName, &children) != KERN_SUCCESS) {
        return;
    }
    io_registry_entry_t child;
    while ((child = IOIteratorNext(children))) {
        icliWalkRegistry(child, planeName, depth + 1, entries);
        IOObjectRelease(child);
    }
    IOObjectRelease(children);
}

char *icli_ioreg_json(const char *plane) {
    icli_private_init();
    const char *planeName = (plane && plane[0]) ? plane : kIOServicePlane;
    mach_port_t master = MACH_PORT_NULL;
#if defined(kIOMainPortDefault)
    master = kIOMainPortDefault;
#elif defined(kIOMasterPortDefault)
    master = kIOMasterPortDefault;
#else
    IOMainPort(MACH_PORT_NULL, &master);
#endif
    io_registry_entry_t root = IORegistryGetRootEntry(master);
    if (!root) {
        return icli_json_or_empty(@{@"entries": @[], @"error": @"no io registry"});
    }
    NSMutableArray *entries = [NSMutableArray array];
    icliWalkRegistry(root, planeName, 0, entries);
    IOObjectRelease(root);
    return icli_json_or_empty(@{@"plane": @(planeName), @"entries": entries, @"count": @(entries.count)});
}
