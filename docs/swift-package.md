# Using IcliKit from Swift Package Manager

The package exports the `IcliKit`, `IcliSystem` and `IcliLaunch` libraries and the `icli` executable. An iOS app or package manager can link either library and call its functions in-process. It does not need to install or launch the CLI. The `IcliKit` product includes its private Objective-C bridge and statically linked ArchiveKit dependency; Argument Parser and the CLI's embedded Info.plist belong only to the executable target. Library targets declare no unsafe build flags.

`IcliKit` requires an iOS 15 or later arm64 device and a compatible bootstrap for privileged device operations. This is an on-device library, not a macOS host SDK. Simulator runtime is not supported or tested. For read-only system state alone, [`IcliSystem`](#the-iclisystem-product) has an iOS 15 floor and compiles for the simulator and Mac Catalyst.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/owngoal-dev/icli.git", from: "0.7.0"),
],
targets: [
    .target(
        name: "YourPackageManager",
        dependencies: [.product(name: "IcliKit", package: "icli")]
    ),
]
```

For a development checkout, use `.package(path: "../icli")`. In Xcode, add the repository as a package dependency and select the **IcliKit** library product for your app target.

```swift
import IcliKit

let environment = try environmentReport()
let metadata = try readDeb("/path/to/package.deb")
let installed = try packageStatus("example.package")
let comparison = try compareDebianVersions("1.0~beta", "1.0")
let services = try listServices()
let service = try serviceStatus("example.service")
let launchdDescription = try printService("example.service")
let keychainMetadata = try listKeychainDatabaseMetadata(className: nil)
let running = try runningApps()             // source, apps, count; each app has a PID
let frontmost = frontmostApp()               // bundle_id, verified, source

