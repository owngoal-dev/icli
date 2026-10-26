#pragma once

#include <stdbool.h>

// Lock state, app launch and the frontmost app: what a host needs to bring an
// app forward. Foundation only; SpringBoardServices, LaunchServices and
// RunningBoardServices are looked up at runtime, so nothing here links UIKit.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool locked;
    bool screen_off;
    bool passcode_enabled;
} IcliLockStatus;

typedef enum {
    /// SpringBoard, LaunchServices or (on tvOS) FrontBoard accepted the request.
    IcliLaunchAccepted = 0,
    /// Refused while the device was locked or its screen was off.
    IcliLaunchLocked = 1,
    /// Refused on an unlocked device.
    IcliLaunchRefused = 2,
} IcliLaunchResult;

IcliLockStatus icli_lock_status(void);
/// On a refusal, `reason` (when not NULL) receives the system shell's
/// explanation when it gave one (PineBoard on tvOS), to be released with free().
IcliLaunchResult icli_launch_app(const char *bundle_id, char **reason);
char *icli_frontmost_app_json(void);

#ifdef __cplusplus
}
#endif
