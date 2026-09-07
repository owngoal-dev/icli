# Using IcliKit from Swift Package Manager

The package exports the `IcliKit` library and the `icli` executable. An iOS app or package manager can link `IcliKit` and call its functions in-process. It does not need to install or launch the CLI. The library product includes its private Objective-C bridge and statically linked LibArchive dependency; Argument Parser and the CLI's embedded Info.plist belong only to the executable target. Library targets declare no unsafe build flags.

Requires an iOS 16 or later arm64 device and a compatible bootstrap for privileged device operations. This is an on-device library, not a macOS host SDK. Simulator runtime is not supported or tested.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/owngoal-dev/icli.git", from: "0.3.0"),
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

// Run only after your UI obtains the user's installation intent.
// The calling process must already be root for this operation.
let result = try installDebFile("/path/to/package.deb")
let completion = result["completion"] as? String
let skippedScripts = result["scripts_not_run"] as? [String] ?? []
```

Functions return Foundation dictionaries and throw `IcliError` or underlying Foundation errors. Handle `IcliError.code`, `.message`, or `.payload` in your own UI. Treat `completion: "partial"`, skipped maintainer scripts, and registration failures as incomplete setup. DEB handling supports local archives and existing dependency checks, not repository downloads or script/trigger execution. The caller supplies passwords directly to `setAccountPassword(user:password:)`; stdin handling belongs to the CLI.

The API is synchronous and has not been audited for concurrent use. Serialize operations, especially package database mutations and UI interactions. Archive operations and waits can block; integrate them with your application's scheduling and lifecycle. Long-lived app hosts have only been checked for compilation through a separate consumer; the full behavior suite runs in the CLI process.

`Envelope` is CLI output/exit machinery, not an app integration API: `Envelope.run` can terminate the process. Call the throwing library functions directly. The CLI's interactive lock check wraps its commands; library callers must enforce their own interaction policy, check `screenInfo()` for `locked` and `screen_off`, and respect system privacy and permission decisions.

## Signing and entitlements

SwiftPM does not sign your executable with icli's entitlements, elevate privileges, or grant platform status. Entitlements belong to the **calling app or executable**, not the library. Integrate the applicable entries from [the complete entitlement inventory](entitlements.md) into your own target's signing configuration and use your own application identifiers. Root requirements are separate from entitlements.

[Resources/icli.entitlements](../Resources/icli.entitlements) records the tested CLI signing profile. It contains private platform capabilities; ordinary App Store provisioning does not grant them. The inventory explains every key and array value, distinguishes the tested profile from proven minimum requirements, and records the CLI's `icli.test` Keychain access group.

## Integration verification

```sh
python3 scripts/check-package-consumer.py
# With icli installed on the configured test device:
python3 scripts/check-package-consumer.py --device
```

This builds a separate iOS executable against a local Git snapshot tagged with the package version, using an exact-version source-control dependency. It verifies product selection, public imports, transitive linkage, and compatibility with SwiftPM's dependency build restrictions. `--device` signs the test executable with its own application identity and the CLI capability profile, then checks environment reporting, Debian version comparison, and installed package state on the device. The consumer source is in [Tests/PackageConsumer](../Tests/PackageConsumer); evidence is saved to `.build/package-consumer-verification.json`.
