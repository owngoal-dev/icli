#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>

// The read-only system half lives in IcliSystemPrivate and the lock, launch
// and frontmost bridge in IcliLaunchPrivate; both are re-exported here, so this
// module still declares the whole private bridge.
#include "IcliSystemPrivate.h"
#include "IcliLaunchPrivate.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double width;
    double height;
    double scale;
    int orientation;
} IcliScreenMetrics;

void icli_private_init(void);

/// Whether the device has a passcode, whether or not it is locked now.
bool icli_passcode_set(void);
IcliScreenMetrics icli_screen_metrics(void);
/// Converts a point in the upright interface to the fixed (portrait) space
/// that the digitizer and accessibility hit testing use.
void icli_screen_point_to_fixed(double x, double y, double *fx, double *fy);
/// The inverse of icli_screen_point_to_fixed.
void icli_screen_fixed_to_point(double fx, double fy, double *x, double *y);
/// Converts a point in the upright interface to 0…1 digitizer coordinates.
void icli_screen_point_to_digitizer(double x, double y, double *nx, double *ny);

bool icli_screenshot_jpeg(const char *path, float quality, int max_bytes, bool native_resolution);
char *icli_ax_elements_json(int pid, int max_elements);
char *icli_ax_element_at_json(int pid, double x, double y);
/// Puts the system-wide accessibility switches that AX queries turned on back
/// off. icli does this at exit; a long-running host calls it when it is done.
void icli_ax_restore_switches(void);

bool icli_hid_tap(double x, double y);
bool icli_hid_double_tap(double x, double y, double interval);
bool icli_hid_long_press(double x, double y, double seconds);
bool icli_hid_swipe(double x1, double y1, double x2, double y2, double seconds, int steps);
bool icli_hid_drag(const double *xs, const double *ys, int count, double hold, double seconds, int steps);
/// One digitizer event at 0…1 digitizer coordinates. Phase uses UITouchPhase
/// numbers, as vphoned's protocol does: 0 down, 1 move, 3 up.
bool icli_hid_touch(int phase, double nx, double ny);
bool icli_hid_key(uint16_t usage_page, uint16_t usage, bool down);
bool icli_hid_text(const char *text);
bool icli_hid_button(const char *name);
bool icli_wake(void);

/// What the icli_pointer_ calls return.
enum {
    ICLI_POINTER_OK = 0,
    /// The system does not have the private IOKit symbols.
    ICLI_POINTER_UNAVAILABLE = 1,
    /// IOHIDUserDeviceCreate refused to make the device.
    ICLI_POINTER_REFUSED = 2,
    /// The device exists but iOS has not put an event service over it yet.
    ICLI_POINTER_NOT_READY = 3,
    /// The report or the event could not be made or delivered.
    ICLI_POINTER_FAILED = 4,
};

/// Puts the virtual pointer at x, y: 0…1 from the top-left corner of the
/// interface as it is shown. Creates the pointing device on first use; it
/// lives as long as the process. `buttons` are the buttons held from then on,
/// bit 0 primary, bit 1 secondary, bit 2 middle; a negative value keeps the
/// ones held.
int icli_pointer_move(double x, double y, int buttons);
/// Presses or releases buttons where the pointer is.
int icli_pointer_buttons(int buttons);
/// One scroll event to the view under the pointer. `phase` is an
/// IOHIDEventPhaseBits value: 1 began, 2 changed, 4 ended, 8 cancelled. dx and
/// dy are interface points, with a browser wheel event's signs.
int icli_pointer_scroll(int phase, double dx, double dy);

bool icli_open_url(const char *url);
bool icli_open_url_in_app(const char *url, const char *bundle_id);
/// Live application processes reported by RunningBoard, as a JSON object.
char *icli_runningboard_apps_json(void);
bool icli_uninstall_app(const char *bundle_id);
bool icli_unregister_app(const char *path);
char *icli_app_handlers_json(const char *url_or_scheme);

double icli_battery_fraction(void);
int icli_battery_state(void);

double icli_brightness_get(void);
bool icli_brightness_set(double value);
/// 1 when auto-brightness is on, 0 when off, -1 when it cannot be read.
int icli_auto_brightness(void);
double icli_volume_get(const char *category);
bool icli_volume_set(double value, const char *category);

typedef struct {
    int degrees;
    int device_orientation;
    bool locked;
} IcliRotation;

/// SpringBoard's interface orientation in degrees, or -1 when it does not answer.
int icli_interface_degrees(void);
IcliRotation icli_rotation_get(void);
bool icli_rotation_set(int degrees);
bool icli_rotation_lock_set(bool locked);

char *icli_extract_ipa_json(const char *source, const char *destination);
char *icli_deb_read_json(const char *path, const char *destination);
char *icli_deb_unpack_json(const char *path, const char *prefix, const char **skip, int skip_count);
char *icli_capture_packets_json(
    const char *interface,
    const char *filter_text,
    double seconds,
    const char *output_path
);
char *icli_tar_entry_text(const char *path, const char *entry_name);
int icli_compare_debian_versions(const char *left, const char *right, int *comparison);

char *icli_apps_unregister_directory_json(const char *directory);
char *icli_app_registration_json(const char *path);
/// Every app LaunchServices lists, as an XML property list array of
/// {bundle_id, path, type, signer} with the path normalized. NULL when
/// LaunchServices cannot be asked.
char *icli_app_index_plist(void);
/// The record of the app registered as `bundle_id` at `path`, as an XML
/// property list: the bundle identifier, normalized path, and what a uicache
/// registration sets (versions, type, signer, containerization, data
/// container, environment, group identifiers, entitlements, settings bundle),
/// with its plug-ins under "plugins". An empty dictionary when no such app is
/// registered, NULL when LaunchServices cannot be asked.
char *icli_app_record_plist(const char *bundle_id, const char *path);
/// A bundle path in the form LaunchServices reports it: symlinks in every
/// existing component resolved, /private/var as /var.
char *icli_normalized_app_path(const char *path);

