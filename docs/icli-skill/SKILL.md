---
name: icli
description: Command map for icli, the on-device CLI that controls and inspects a jailbroken iPhone or iPad. Use it when you drive or inspect such a device over SSH: tapping, typing, reading the accessibility tree, screenshots and OCR, launching or installing apps, files, logs, Debian packages, launchd services, reboots and device settings. It maps an intent to the exact `icli` command, with the sudo and screen-state rules for each command.
---

# icli command map

icli runs **on the device**. Run every command in an SSH session on the device, for example `ssh mobile@<device> 'icli device info'`. It prints JSON on stdout. Add `--human` for readable text. `icli <group> --help` and `icli <group> <command> --help` list every option.

The tables below mark each command with two properties:

- **Root**: `required` means icli refuses to run without root (use `sudo icli …`). `usually` means the command runs, but the files or launchd domain it changes normally need root. `no` means it works as the mobile user.
- **Screen**: `unlocked` means the command exits with code 2 (`device_locked`) while the device is locked or its screen is off. `any` means it also runs while the device is locked.

Per-group detail: [interaction](reference/interaction.md) (screen, ui, input, button, clipboard), [device](reference/device.md) (device, location), [apps](reference/apps.md) (app, url, sb), [files and logs](reference/files-logs.md) (fs, log), [packages](reference/packages.md) (pkg), [system](reference/system.md) (svc, account, env, proc, sec, net, tests).

## Quick index

| I want to… | Command |
| --- | --- |
| Check whether the screen is on and unlocked | `icli screen info` (read `locked`, `screen_off`) |
| Wake the screen | `icli button wake` (does not remove a passcode) |
| Find which app is in front | `icli app frontmost` |
| Find an app's bundle ID | `icli app search <name>` or `icli app list` |
| Launch an app and wait until it is in front | `icli app launch <bundle-id>` |
| Open a URL or deep link | `icli url open <url>` or `icli app open <url> --bundle <bundle-id>` |
| Quit an app | `icli app kill <bundle-id> --force` |
| List what is on screen | `icli ui tree` (add `--clickable-only`, `--limit N`) |
| Tap a button by its label | `icli ui tap 'Label' --match exact` |
| Tap by accessibility identifier | `icli ui tap --identifier <id>` |
| Wait for an element to appear or disappear | `icli ui wait 'Text' --timeout 5` / `icli ui wait-gone 'Loading'` |
| Find which element is at a point | `icli ui at <x> <y>` |
| Tap, double-tap or long-press a point | `icli screen tap <x> <y>` / `double-tap` / `long-press --seconds 1` |
| Swipe or scroll | `icli screen swipe --from-x X --from-y Y --to-x X --to-y Y` |
| Drag along a path | `icli screen drag --points '[{"x":10,"y":10},{"x":90,"y":40}]'` |
| Type text into the focused field | `icli input paste 'text'` (fast, Unicode) or `icli input type 'text'` |
| Press Return, Tab, arrows or a shortcut | `icli input key return` / `icli input key cmd+a` |
| Press Home, lock the screen or change volume | `icli button home` / `button power` / `button volume-up` |
| Read or set the clipboard | `icli clipboard get` / `icli clipboard set 'text'` |
| Take a screenshot | `icli screen shot --output /tmp/s.jpg` or `--base64` |
| Read the text on screen | `icli screen ocr` |
| Get a screenshot, OCR and elements together | `icli screen describe` |
| Get the model, iOS version, battery and jailbreak | `icli device info` |
| Get brightness, volume and orientation | `icli device brightness get` / `volume get` / `rotation get` |
| Simulate the GPS location, then stop | `icli location set 37.3349 -122.009` / `icli location clear` |
| Read the current location | `icli location get` (check `fresh` and `simulated`) |
| Rotate the screen or lock rotation | `icli device rotation set landscape-left` / `rotation lock set on` |
| Read, write or list files | `icli fs read <p>` / `fs write <p> <text>` / `fs ls <dir>` |
| Read or edit a plist | `icli fs plist <p>` / `icli fs plist-set <p> <key> '<json>'` |
| Capture live logs | `icli log syslog --seconds 5 --process <name> --level error` |
| Find and read crash reports | `icli log crashes --bundle-id <id>` then `icli log crash <path>` |
| Install a .deb or .ipa | `sudo icli app install /tmp/x.deb` (or `.ipa`) |
| Uninstall an app or package | `sudo icli app uninstall <bundle-id> --force` / `sudo icli pkg remove <pkg>` |
| Inspect a .deb without installing it | `icli pkg info <file.deb>` |
| Check whether a package is installed | `icli pkg status <name>` / `icli pkg list --filter <text>` |
| Refresh the home screen's app icons | `sudo icli sb uicache` or `icli app refresh` |
| Restart SpringBoard | `icli sb respring` |
| Check a launchd service | `icli svc status <label>` / `icli svc print <label>` |
| Start or stop a service | `sudo icli svc start <label>` / `sudo icli svc stop <label>` |
| List processes | `icli proc list --filter <text>` |
| Get jailbreak paths (jbroot, layout) | `icli env info` |
| Capture packets | `sudo icli net capture --seconds 5 --filter 'tcp port 443'` |
| Run the self-tests | `icli tests --expect-layout roothide` |
| Restart userspace | `sudo icli device reboot --userspace --force` |