// Run only after your UI obtains the user's installation intent.
// The calling process must already be root for this operation.
let result = try installDebFile("/path/to/package.deb")
let completion = result["completion"] as? String
let skippedScripts = result["scripts_not_run"] as? [String] ?? []
```

Functions return Foundation dictionaries and throw `IcliError` or underlying Foundation errors. Handle `IcliError.code`, `.message`, or `.payload` in your own UI. Service APIs also include bootstrap/load, bootout/unload, enable/disable, start/stop, signal, remove, disabled-override, and launchd environment operations. Treat `completion: "partial"`, skipped maintainer scripts, and registration failures as incomplete setup. DEB handling supports local archives and existing dependency checks, not repository downloads or script/trigger execution. The caller supplies passwords directly to `setAccountPassword(user:password:)`; stdin handling belongs to the CLI.

`listKeychainDatabaseMetadata(className:)` reads only the `genp`, `inet`, `cert`, and `keys` tables' index metadata. It requires filesystem permission to read `/var/Keychains/keychain-2.db` (normally root). RootHide's bootstrap shell reaches that file at `/rootfs/var/Keychains/keychain-2.db`, but an IcliKit process opens the real filesystem path. The result identifies `source: "database"`, `protectedMetadata: true`, and per-table counts. Only columns SQLite marks as text are included; protected BLOB attributes are omitted. It never includes passwords, decrypted data, or encrypted blobs. `listKeychain` uses Security.framework and remains limited by the calling process's access groups; its items identify `source: "security"`. Consumers combining these two results should preserve unmatched database rows and identify possible duplicates rather than hiding protected entries on an uncertain match.

The API is synchronous. Package installs and removals in one process wait for each other, and the read APIs have been run from eight threads at once in `Tests/HostSoak` (`scripts/host-soak.py` runs it on the acceptance device); serialize UI interactions yourself. Archive operations and waits can block; integrate them with your application's scheduling and lifecycle. Long-lived app hosts have only been checked for compilation through a separate consumer; the full behavior suite runs in the CLI process.

`Envelope` is CLI output/exit machinery, not an app integration API: `Envelope.run` can terminate the process. Call the throwing library functions directly. The CLI's interactive lock check wraps its commands; library callers must enforce their own interaction policy, check `lockState()` or `screenInfo()` for `locked` and `screen_off`, and respect system privacy and permission decisions. `launchApp` is the exception: it reports a locked device itself, as `IcliError.locked`.

## Device features

Every `icli` command is a thin layer over a public IcliKit function, so a long-running host such as a daemon can call the same code in-process. These arrived in 0.6.0:

| Feature | Calls |
| --- | --- |
| Location | `simulateLocation(latitude:longitude:altitude:horizontalAccuracy:verticalAccuracy:speed:course:)`, `clearSimulatedLocation()`, `currentLocation(timeout:)`. The simulation stays on after the calling process exits. |
| Developer Mode | `developerModeStatus()`, `enableDeveloperMode()`. Enabling only arms it for the next restart. |
| Low Power Mode | `lowPowerMode()`, `setLowPowerMode(_:)` |
| Time zone | `timeZone()`, `setTimeZone(_:)`, `setAutomaticTimeZone(_:)`. Setting a zone turns the automatic time zone off first, so timed does not put its own back. |
| Darwin notifications | `postDarwinNotification(_:state:)`, `darwinNotificationState(_:)` |
| Clipboard | `clipboardInfo(imageOutput:)`, `clipboardImagePNG()`, `setClipboardImage(_:)`, next to `clipboardText()` and `setClipboard(_:)` |
| Preferences | `readPreference`, `writePreference` and `deletePreference`, with `PreferenceUser` and `PreferenceValue`. Build a `PreferenceValue` directly, or parse command-line text with `init(text:type:)`. |
| Accessibility | `uiElements`, `elementAt` and the waits turn on the system-wide accessibility and automation switches when they are off, read again on every query. `restoreAccessibilitySwitches()` turns back off what they turned on; the `icli` command does it at exit, and a host that runs until it is killed should call it when it stops reading the UI. |
| JSON | `jsonSafe(_:)` reduces a plist or preference value to what `JSONSerialization` accepts. Results from IcliKit already are; values a host reads itself may not be, and `JSONSerialization` raises an Objective-C exception, which Swift cannot catch, on a NaN or a date. |
| Rotation | `rotationInfo()`, `setRotation(_:)`, `setRotationLock(_:)`, and `interfaceRotationDegrees()`, which asks SpringBoard alone and returns nil when it does not answer. A host that stays running across a respring keeps working: before 0.7.9 it kept the old SpringBoard's accessibility port, and every later call failed with "The device did not apply the requested rotation." |
| Raw input | `touch(_:x:y:normalized:)`, `touchSequence(_:normalized:)` with `TouchEvent`, `hidEvent(page:usage:down:)`, `hidPress(page:usage:)`. `TouchPhase` is `down`, `move` or `up` (UITouchPhase 0, 1 and 3). |
| Pointer | `pointerMove(x:y:normalized:buttons:)`, `pointerButtons(_:)`, `pointerScroll(_:dx:dy:)` with `ScrollPhase`, and the whole gestures `pointerClick(x:y:normalized:button:count:hold:hover:)` and `pointerScrollGesture(x:y:normalized:dx:dy:seconds:steps:)`. The pointer is a HID mouse with an absolute position that the process creates on first use and keeps until it exits, so a host that stays running moves one pointer: iPadOS shows it, hides it after a few seconds without movement, and answers a held `PointerButtons` button as a trackpad click, not a touch. A touch is the wrong input under a visible pointer: an alert ignores a touch on a button the pointer is hovering. `normalized` coordinates are 0…1 of the interface as it is shown, not the digitizer's portrait space. Calls from several threads are applied one at a time, in the order they arrive; a host that sends moves concurrently orders them itself. |
| Container installs | `installIPAInContainer(_:registration:)` or `installPackage(_:container:registration:)`, with `AppRegistrationType`. `installIPAInContainer(_:registration:prepareApp:)` lets an integrator prepare the validated temporary app bundle before container installation. `uninstallApp(_:force:)` removes container apps icli installed. |

A call a device can't support throws `IcliError.unavailable` and leaves the device as it was. For example, a device running custom firmware won't launch an app installed in a container unless the app is signed in a way CoreTrust accepts. The CLI refuses UI input while the device is locked. A library caller has to make that check itself.

`kickstartService(_:kill:)` starts a loaded launchd job immediately. With `kill: true` it replaces the running instance and returns the new `pid`, so a daemon can start using its updated executable. With `kill: false`, an existing process stays running and `unchanged` is true. The host executable needs `com.apple.private.xpc.service-attach` in its own signing profile as well as the usual service privileges; `com.apple.private.xpc.service-configure` alone was refused with launchd status 144 on iOS 27. Linking IcliKit does not add entitlements to the host.

## The IcliSystem product

`IcliSystem` is the read-only system-state half of the library, split out for hosts that want a system report without the rest: a crash reporter attaching device state to a report, for example. `IcliKit` depends on it and re-exports it, so a consumer that links `IcliKit` keeps the same API and needs no second import.

```swift
import IcliSystem

