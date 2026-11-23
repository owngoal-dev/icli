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

/// Watches BackBoard for `bundle_id` coming to the front. Start it before
/// requesting the launch; NULL when the monitor is unavailable. End it with
/// icli_frontmost_watch_end on every path.
void *icli_frontmost_watch_start(const char *bundle_id);
/// Waits up to `seconds` for the watched app to become frontmost. False on
/// timeout, or at once for a NULL watch.
bool icli_frontmost_watch_wait(void *watch, double seconds);
/// Releases the watch. NULL is allowed.
void icli_frontmost_watch_end(void *watch);

#ifdef __cplusplus
}
#endif
