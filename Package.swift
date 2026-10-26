// swift-tools-version:5.9
import Foundation
import PackageDescription

let repositoryDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

let package = Package(
    name: "icli",
    platforms: [.iOS(.v15), .tvOS(.v15)],
    products: [
        .library(name: "IcliKit", targets: ["IcliKit"]),
        .library(name: "IcliSystem", targets: ["IcliSystem"]),
        .library(name: "IcliLaunch", targets: ["IcliLaunch"]),
        .executable(name: "icli", targets: ["icli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.1"),
        .package(url: "https://github.com/Lakr233/libarchive.xcframework.git", from: "1.0.0"),
    ],
    targets: [
        // Read-only system state: Foundation, CoreFoundation and the launchd,
        // LaunchServices and memorystatus private symbols it resolves itself.
        .target(
            name: "IcliSystemPrivate",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"),
            ],
        ),
        .target(
            name: "IcliSystem",
            dependencies: ["IcliSystemPrivate"],
        ),
        // Lock state, app launch and the frontmost app, for a host that brings
        // an app forward and needs nothing else: Foundation and the private
        // frameworks it looks up at runtime.
        .target(
            name: "IcliLaunchPrivate",
            dependencies: ["IcliSystemPrivate"],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"),
            ],
        ),
        .target(
            name: "IcliLaunch",
            dependencies: ["IcliLaunchPrivate", "IcliSystem"],
        ),
        .target(
            name: "IcliPrivate",
            dependencies: [
                "IcliSystemPrivate",
                "IcliLaunchPrivate",
                .product(name: "ArchiveKit", package: "libarchive.xcframework"),
            ],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("UIKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreLocation"),
            ],
        ),
        // The JavaScriptCore scripting shell behind `icli probe`: the JSContext,
        // its prelude, and the NSInvocation ObjC reflection bridge. It imports
        // the JavaScriptCore headers, which leaves an autolink request in each
        // object file, but names no JavaScriptCore symbol: the framework is
        // loaded with dlopen and every use goes through IcliProbeContextClass /
        // IcliProbeValueClass, resolved by NSClassFromString, so ld drops the
        // request. The binary still builds and loads where JavaScriptCore is
        // absent, and evaluation there fails with an error saying so. One
        // direct `[JSValue ...]` would link the framework after all, which
        // scripts/verify-binary.py rejects. This also keeps the target free of
        // the unsafe linker flags a weak framework link would need, which an
        // external versioned consumer of IcliKit cannot build.
        .target(
            name: "IcliProbe",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("Foundation")],
        ),
        .target(
            name: "IcliKit",
            dependencies: ["IcliPrivate", "IcliSystem", "IcliLaunch", "IcliProbe"],
            linkerSettings: [.linkedLibrary("sqlite3")],
        ),
        .executableTarget(
            name: "icli",
            dependencies: [
                "IcliKit",
                "IcliPrivate",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", repositoryDirectory.appendingPathComponent("Resources/Info.plist").path,
                ]),
            ],
        ),
    ],
)
