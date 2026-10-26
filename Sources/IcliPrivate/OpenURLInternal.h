#pragma once
#import <Foundation/Foundation.h>

/// Opens `url` with FrontBoard's system service, in `bundleID` or, when it is
/// nil, the app LaunchServices names as its handler. This is tvOS's route:
/// LaunchServices' own open asks SpringBoard, which tvOS does not run.
#if TARGET_OS_TV
bool icli_frontboard_open_url(NSURL *url, NSString *bundleID);
#endif