/// A MobileContainerManager container; kind is app, data, plugin, group or
/// system-group. Returns {"path", "existed"}, {"missing": true} when create is
/// false and there is none, or {"error"}.
char *icli_container_json(const char *kind, const char *identifier, bool create);
/// Deletes a container through containermanagerd and reads the result back:
/// {"destroyed": true, "path"}, {"missing": true} or {"error"}.
char *icli_container_destroy_json(const char *kind, const char *identifier);
/// Registers an app from a LaunchServices registration dictionary (XML plist).
bool icli_register_app_dictionary(const char *plist_xml);

bool icli_springboard_relaunch(void);

char *icli_sha512_crypt(const char *key, const char *salt);
char *icli_account_set_password_json(const char *etc_directory, const char *user, const char *password);

bool icli_platform_binary(void);
int icli_reboot(bool userspace);
char *icli_app_network_policy_json(const char *bundle_id, bool repair);
char *icli_system_apps_visible_json(int desired);
char *icli_bootlogo_render_json(
    const char *mark_path,
    const char *output_path,
    bool dark,
    int width,
    int height,
    double mark_points
);
char *icli_active_audio_json(void);
char *icli_audio_button_json(const char *button);

/// amfid's Developer Mode reply ({success, status, armed, writable}); arm
/// asks amfid to turn Developer Mode on after the next restart.
char *icli_amfi_developer_mode_json(bool arm);
/// powerd's Low Power Mode: 1 on, 0 off, -1 when the service is unavailable.
int icli_low_power_mode_get(void);
/// 0 on acceptance; -1 if unavailable, -2 on timeout, -3 on rejection.
int icli_low_power_mode_set(bool enabled);
/// timed's automatic time zone: 1 on, 0 off, -1 when CoreTime does not offer
/// it, -2 when timed does not answer within 3 seconds.
int icli_automatic_time_zone_get(void);
/// Sends timed the setting without waiting; -1 when CoreTime does not offer it.
int icli_automatic_time_zone_set(bool enabled);
/// Asks tzlinkd to point /var/db/timezone/localtime at the Olson name. Returns
/// tzlinkd's errno (0 on success), -1 without tzlink, -2 after 5 silent seconds.
int icli_time_zone_link(const char *name);
/// Posts a Darwin notification through notifyd, first setting its state when
/// set_state is true. delivered reports whether this process's own listener
/// received the post within a second. Returns a notify(3) status; 0 is success.
uint32_t icli_notify_post(const char *name, bool set_state, uint64_t state, bool *delivered);
/// A Darwin notification's current state. Returns a notify(3) status.
uint32_t icli_notify_get_state(const char *name, uint64_t *state);
/// Location simulation through locationd; the location outlives the process.
char *icli_location_simulate_json(
    double latitude,
    double longitude,
    double altitude,
    double horizontal_accuracy,
    double vertical_accuracy,
    double speed,
    double course
);
char *icli_location_clear_json(void);
/// Waits up to `timeout` seconds for a fresh fix (at the target coordinate when `match`).
char *icli_location_read_json(double timeout, bool match, double latitude, double longitude);

/// Listens for `seconds` and answers the matching entries, at most
/// `max_lines` of them. Every filter applies before the cap; NULL or empty
/// strings and a pid of 0 or less match anything.
char *icli_syslog_json(
    double seconds,
    const char *process,
    int pid,
    const char *subsystem,
    const char *category,
    const char *message_contains,
    const char *level,
    int max_lines
);

/// Why a syslog stream ended.
typedef enum {
    IcliSyslogEndCancelled = 0,
    /// Its duration passed.
    IcliSyslogEndDuration = 1,
    /// It delivered its maximum number of entries.
    IcliSyslogEndEntryLimit = 2,
    /// The entry handler answered false.
    IcliSyslogEndStopped = 3,
    /// The system ended the stream: logd went away or refused this process.
    IcliSyslogEndInterrupted = 4,
} IcliSyslogEnd;

/// One matching entry. The strings are never NULL, are valid for the call
/// only (retain one to keep it), hold any NUL the message had, and are
/// well-formed: a lone UTF-16 surrogate becomes U+FFFD. `date` is seconds
/// since 1970, or NaN when the event has none. Answer false to stop.
typedef bool (^IcliSyslogEntryHandler)(
    CFStringRef process,
    int pid,
    CFStringRef subsystem,
    CFStringRef category,
    CFStringRef level,
    CFStringRef message,
    double date
);
typedef void (^IcliSyslogEndHandler)(IcliSyslogEnd reason, long delivered);

/// Starts one continuous listen with the filters of icli_syslog_json. It ends
/// after `seconds` when that is above zero, after `max_entries` entries when
/// that is above zero, when `entry` answers false, when the system ends it, or
/// at icli_syslog_stream_cancel. Answers NULL when the stream is unavailable
/// or `level` is unknown. The handle stays valid until
/// icli_syslog_stream_release, which cancels first.
void *icli_syslog_stream_open(
    const char *process,
    int pid,
    const char *subsystem,
    const char *category,
    const char *message_contains,
    const char *level,
    double seconds,
    long max_entries,
    IcliSyslogEntryHandler entry,
    IcliSyslogEndHandler end
);
/// No entry is delivered once this returns. Idempotent.
void icli_syslog_stream_cancel(void *stream);
void icli_syslog_stream_release(void *stream);
char *icli_ioreg_json(const char *plane);

#ifdef __cplusplus
}
#endif
