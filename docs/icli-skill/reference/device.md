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
| `device devmode get` | Developer Mode: `enabled`, `armed` (turns on after the next restart), `writable` (the device allows changing it) | | no | any |
| `device devmode enable` | Arm Developer Mode when it is off; returns `already_enabled` and `restart_required`. Does not restart the device | | see notes | any |
| `device low-power get` | Whether Low Power Mode is on (`method: powerd`) | | no | any |
| `device low-power set <on\|off>` | Turn Low Power Mode on or off through powerd, like Control Center; checks the new state | | no | any |
| `device network` | Interface addresses | | no | unlocked |
| `device ioreg` | IORegistry dump | `--plane IOService` | no | unlocked |
| `device bootlogo` | Render a screen-sized JPEG 2000 boot logo from a PNG/JPEG mark | `--mark <image>`, `--output <file.jp2>` (both required), `--dark`, `--width`, `--height`, `--mark-points 128` | no | any |
| `device reboot --force` | Full reboot | `--force` required | required | any |
| `device reboot --userspace --force` | Userspace restart (launchd re-exec) | `--force` required | required | any |

Reboot notes:

- SSH usually drops before the JSON arrives, so a disconnect does not prove that the reboot happened. Reconnect and compare `device info` with the values from before.
- After a userspace restart the system and UI processes are new, while the kernel boot time and boot session UUID stay the same. A full reboot changes both.
- A full reboot clears `/tmp`. On a semi-untethered jailbreak it can also leave the device without SSH until someone re-jailbreaks it, so run it only when you are explicitly told to.

Developer Mode notes:

- `devmode get` asks amfid and works as mobile. It matches `sysctl security.mac.amfi.developer_mode_status`.
- `devmode enable` does nothing when Developer Mode is already on or armed. Otherwise it asks amfid to arm it: after the next restart the device asks the user to confirm, and only then is it on. amfid may refuse to arm it without root; the command then fails with `unavailable`. There is no command to turn Developer Mode off.
