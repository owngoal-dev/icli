# device

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `device info` | Model, iOS, battery, storage, memory, jailbreak layout | | no | any |
| `device jetsam` | Jetsam bands, jetsam property lists, memory pressure | | usually (without root, `priorities_error` replaces the band list) | any |
| `device brightness get` | Brightness 0–1 | | no | unlocked |
| `device brightness set <value>` | Set brightness (0–1) | | no | unlocked |
| `device volume get` | Volume, active volume and category | `--category Audio/Video` | no | unlocked |
| `device volume set <value>` | Set volume (0–1) | `--category Audio/Video` | no | unlocked |
| `device rotation get` | Orientation name and degrees, rotation lock | | no | unlocked |
| `device rotation set <value>` | `portrait`, `landscape-left`, `upside-down`, `landscape-right` (or 0/90/180/270) | | no | unlocked |
| `device rotation lock get` | Whether orientation lock is on | | no | unlocked |
| `device rotation lock set <on\|off>` | Turn orientation lock on or off | | no | unlocked |
| `device network` | Interface addresses | | no | unlocked |
| `device ioreg` | IORegistry dump | `--plane IOService` | no | unlocked |
| `device bootlogo` | Render a screen-sized JPEG 2000 boot logo from a PNG/JPEG mark | `--mark <image>`, `--output <file.jp2>` (both required), `--dark`, `--width`, `--height`, `--mark-points 128` | no | any |
| `device reboot --force` | Full reboot | `--force` required | required | any |
| `device reboot --userspace --force` | Userspace restart (launchd re-exec) | `--force` required | required | any |

Reboot notes:

- SSH usually drops before the JSON arrives, so a disconnect does not prove that the reboot happened. Reconnect and compare `device info` with the values from before.
- After a userspace restart the system and UI processes are new, while the kernel boot time and boot session UUID stay the same. A full reboot changes both.
- A full reboot clears `/tmp`. On a semi-untethered jailbreak it can also leave the device without SSH until someone re-jailbreaks it, so run it only when you are explicitly told to.

## location

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `location set <latitude> <longitude>` | Simulate a fixed location for every app, then read it back to confirm | `--altitude 0`, `--horizontal-accuracy 5`, `--vertical-accuracy 5`, `--speed`, `--course` (speed and course default to unknown) | no | any |
| `location clear` | Stop simulating | | no | any |
| `location get` | The location CoreLocation reports: coordinates, altitude, accuracies, speed, course, `timestamp`, `age_seconds`, `fresh`, `simulated` | `--timeout 10` | no | any |

Location notes:

- The simulated location stays on after icli exits, for every app and user, until `location clear`. Always clear it when you are done.
- Negative coordinates work without `--`: `icli location set -33.8688 151.2093`. Give a negative altitude as `--altitude=-10`.
- `get` reads as a System Services location bundle, so it needs no permission prompt. `simulated` is CoreLocation's own flag for a software-simulated fix.
- `fresh: false` means no new fix arrived within the timeout and the reading is locationd's last known location. `clear` waits until locationd stops refreshing the simulated fix, but until the next real fix `get` can still return the last simulated location with `fresh: false`.
- A Wi-Fi-only iPad can reject real fixes for about 15 minutes after a simulated location far from the real one. To avoid that, run `location set` with the real coordinates (from `location get` before simulating), then `location clear`.
