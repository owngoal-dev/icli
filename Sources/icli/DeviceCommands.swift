import ArgumentParser
import Foundation
import IcliKit
struct Device: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Device info and settings",
        subcommands: [Info.self, Brightness.self, Volume.self, Rotation.self, Network.self, Ioreg.self, Reboot.self, Bootlogo.self]
    )
}

extension Device {
    struct Reboot: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Request a full or userspace reboot (root); completion is proven by reconnecting")
        @OptionGroup var output: OutputOptions
        @Flag(help: "Restart userspace only (launchd re-exec) instead of the whole device") var userspace = false
        @Flag var force = false
        func run() { emit(allowWhenLocked: true, output) { try requestReboot(userspace: userspace, force: force) } }
    }
    struct Bootlogo: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Render a screen-sized JPEG 2000 boot logo from a mark image")
        @OptionGroup var output: OutputOptions
        @Option(help: "PNG/JPEG mark image") var mark: String
        @Option(name: .customLong("output"), help: "Destination .jp2 path") var destination: String
        @Flag var dark = false
        @Option(help: "Canvas width in pixels (default: native screen)") var width: Int = 0
        @Option(help: "Canvas height in pixels (default: native screen)") var height: Int = 0
        @Option(help: "Maximum mark side length in points") var markPoints: Double = 128
        func run() { emit(allowWhenLocked: true, output) { try renderBootLogo(mark: mark, output: destination, dark: dark, width: width, height: height, markPoints: markPoints) } }
    }
    struct Info: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Model, iOS, battery, storage, jailbreak")
        @OptionGroup var output: OutputOptions
        func run() { emit(allowWhenLocked: true, output) { try collectDeviceSnapshot() } }
    }

    struct Brightness: ParsableCommand {
        static var configuration = CommandConfiguration(subcommands: [Get.self, Set.self])
        struct Get: ParsableCommand {
            @OptionGroup var output: OutputOptions
            func run() { emit(output) { ["brightness": brightness()] } }
        }
        struct Set: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument var value: Double
            func run() { emit(output) { try setBrightness(value); return ["brightness": value] } }
        }
    }

    struct Volume: ParsableCommand {
        static var configuration = CommandConfiguration(subcommands: [Get.self, Set.self])
        struct Get: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Option var category: String = "Audio/Video"
            func run() { emit(output) {
                var state = try audioState()
                state["volume"] = volume(category)
                state["category"] = category
                return state
            } }
        }
        struct Set: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument var value: Double
            @Option var category: String = "Audio/Video"
            func run() { emit(output) { try setVolume(value, category: category) } }
        }
    }

    struct Rotation: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Display orientation",
            subcommands: [Get.self, Set.self, Lock.self]
        )
        struct Get: ParsableCommand {
            @OptionGroup var output: OutputOptions
            func run() { emit(output) { rotationInfo() } }
        }
        struct Set: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument var value: String
            func run() { emit(output) { try setRotation(value) } }
        }
        struct Lock: ParsableCommand {
            static var configuration = CommandConfiguration(subcommands: [Get.self, Set.self])
            struct Get: ParsableCommand {
                @OptionGroup var output: OutputOptions
                func run() { emit(output) { ["locked": rotationInfo()["locked"] ?? false] } }
            }
            struct Set: ParsableCommand {
                @OptionGroup var output: OutputOptions
                @Argument var value: String
                func run() { emit(output) { try setRotationLock(try parseOnOff(value)) } }
            }
        }
    }

    struct Network: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(output) { networkInfo() } }
    }

    struct Ioreg: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option var plane: String = "IOService"
        func run() { emit(output) { try ioregistry(plane: plane) } }
    }
}
