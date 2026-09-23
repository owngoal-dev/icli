#pragma once

#include <stdbool.h>
#include <stdint.h>

// The read-only system half lives in IcliSystemPrivate and is re-exported here,
// so this module still declares the whole private bridge.
#include "IcliSystemPrivate.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool locked;
    bool screen_off;
    bool passcode_enabled;
} IcliLockStatus;

typedef struct {
    double width;
    double height;
    double scale;
    int orientation;
} IcliScreenMetrics;

void icli_private_init(void);

IcliLockStatus icli_lock_status(void);
/// Whether the device has a passcode, whether or not it is locked now.
bool icli_passcode_set(void);
IcliScreenMetrics icli_screen_metrics(void);
/// Converts a point in the upright interface to the fixed (portrait) space
/// that the digitizer and accessibility hit testing use.
void icli_screen_point_to_fixed(double x, double y, double *fx, double *fy);
/// The inverse of icli_screen_point_to_fixed.
void icli_screen_fixed_to_point(double fx, double fy, double *x, double *y);

bool icli_screenshot_jpeg(const char *path, float quality, int max_bytes, bool native_resolution);
char *icli_ax_elements_json(int pid, int max_elements);
char *icli_ax_element_at_json(int pid, double x, double y);

bool icli_hid_tap(double x, double y);
bool icli_hid_double_tap(double x, double y, double interval);
bool icli_hid_long_press(double x, double y, double seconds);
bool icli_hid_swipe(double x1, double y1, double x2, double y2, double seconds, int steps);
bool icli_hid_drag(const double *xs, const double *ys, int count, double hold, double seconds, int steps);
bool icli_hid_key(uint16_t usage_page, uint16_t usage, bool down);
bool icli_hid_text(const char *text);
bool icli_hid_button(const char *name);
bool icli_wake(void);

bool icli_launch_app(const char *bundle_id);
bool icli_open_url(const char *url);
bool icli_open_url_in_app(const char *url, const char *bundle_id);
char *icli_frontmost_bundle_id(void);
bool icli_uninstall_app(const char *bundle_id);
bool icli_register_app(const char *path);
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

IcliRotation icli_rotation_get(void);
bool icli_rotation_set(int degrees);
bool icli_rotation_lock_set(bool locked);

char *icli_extract_ipa_json(const char *source, const char *destination);
char *icli_deb_read_json(const char *path, const char *destination);
char *icli_deb_unpack_json(const char *path, const char *prefix, const char **skip, int skip_count);
char *icli_capture_packets_json(const char *interface, const char *filter_text, double seconds, const char *output_path);
char *icli_tar_entry_text(const char *path, const char *entry_name);
int icli_compare_debian_versions(const char *left, const char *right, int *comparison);

char *icli_apps_refresh_json(const char *directory);
char *icli_apps_unregister_directory_json(const char *directory);
char *icli_app_registration_json(const char *path);

bool icli_springboard_relaunch(void);

char *icli_sha512_crypt(const char *key, const char *salt);
char *icli_account_set_password_json(const char *etc_directory, const char *user, const char *password);

bool icli_platform_binary(void);
int icli_reboot(bool userspace);
char *icli_app_network_policy_json(const char *bundle_id, bool repair);
char *icli_system_apps_visible_json(int desired);
char *icli_bootlogo_render_json(const char *mark_path, const char *output_path, bool dark, int width, int height, double mark_points);
char *icli_active_audio_json(void);
char *icli_audio_button_json(const char *button);

/// Location simulation through locationd; the location outlives the process.
char *icli_location_simulate_json(double latitude, double longitude, double altitude, double horizontal_accuracy, double vertical_accuracy, double speed, double course);
char *icli_location_clear_json(void);
/// Waits up to `timeout` seconds for a fresh fix (at the target coordinate when `match`).
char *icli_location_read_json(double timeout, bool match, double latitude, double longitude);

char *icli_syslog_json(double seconds, const char *process, const char *level, int max_lines);
char *icli_ioreg_json(const char *plane);

#ifdef __cplusplus
}
#endif
