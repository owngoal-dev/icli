#pragma once
#import <Foundation/Foundation.h>

/// Registers an application through LaunchServices' containerized interface,
/// the one iOS 27 still carries out: there -[LSApplicationWorkspace
/// registerApplicationDictionary:] only logs that it is deprecated and answers
/// NO. lsd refuses the call (-54) unless its embedded-registration check lets
/// the caller through, as the vphone firmware patches it to. The call answers
/// NO even when it registers, so success is the absence of an error; callers
/// read the record back.
BOOL icli_ls_register_containerized(id workspace, NSDictionary *info, NSError **error);
