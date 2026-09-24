# Using IcliKit from Swift Package Manager

The package exports the `IcliKit` and `IcliSystem` libraries and the `icli` executable. An iOS app or package manager can link either library and call its functions in-process. It does not need to install or launch the CLI. The `IcliKit` product includes its private Objective-C bridge and statically linked LibArchive dependency; Argument Parser and the CLI's embedded Info.plist belong only to the executable target. Library targets declare no unsafe build flags.

`IcliKit` requires an iOS 16 or later arm64 device and a compatible bootstrap for privileged device operations. This is an on-device library, not a macOS host SDK. Simulator runtime is not supported or tested. For read-only system state alone, [`IcliSystem`](#the-iclisystem-product) has an iOS 15 floor and compiles for the simulator and Mac Catalyst.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/owngoal-dev/icli.git", from: "0.6.5"),
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

The API is synchronous and has not been audited for concurrent use. Serialize operations, especially package database mutations and UI interactions. Archive operations and waits can block; integrate them with your application's scheduling and lifecycle. Long-lived app hosts have only been checked for compilation through a separate consumer; the full behavior suite runs in the CLI process.

`Envelope` is CLI output/exit machinery, not an app integration API: `Envelope.run` can terminate the process. Call the throwing library functions directly. The CLI's interactive lock check wraps its commands; library callers must enforce their own interaction policy, check `screenInfo()` for `locked` and `screen_off`, and respect system privacy and permission decisions.

## Device features

Every `icli` command is a thin layer over a public IcliKit function, so a long-running host such as a daemon can call the same code in-process. These arrived in 0.6.0:

| Feature | Calls |
| --- | --- |
| Location | `simulateLocation(latitude:longitude:altitude:horizontalAccuracy:verticalAccuracy:speed:course:)`, `clearSimulatedLocation()`, `currentLocation(timeout:)`. The simulation stays on after the calling process exits. |
| Developer Mode | `developerModeStatus()`, `enableDeveloperMode()`. Enabling only arms it for the next restart. |
| Low Power Mode | `lowPowerMode()`, `setLowPowerMode(_:)` |
| Clipboard | `clipboardInfo(imageOutput:)`, `clipboardImagePNG()`, `setClipboardImage(_:)`, next to `clipboardText()` and `setClipboard(_:)` |
| Preferences | `readPreference`, `writePreference` and `deletePreference`, with `PreferenceUser` and `PreferenceValue`. Build a `PreferenceValue` directly, or parse command-line text with `init(text:type:)`. |
| Raw input | `touch(_:x:y:normalized:)`, `touchSequence(_:normalized:)` with `TouchEvent`, `hidEvent(page:usage:down:)`, `hidPress(page:usage:)`. `TouchPhase` is `down`, `move` or `up` (UITouchPhase 0, 1 and 3). |
| Container installs | `installIPAInContainer(_:registration:)` or `installPackage(_:container:registration:)`, with `AppRegistrationType`. `uninstallApp(_:force:)` removes container apps icli installed. |

A call a device can't support throws `IcliError.unavailable` and leaves the device as it was. For example, a jailbroken device won't launch an app installed in a container unless the app is signed in a way CoreTrust accepts. The CLI refuses UI input while the device is locked. A library caller has to make that check itself.

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

Also `serviceStatus(_:)`, `printService(_:)` and the shared `IcliError`, `takeCString(_:)` and `decodeBridgeJSON(_:_:)`. Nothing in this product changes system state: service loading, enabling, starting, stopping, signalling and `setenv`, app registration, installation and every device setting stay in `IcliKit`. `servicesDump()` records a label launchd refuses to describe in its `errors` map and returns the rest; `jetsamSnapshot()` reports `priorities_error` instead of throwing when the kernel refuses the priority list.

| Property | Value |
| --- | --- |
| Deployment floor | iOS 15.0 — the whole package declares `.iOS(.v15)`; the CLI itself is still built and packaged for iOS 16 |
| Links | Foundation and CoreFoundation only |
| Resolved at runtime | launchd's bootstrap pipe and `memorystatus_control` through libSystem, `LSApplicationWorkspace` through `NSClassFromString` after `dlopen`, `libroot`/`libroothide` through `dlopen` |
| Not linked | UIKit, IOKit, Vision, AVFoundation, CoreGraphics, Security, LibArchive |
| Builds for | iOS device, iOS simulator (`arm64-apple-ios15.0-simulator`) and Mac Catalyst (`arm64-apple-ios15.0-macabi`) |

Off a jailbroken device the calls fail cleanly rather than crashing: every private symbol it names is exported by libSystem in the iPhoneOS, iPhoneSimulator and macOS SDKs, so nothing is link-guarded, and a missing class, service or bootstrap turns into an empty list, an `IcliError` or an error field. Simulator and Catalyst runtime behaviour is compile-verified only; `listApps()` there returns whatever LaunchServices answers, which on macOS is usually nothing.

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

## Signing and entitlements

SwiftPM does not sign your executable with icli's entitlements, elevate privileges, or grant platform status. Entitlements belong to the **calling app or executable**, not the library. Integrate the applicable entries from [the complete entitlement inventory](entitlements.md) into your own target's signing configuration and use your own application identifiers. Root requirements are separate from entitlements.

[Resources/icli.entitlements](../Resources/icli.entitlements) records the tested CLI signing profile. It contains private platform capabilities; ordinary App Store provisioning does not grant them. The inventory explains every key and array value, distinguishes the tested profile from proven minimum requirements, and records the CLI's `icli.test` Keychain access group.

## Integration verification

```sh
python3 scripts/check-package-consumer.py
# With icli installed on the configured test device:
python3 scripts/check-package-consumer.py --device
```

This builds separate iOS executables against a local Git snapshot tagged with the package version, using an exact-version source-control dependency: `IcliKit` at the iOS 16 triple and `IcliSystem` at the iOS 15 one, from a consumer package that declares the iOS 15 floor. It verifies product selection, public imports, transitive linkage, the floor a consumer may declare, and compatibility with SwiftPM's dependency build restrictions. `--device` signs the test executable with its own application identity and the CLI capability profile, then checks environment reporting, Debian version comparison, installed package state, Developer Mode and Low Power Mode status on the device. It also checks that `writePreference` refuses a value that isn't a property list before anything is written. The build references every 0.6.0 device-feature API with its full type, so the check fails if one stops being public or changes signature. The consumer source is in [Tests/PackageConsumer](../Tests/PackageConsumer); evidence is saved to `.build/package-consumer-verification.json`.
