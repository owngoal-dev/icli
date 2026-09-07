# icli

Control your iPhone from the command line. Tap and swipe, enter text, inspect accessibility elements, capture screenshots, and read on-screen text, with JSON output for scripts and automation.

icli runs on the device itself. Use it in a device terminal or over SSH from your Mac. It requires an arm64 device running iOS 16 or later with a compatible jailbreak bootstrap.

icli is a single, self-contained executable. It performs its work in-process using iOS frameworks and a statically linked archive library, without spawning subprocesses or invoking bootstrap tools. No additional runtime packages are required. `icli env` reports the detected environment, `spawns_processes: false`, and an empty `external_tools_used` object.

For app integration, add this repository as a Swift Package dependency and select the **IcliKit** library product. See the [Swift Package integration guide](docs/swift-package.md) for usage and the [complete entitlement inventory](docs/entitlements.md) for host signing requirements.

## Install

[Build a package from source](#build-from-source), then choose the package for your bootstrap:

| Bootstrap | Package Architecture | Status |
| --- | --- | --- |
| Rootless (`/var/jb`) | `iphoneos-arm64` | Tested on the project's rootless vphone |
| RootHide | `iphoneos-arm64e` | Experimental; package checks pass, runtime remains unverified |

Both packages contain the same arm64 executable. The architecture label identifies the bootstrap layout. iOS 16 is the minimum deployment target; the [acceptance report](docs/rootless-acceptance.md) records the environment actually tested.

For the initial DEB installation below, use the bootstrap's `dpkg` and an account with permission to install packages. To connect over USB, you also need an SSH server on the device and `iproxy` on your Mac. These are installation and connection tools; icli does not invoke them.

In one Mac terminal, start USB forwarding and leave it running:

```sh
iproxy 2333 22
```

In another Mac terminal, upload the package from the repository directory and connect. Replace the version and account details as needed:

```sh
scp -P 2333 .build/com.icli.icli_0.3.0_iphoneos-arm64.deb mobile@127.0.0.1:/tmp/icli.deb
ssh -p 2333 mobile@127.0.0.1
```

Then run on the device:

```sh
sudo dpkg -i /tmp/icli.deb
icli --version
icli device info
```

On rootless installations, the command is `/var/jb/usr/bin/icli`. Use that full path if your shell cannot find it. For SSH over the network, use your device's address and port instead of USB forwarding.

The DEB installs a command-line executable and license notices. The executable is signed with the [documented entitlements](docs/entitlements.md) in `Resources/icli.entitlements`, so clipboard, brightness, and rotation commands run directly without launching an app or changing the foreground app.

## Features

- **Touch and keyboard**: Tap, swipe, press and hold, drag along a path, enter Unicode text, and send keyboard shortcuts.
- **Accessibility**: Read the UI tree, find elements by text, identifier, or role, tap a match, and wait for an element to appear or disappear.
- **Screenshots and OCR**: Save JPEG screenshots, return images as Base64, recognize text, or collect an image, OCR results, and accessibility elements together.
- **Apps**: List, launch, inspect, register, unregister, and refresh apps; inspect or repair their network policy. Install and remove local DEB packages or compatible IPA files.
- **Files and logs**: Read, write, copy, move, link, and remove files; change permissions and ownership; read and edit property lists; capture live logs and read crash reports.
- **Device controls**: Adjust brightness, volume, and rotation; use hardware button actions and the clipboard; request userspace or full reboots; render boot logos.
- **System**: Manage launchd services, local DEB packages and repository source files, compare Debian and BaseBin versions, set account passwords through stdin, control system app visibility, restart SpringBoard, capture packets, and store test credentials in the `icli.test` Keychain access group.

OCR uses Apple's Vision framework. If system text recognition is unavailable, the command returns an `unavailable` error. A successful scan with no recognized text returns an empty result.

## Command Line

Run these commands on the device or in its SSH session. Unlock the device and keep the screen on before interacting with an app. Use `icli --help` or append `--help` to a command to see its options.

### Inspect and Interact

Read the foreground app's accessibility tree, then use its text or identifiers in your commands. Replace the sample identifiers and text below with elements in your app:

```sh
icli app frontmost
icli ui tree
icli ui tap --identifier counter.increment
icli ui wait 'Ready element' --timeout 5
icli ui wait-gone 'Loading' --timeout 10
```

For coordinate input, read the screen dimensions first. Coordinates are **points**, including those returned by accessibility and OCR:

```sh
icli screen info
icli screen tap 100 245
icli screen swipe --from-x 200 --from-y 600 --to-x 200 --to-y 200
icli screen drag --points '[{"x":54,"y":500},{"x":140,"y":480},{"x":240,"y":500}]'
```

Focus a text field before entering text:

```sh
icli input paste '中文 and emoji 🌱'
icli input key cmd+a
icli input type 'Hello!' --delay-ms 30
```

`input paste` sends Unicode keyboard events; it does not read the clipboard. `input type` sends one grapheme at a time. Use `icli clipboard get` and `icli clipboard set 'shared text'` for clipboard text. icli reads and writes the system pasteboard without a prompt. When another app later reads that text programmatically, iOS may show its standard paste permission prompt for that app; user-initiated pastes such as `icli input key cmd+v` are not prompted.

### Capture the Screen

```sh
icli screen shot --output /tmp/screen.jpg
icli screen shot --base64
icli screen ocr
icli screen describe
```

Screenshot paths are on the device. Default screenshots have one image pixel per point. Add `--native-resolution` for native pixel dimensions; the result includes a `coordinate_scale` to relate pixels to points.

`screen describe` uses one capture for its JPEG and OCR results and collects accessibility elements separately. Check its component errors and `context_changed` before combining the results.

### Apps, Files, and Logs

Use `app list` to find an app's bundle identifier. Replace `example.bundle.id` with an app you installed; file paths refer to the device:

```sh
icli app list
icli app info example.bundle.id
icli app launch example.bundle.id
icli fs write /tmp/example.txt 'Hello from icli'
icli fs read /tmp/example.txt
icli log syslog --seconds 3 --level error
icli log crashes --bundle-id example.bundle.id
```

Upload a package before installing it:

```sh
sudo icli app install /tmp/example.deb
sudo icli app install /tmp/example.ipa
```

DEB operations read archives and update the bootstrap's dpkg database directly. IPA installation validates archive paths and app metadata, preserves the app's signature, and requires the bootstrap to support running it. This IPA installation path does not overwrite apps installed outside icli. Use `icli app uninstall --help` for removal options.

`sudo icli pkg install /tmp/example.deb` installs a local archive and checks architecture and installed dependencies; installing the same version reinstalls it. Package identifiers and repository downloads are not supported. `pkg info`, `pkg extract`, `pkg status`, and `pkg compare` expose metadata, extraction, installed state, and Debian version comparison. `pkg remove` keeps configuration files unless `--purge` is supplied. `pkg repos` and `pkg add-repo` inspect and edit repository source files.

Maintainer scripts and package triggers are not executed. Transactions report skipped scripts in `scripts_not_run` and register installed app bundles through LaunchServices. Packages that require script-driven setup need that setup handled separately; icli is not a complete dpkg or APT replacement.

### Services and System Maintenance

```sh
icli env info
icli env basebin --bundled /tmp/basebin.tar
icli svc status example.service
sudo icli svc load /var/jb/Library/LaunchDaemons/example.service.plist
sudo icli svc unload /var/jb/Library/LaunchDaemons/example.service.plist
icli app refresh
icli sb system-apps get
```

`svc load`, `svc unload`, and `svc status` also accept a directory for batch operations. `svc enable` and `svc disable` take a service label. `account set-password <user>` reads the new password from stdin and requires root; keep passwords out of command arguments and shell history.

`sudo icli device reboot --force` requests a full reboot; add `--userspace` for a userspace restart. SSH may disconnect before a JSON response arrives; a disconnect alone does not prove success. Verify completion after reconnecting: a userspace restart replaces system and UI service processes while kernel boot time and boot session UUID remain unchanged; a full reboot changes the kernel boot time and session UUID. The acceptance runner records these before/after values.

### Output and Device State

Commands return JSON on standard output by default. Add `--human` for interactive reading. Runtime failures return an `error` code and a `message` and exit nonzero. Help, version output, and argument errors are handled separately by the argument parser.

The former `shell` command was removed in 0.3.0. Use the filesystem and system command groups for operations implemented by icli.

Most commands reject execution while the device is locked or the screen is off. Device and screen information, screenshots, `button wake`, and live logs remain available. `button wake` wakes the screen; it does not remove a passcode.

Audio buttons try hardware events first and fall back to the system audio controller when needed. Their JSON reports the method and resulting state. `button mute` toggles the active audio category's mute state; physical ringer-switch behavior has not been verified.

## Build from Source

Requires macOS with Xcode and its iPhoneOS SDK, Swift, Clang, Make, `ldid`, `dpkg-deb`, and Python 3. Make these tools available on your `PATH`.

```sh
git clone https://github.com/owngoal-dev/icli.git
cd icli
make all CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
make deb-rootless
make deb-roothide
./scripts/check-packages.sh
```

Swift Package Manager resolves Argument Parser and the static [LibArchive package](https://github.com/Lakr233/libarchive.xcframework) using the versions pinned in `Package.resolved`. Dependency checkouts and binary artifacts stay under `.build/swiftpm/`; no library sources or headers are vendored. Use `make resolve` after changing dependency versions.

| Output | Location |
| --- | --- |
| Signed executable | `.build/icli` |
| Rootless package | `.build/com.icli.icli_<version>_iphoneos-arm64.deb` |
| Experimental RootHide package | `.build/com.icli.icli_<version>_iphoneos-arm64e.deb` |
| Package verification report | `.build/package-verification.json` |

The version comes from `Resources/Info.plist`. `make deb` builds the rootless package. Every build checks for forbidden process-launch imports. Package checks repeat that check and verify architecture, deployment target, entitlements, system-only linked libraries, a firmware-only DEB dependency, ownership, and identical executable contents across the two layouts. Import checks detect direct linked calls; runtime acceptance also checks the environment report.

`make` runs the SwiftPM iOS build, copies the executable to `.build/icli`, and signs it with `ldid` using the repository's entitlements. It does not require an Apple development certificate. To compile without signing, use `swift build -c release --triple arm64-apple-ios16.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" --scratch-path .build/swiftpm --product icli --force-resolved-versions`.

## Testing and Compatibility

The [acceptance report](docs/rootless-acceptance.md) is generated from the recorded test run and lists every case and every command entry point with its result; failed or untested entries stay visible. Acceptance covers rotation, package repositories, network capture, and Keychain operations on dedicated `icli.test` entries. Keychain commands operate only within that access group and do not read other apps' items. RootHide runtime, other iOS versions, and physical hardware require separate testing.

Device acceptance uses a separate TestHost app and installation fixtures, which are excluded from release packages. After building icli, prepare them on your Mac:

```sh
./scripts/build-testhost.sh
./scripts/build-install-fixtures.sh
```

Install `.build/icli-testhost_1.0_iphoneos-arm64.deb` on the device and upload the `.ipa` and `.deb` from `.build/install-fixtures/` to the device's `/tmp/`. Then run from your Mac:

```sh
python3 scripts/acceptance.py --install --report .build/acceptance-release.json
python3 scripts/check-package-consumer.py --device
python3 scripts/assemble-release.py
```

`assemble-release.py` archives the binary, packages, fixtures, integration documentation, and reports under `.build/release/<version>/` and regenerates `docs/rootless-acceptance.md` from the run. It verifies that the full run completed, the tested runner and binary still match, and the package consumer passed. It exits nonzero if any case failed or any command was not executed.

The runner defaults to `mobile@127.0.0.1:2333`. Override `ICLI_SSH_HOST`, `ICLI_SSH_PORT`, `ICLI_SSH_USER`, or `ICLI_BINARY` as needed. Use SSH keys or set `ICLI_SSH_PASSWORD`; password-based SSH requires `sshpass` on the Mac. The account must also be able to run the test's `sudo` commands without an interactive prompt.

Tests interact with apps, change device settings, and install or remove fixtures. Use an unlocked device prepared for testing. `--install` installs icli, not TestHost or its fixtures. Full acceptance runs userspace and full reboot tests last; reboots clear `/tmp` on the test device, so upload fixtures again before another run. `--skip-reboot` produces a partial run that cannot qualify for release assembly. Reports are saved under `.build/`, which is excluded from Git.

## License

icli is available under the [MIT License](LICENSE).

Third-party dependency licenses are listed in [Third-Party Notices](THIRD_PARTY_NOTICES.md). The notices and bundled dependency license texts are included in both DEB packages.
