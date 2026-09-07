// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IcliPackageConsumer",
    platforms: [.iOS(.v16)],
    products: [.executable(name: "IcliPackageConsumer", targets: ["IcliPackageConsumer"])],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "IcliPackageConsumer",
            dependencies: [.product(name: "IcliKit", package: "icli")]
        ),
    ]
)
