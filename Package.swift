// swift-tools-version:5.9
import Foundation
import PackageDescription

let repositoryDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

let package = Package(
    name: "icli",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "IcliKit", targets: ["IcliKit"]),
        .executable(name: "icli", targets: ["icli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.3.1"),
        .package(url: "https://github.com/Lakr233/libarchive.xcframework.git", exact: "0.1.1"),
    ],
    targets: [
        .target(
            name: "IcliPrivate",
            dependencies: [
                .product(name: "LibArchive", package: "libarchive.xcframework"),
            ],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("UIKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .target(
            name: "IcliKit",
            dependencies: ["IcliPrivate"]
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
            ]
        ),
    ]
)
