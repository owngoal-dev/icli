// swift-tools-version:5.9
import PackageDescription

/// The iOS 15 floor is part of what this fixture proves: SwiftPM resolves
/// platforms per package, so a consumer may only declare a floor the icli
/// package also supports.
let package = Package(
    name: "IcliPackageConsumer",
    platforms: [.iOS(.v15)],
    products: [
        .executable(name: "IcliPackageConsumer", targets: ["IcliPackageConsumer"]),
        .executable(name: "IcliSystemConsumer", targets: ["IcliSystemConsumer"]),
    ],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "IcliPackageConsumer",
            dependencies: [.product(name: "IcliKit", package: "icli")]
        ),
        .executableTarget(
            name: "IcliSystemConsumer",
            dependencies: [.product(name: "IcliSystem", package: "icli")]
        ),
    ]
)
