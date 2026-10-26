# icli

Control your iPhone from the command line. Tap and swipe, enter text, inspect accessibility elements, capture screenshots, and read on-screen text, with JSON output for scripts and automation.

icli runs on the device itself. Use it in a device terminal or over SSH from your Mac. It requires an arm64 device running iOS 15 or later on custom firmware with a compatible bootstrap. A separate build runs on tvOS 15 or later; see [tvOS](docs/platforms/tvos.md).

icli is a single, self-contained executable. It performs its work in-process using iOS frameworks and a statically linked archive library, without spawning subprocesses or invoking bootstrap tools. `icli env` reports `spawns_processes: false` and an empty `external_tools_used` object.

For app integration, add this repository as a Swift Package dependency and select **IcliKit**, or the Foundation-only **IcliSystem** (read-only system state) and **IcliLaunch** (bring an app to the front, read the lock state and the frontmost app). See the [Swift Package integration guide](docs/swift-package.md) and the [entitlement inventory](docs/entitlements.md).

## Install

Download a DEB from [GitHub Releases](https://github.com/owngoal-dev/icli/releases), or [build from source](docs/development/building.md), then choose the package for your bootstrap:

| Bootstrap | Package Architecture | Status |
| --- | --- | --- |
| Rootless (`/var/jb`) | `iphoneos-arm64` | Tested on the project's rootless vphone |
| RootHide | `iphoneos-arm64e` | Experimental; service inspection verified on iOS 18.5, full acceptance pending |
| tvOS, rootful (`/usr/bin`, Procursus `appletvos-arm64`) | `appletvos-arm64` | Package checks only; the same executable passed the tvOS acceptance on a tvOS 26.6 vphone |

```sh
sudo dpkg -i /tmp/icli.deb
icli --version
icli device info
```

See [Install](docs/install/install.md) for uploading over USB, rootless paths, and what the package contains.

## Features

- **Touch and keyboard**: Tap, swipe, press and hold, drag along a path, enter Unicode text, and send keyboard shortcuts or raw HID events. On an iPad, click and scroll with a virtual pointer.
- **Accessibility**: Read the UI tree, find elements by text, identifier, or role, tap a match, and wait for an element to appear or disappear.
- **Screenshots and OCR**: Save JPEG screenshots, return images as Base64, recognize text, or collect an image, OCR results, and accessibility elements together.
- **Apps**: List, launch, inspect, register, unregister, and refresh apps; inspect or repair their network policy. Install and remove local DEB packages or compatible IPA files.
- **Files and logs**: Read, write, copy, move, link, and remove files; change permissions and ownership; read and edit property lists; capture live logs and read crash reports.
- **Device controls**: Brightness, volume, rotation, hardware buttons, the clipboard, Low Power Mode, Darwin notifications, Developer Mode, simulated location, reboots, and boot logos.
- **System**: Manage launchd services, local DEB packages and repository sources, account passwords, system app visibility, SpringBoard restarts, packet capture, and test Keychain items; read jetsam bands and memory pressure.
- **Preferences**: Read, write, and delete typed preference values like `defaults`.
- **Scripting**: Run a JavaScriptCore script in-process with `icli probe`, with an Objective-C reflection bridge and icli's own capabilities through `api()`.

## Command Line

Run commands on the device or in its SSH session. Commands return JSON by default; add `--human` for readable output, and `--help` to any command for its options.

```sh
icli ui tree
icli ui tap --identifier counter.increment
icli screen tap 100 245
icli screen shot --output /tmp/screen.jpg
icli app launch example.bundle.id
icli log syslog --seconds 3 --level error
```

| Topic | Guide |
| --- | --- |
| Accessibility, touch, keyboard, pointer, screenshots, OCR | [Interaction and Screen Capture](docs/usage/interaction.md) |
| Apps, packages, files, logs | [Apps, Files, and Logs](docs/usage/apps-files-logs.md) |
| launchd services, registration, reboots | [Services and System Maintenance](docs/usage/services.md) |
| Location, power, notifications, preferences | [Location, Power, and Preferences](docs/usage/device-settings.md) |
| JavaScriptCore scripting with `icli probe` | [Script the Device](docs/usage/probe.md) |
| JSON output, errors, lock state, RootHide paths | [Output and Device State](docs/usage/output.md) |
| tvOS differences | [tvOS](docs/platforms/tvos.md) |

## Development

- [Build from Source](docs/development/building.md): toolchain, `make` targets, package outputs, and release CI.
- [Testing and Compatibility](docs/development/testing.md): on-device self-tests, the acceptance suite, and tvOS acceptance. Results of the last recorded run are in the [acceptance report](docs/rootless-acceptance.md).

## License

icli is available under the [MIT License](LICENSE).

Third-party dependency licenses are listed in [Third-Party Notices](THIRD_PARTY_NOTICES.md). The notices and bundled dependency license texts are included in every DEB package.