let snapshot = try deviceSnapshot()          // model, kernel, boot, storage, bootstrap
let processes = try listProcesses(filter: nil)
let apps = try listApps()                    // LaunchServices registrations
let tweaks = try listTweaks()
let services = try listServices()
let described = try servicesDump()            // every service plus launchd's own print output
let disabled = try disabledServiceOverrides()
let path = try launchdEnvironment("PATH")
let jetsam = try jetsamSnapshot()             // bands, jetsam property lists, memory pressure
let root = JailbreakRoot.current
```

Also `serviceStatus(_:)`, `printService(_:)`, `servicePlistPaths(_:)` (what `svc paths` prints, read-only), the pure `LaunchdPlistPaths` (RootHide launchctl's plist rewrite) and the shared `IcliError`, `takeCString(_:)` and `decodeBridgeJSON(_:_:)`. Nothing in this product changes system state: service loading, enabling, starting, stopping, signalling and `setenv`, app registration, installation and every device setting stay in `IcliKit`. `servicesDump()` records a label launchd refuses to describe in its `errors` map and returns the rest; `jetsamSnapshot()` reports `priorities_error` instead of throwing when the kernel refuses the priority list.

| Property | Value |
| --- | --- |
| Deployment floor | iOS 15.0 — the whole package declares `.iOS(.v15)`, and the CLI is built and packaged for it |
| Links | Foundation and CoreFoundation only |
| Resolved at runtime | launchd's bootstrap pipe and `memorystatus_control` through libSystem, `LSApplicationWorkspace` through `NSClassFromString` after `dlopen`, `libroot`/`libroothide` through `dlopen` |
| Not linked | UIKit, IOKit, Vision, AVFoundation, CoreGraphics, Security, ArchiveKit |
| Builds for | iOS device, iOS simulator (`arm64-apple-ios15.0-simulator`) and Mac Catalyst (`arm64-apple-ios15.0-macabi`) |

Anywhere other than a device running custom firmware, the calls fail cleanly rather than crashing: every private symbol it links by name is exported by libSystem in the iPhoneOS, iPhoneSimulator and macOS SDKs and by iOS 15.0 itself — `scripts/floor-imports.txt` lists them and the build fails on any other, because an SDK exporting a symbol does not mean the floor does (xpc_user_sessions_get_foreground_uid is iOS 16 and stopped an iOS 15 app at launch); anything newer is resolved with `dlsym` or weak-imported, and a missing class, service or bootstrap turns into an empty list, an `IcliError` or an error field. Simulator and Catalyst runtime behaviour is compile-verified only; `listApps()` there returns whatever LaunchServices answers, which on macOS is usually nothing.

### Entitlements the host needs

Entitlements belong to the calling app, exactly as for `IcliKit`, and the [inventory](entitlements.md) explains every key. For the `IcliSystem` calls specifically:

| Call | Entitlement | Status |
| --- | --- | --- |
| `listServices`, `serviceStatus`, `printService`, `servicesDump`, `disabledServiceOverrides`, `launchdEnvironment` | `com.apple.private.xpc.launchd.per-user-lookup` | The reads are verified with the CLI's complete profile, which contains this key; it has not been verified by removing it. It covers the foreground user's domain, where iOS keeps the real pids of proxied daemons — a host without it should still see the system domain, with no user-domain rows |
| `listApps` | `com.apple.private.coreservices.canmaplsdatabase`, `com.apple.private.coreservices.lsaw` | Not verified separately from the CLI's complete profile; a host without them falls back to the application-directory scan |
| `listProcesses` | `proc_info-allow` for other processes' executable paths | Not verified on its own; the pid and name come from sysctl without it |
| `jetsamSnapshot` priority list | root, or `com.apple.private.memorystatus` | Not verified. `memorystatus_control` returns `EPERM` for an ordinary process, which the snapshot reports as `priorities_error`; `properties` and `memory` need nothing |
| `deviceSnapshot`, `listTweaks`, `JailbreakRoot` | none | Ordinary filesystem and sysctl reads, subject to the caller's own file permissions |

None of these grant root, and a matching entitlement is not proof that a platform will grant it. Everything above except the jetsam priority list has been exercised from the signed CLI; per-key necessity has not been isolated for either product.

## Logs and crash reports

```swift
import IcliKit