## Conventions

- **Output**: one JSON object on stdout, with keys sorted. On failure the object is `{"error": <code>, "message": <text>}`, where the code is `failed`, `device_locked`, `force_required`, `unavailable`, `missing_dependency` or `command_failed`. Argument errors come from the argument parser as plain text on stderr.
- **Exit codes**: `0` is success. `2` is `device_locked`. `1` is any other runtime failure. A result or failure that carries a nonzero `status` exits with that status (1–255). Treat any nonzero exit as a failure and read the JSON.
- **Locked device**: see the Screen column. Most interactive and many read commands need the device unlocked with the screen on. When you get exit 2, run `icli button wake`. If `screen info` still shows `locked: true`, a person has to unlock the device.
- **Destructive commands need `--force`**: `app kill`, `app unregister`, `app unregister-dir`, `app uninstall --package`, `fs rm`, `sec keychain delete` and `device reboot` refuse to run without it and return `force_required`.
- **Coordinates** are UI points in the orientation shown on screen. The origin is the top-left corner as the user sees it. `screen info` gives the current `width`, `height` and `orientation`; an iPad in landscape reports a landscape width. Frames from `ui tree` and boxes from `screen ocr` use the same space, so you can pass the centre of a frame straight to `screen tap`.
- **Paths are physical device paths.** On RootHide, the SSH shell, `scp` and bootstrap tools treat the jailbreak root as `/` and reach the real filesystem under `/rootfs`. A file that icli writes to `/tmp/a.jpg` is `/rootfs/tmp/a.jpg` in that shell. A file you `scp` to `/tmp/x.deb` is `<jbroot>/tmp/x.deb` for icli; `icli env info` reports `jbroot`. On rootless, both views agree and the bootstrap lives under `/var/jb`.
- **Not a shell**: icli never spawns processes. There is no command to run arbitrary programs. Use the SSH shell for that.

## Workflows

**Launch, wait, tap, verify**

```sh
icli screen info                                  # locked:false, screen_off:false
icli app launch com.example.app                   # returns once the app is in front
icli ui wait 'Sign In' --timeout 10
icli ui tap 'Sign In' --match exact
icli ui wait-gone 'Loading' --timeout 15
icli ui tree --clickable-only --limit 50          # confirm the new screen
```

If no element matches, look for the label in `ui tree` (text matching is `contains` by default and ignores case). Use `--index N` to pick the N-th match. As a last resort, tap the centre of the element's `frame` with `screen tap`.

**Screenshot plus OCR**

```sh
icli screen shot --output /tmp/screen.jpg         # one pixel per point; --native-resolution for full pixels
icli screen ocr --lang en-US                      # blocks with text, confidence and point frames
icli screen describe                              # image (base64), OCR and ui elements from one call
```

To copy a screenshot to your Mac on RootHide: `scp mobile@<device>:/rootfs/tmp/screen.jpg .`. On rootless: `scp mobile@<device>:/tmp/screen.jpg .`.

**Install a .deb or .ipa**

```sh
scp app.ipa mobile@<device>:/tmp/                 # RootHide: icli sees it as <jbroot>/tmp/app.ipa
sudo icli app install /tmp/app.ipa                # use the path as icli sees it
icli app info <bundle-id>
icli app launch <bundle-id>
sudo icli app uninstall <bundle-id> --force
```

`app install` picks the installer from the file extension: `.deb` installs natively, as `pkg install` does, `.ipa` installs into the bootstrap and registers the app, and `.app` registers the bundle. Maintainer scripts are never run; the result lists them in `scripts_not_run`.

**Recover from a stuck state**

`icli button home` returns to the home screen. `icli app kill <id> --force` quits the app. `icli sb respring` restarts SpringBoard. `sudo icli device reboot --userspace --force` restarts userspace; SSH drops, so reconnect and check `device info`. A full reboot (`device reboot --force` without `--userspace`) can leave the device without SSH until it is re-jailbroken, so use it only when you are told to.
