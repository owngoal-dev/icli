// swift-tools-version:5.9
import PackageDescription

/// The iOS 15 and tvOS 15 floors are part of what this fixture proves:
/// SwiftPM resolves platforms per package, so a consumer may only declare a
/// floor the icli package also supports.
let package = Package(
    name: "IcliPackageConsumer",
    platforms: [.iOS(.v15), .tvOS(.v15)],
    products: [
        .executable(name: "IcliPackageConsumer", targets: ["IcliPackageConsumer"]),
        .executable(name: "IcliSystemConsumer", targets: ["IcliSystemConsumer"]),
        .executable(name: "IcliLaunchConsumer", targets: ["IcliLaunchConsumer"]),
    ],
    // A path dependency is named after its directory; the name keeps "icli"
    // valid from a checkout or worktree under any other directory name.
    // scripts/check-package-consumer.py swaps this for a tagged snapshot.
    dependencies: [.package(name: "icli", path: "../..")],
    targets: [
        .executableTarget(
            name: "IcliPackageConsumer",
            dependencies: [.product(name: "IcliKit", package: "icli")],
        ),
        .executableTarget(
            name: "IcliSystemConsumer",
            dependencies: [.product(name: "IcliSystem", package: "icli")],
        ),
        .executableTarget(
            name: "IcliLaunchConsumer",
            dependencies: [.product(name: "IcliLaunch", package: "icli")],
        ),
    ],
)