// One bounded read: every filter applies before maxLines.
let read = try captureSyslog(seconds: 5, filter: SyslogFilter(subsystem: "com.example.tweak", messageContains: "loaded"), maxLines: 50)

// One continuous listen with no seam, until cancelled or its seconds pass.
let stream = try SyslogStream(filter: SyslogFilter(subsystem: "com.example.tweak"), seconds: 600) { entry in
    print(entry.date ?? Date(), entry.process, entry.message)
    return true                                // false stops the stream
} onEnd: { reason in
    print("ended:", reason)                    // cancelled, duration, entry_limit, handler, interrupted
}
stream.cancel()                                // no entry arrives once this returns

// The same as an async sequence; cancelling the consuming task stops it.
for await entry in try syslogEntries(filter: SyslogFilter(level: "error"), seconds: 30) {
    print(entry.message)
}

let report = try readCrashLog("/var/mobile/Library/Logs/CrashReporter/example.ips", maxBytes: 1 << 20)
```

`SyslogFilter` keeps entries whose process name contains `process` (case-insensitive), whose `pid` matches, whose subsystem is `subsystem` or a dotted child of it, whose category is `category`, whose message contains `messageContains` (case-sensitive) and whose level is at least `level`. `captureSyslog(seconds:process:level:maxLines:)` keeps its old parameters and takes the new ones after them.

`SyslogStream` delivers each matching entry to its handler, one at a time and in arrival order, until `seconds` pass, `maxEntries` entries have been delivered, the handler answers false, the system ends the stream (`interrupted`: logd went away or refused the process) or `cancel()` is called; releasing it cancels it. `onEnd` runs once, on a queue of its own, and `wait(timeout:)` blocks for the end. Nothing is buffered in the stream: a slow handler holds up the stream and the system drops what it cannot hold. `syslogEntries` buffers at most `bufferLimit` entries for a consumer that falls behind and drops later ones until it catches up. Do not make the handler wait on a thread that may be calling `cancel()`. The live stream needs the logging entitlements in the inventory, as `log syslog` does.

`readCrashLog(_:maxBytes:)` reads at most `maxBytes` of the file without loading the rest, refuses anything but a regular file, and answers `content`, `bytes` (what `content` holds), `size` (the whole file) and `truncated`.

## The IcliLaunch product

`IcliLaunch` is what a host needs to bring an app to the front, and nothing else: a command-line tool that wakes its own app, for example. `IcliKit` depends on it and re-exports it, and it re-exports `IcliSystem`, whose `IcliError` it throws.

```swift
import IcliLaunch

let lock = lockState()                        // locked, screen_off
let frontmost = frontmostApp()                 // bundle_id, verified, source
let launched = try launchApp("com.example.app") // launched, frontmost
```

`launchApp` asks SpringBoardServices first and falls back to `LSApplicationWorkspace`, then waits up to five seconds for the app to be frontmost. It throws `IcliError.locked` at once when the system refuses because the device is locked or its screen is off, and `IcliError.failed` for an app LaunchServices does not know, any other refusal, or an app that never came to the front. Before 0.7.8 the LaunchServices fallback ignored the refusal, so a library caller on a locked device waited the five seconds and got "app did not become frontmost".

The lock comes from SpringBoard's `com.apple.springboard.lockstate` notification and `SBGetScreenLockStatus` together: on iOS 26 `SBSGetScreenLockStatus` reads unlocked on a locked device, and MobileKeyBag answers nothing useful on a device without a passcode.

| Property | Value |
| --- | --- |
| Deployment floor | iOS 15.0 |
| Links | Foundation and CoreFoundation only |
| Resolved at runtime | SpringBoardServices and RunningBoardServices through `dlopen`, `LSApplicationWorkspace` through `NSClassFromString` |
| Not linked | UIKit, IOKit, AVFoundation, CoreLocation, ArchiveKit |

| Call | Entitlement | Status |
| --- | --- | --- |
| `launchApp` (the launch itself), `lockState` | none | Verified on the iOS 26.4 RootHide and rootless vphones, as `mobile` and as root: the LaunchServices fallback launches with no entitlement and refuses while locked |
| `frontmostApp`, and so `launchApp`'s wait | `com.apple.private.security.no-sandbox` | Verified on the iOS 26.4 RootHide vphone. A bootstrap executable signed without it gets no RunningBoard process handles, `frontmostApp()` reports `source: "unavailable"`, and `launchApp` launches the app and then fails after five seconds. `platform-application`, `proc_info-allow`, `task_for_pid-allow` and the launch-application keys alone do not help. An unverified answer carries a `runningboard` object saying which step failed (`reason`: `runningboard_unavailable`, `process_list_failed`, `no_process_handles`, `no_process_states`, `no_focal_app`, `several_focal_apps` or `several_focal_roles`), with counts and RunningBoard's first handle error; on macOS that error names `com.apple.runningboard.process-state` |
| SpringBoardServices launch | `com.apple.springboard.launchapplications` | Optional: without it the LaunchServices fallback does the same work |

## Signing and entitlements

SwiftPM does not sign your executable with icli's entitlements, elevate privileges, or grant platform status. Entitlements belong to the **calling app or executable**, not the library. Integrate the applicable entries from [the complete entitlement inventory](entitlements.md) into your own target's signing configuration and use your own application identifiers. Root requirements are separate from entitlements.

[Resources/icli.entitlements](../Resources/icli.entitlements) records the tested CLI signing profile. It contains private platform capabilities; ordinary App Store provisioning does not grant them. The inventory explains every key and array value, distinguishes the tested profile from proven minimum requirements, and records the CLI's `icli.test` Keychain access group.

## Integration verification

```sh
python3 scripts/check-package-consumer.py
# With icli installed on the configured test device:
python3 scripts/check-package-consumer.py --device
```

This builds separate iOS executables against a local Git snapshot tagged with the package version, using an exact-version source-control dependency: `IcliKit`, `IcliSystem` and `IcliLaunch` at the iOS 15 triple, from a consumer package that declares the iOS 15 floor. It verifies product selection, public imports, transitive linkage, the floor a consumer may declare, and compatibility with SwiftPM's dependency build restrictions. `--device` signs the test executable with its own application identity and the CLI capability profile, then checks environment reporting, Debian version comparison, installed package state, Developer Mode and Low Power Mode status on the device. It also checks that `writePreference` refuses a value that isn't a property list before anything is written. The build references every 0.6.0 device-feature API with its full type, so the check fails if one stops being public or changes signature. The consumer source is in [Tests/PackageConsumer](../Tests/PackageConsumer); evidence is saved to `.build/package-consumer-verification.json`.
