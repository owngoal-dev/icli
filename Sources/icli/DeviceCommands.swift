import ArgumentParser
import Foundation
import IcliKit

struct Device: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Device info and settings",
        subcommands: [Info.self, Jetsam.self, Brightness.self, Volume.self, Rotation.self, Network.self, Ioreg.self, Devmode.self, LowPower.self, Reboot.self, Bootlogo.self]
    )
}

extension Device {
    struct Reboot: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Request a full or userspace reboot (root); completion is proven by reconnecting"
        )
        @OptionGroup var output: OutputOptions
        @Flag(help: "Restart userspace only (launchd re-exec) instead of the whole device") var userspace = false
        @Flag(help: "Confirm the restart; required to run this command.") var force = false
        func run() {
            emit(allowWhenLocked: true, output) { try requestReboot(userspace: userspace, force: force) }
        }
    }

    struct Bootlogo: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Render a screen-sized JPEG 2000 boot logo from a mark image"
        )
        @OptionGroup var output: OutputOptions
        @Option(help: "PNG/JPEG mark image") var mark: String
        @Option(name: .customLong("output"), help: "Destination .jp2 path") var destination: String
        @Flag var dark = false
        @Option(help: "Canvas width in pixels (default: native screen)") var width: Int = 0
        @Option(help: "Canvas height in pixels (default: native screen)") var height: Int = 0
        @Option(help: "Maximum mark side length in points") var markPoints: Double = 128
        func run() {
            emit(allowWhenLocked: true, output) {
                try renderBootLogo(
                    mark: mark,
                    output: destination,
                    dark: dark,
                    width: width,
                    height: height,
                    markPoints: markPoints
                )
            }
        }
    }

    struct Info: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Model, iOS, battery, storage, jailbreak")
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, output) { try collectDeviceSnapshot() }
        }
    }

    struct Jetsam: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Jetsam bands, jetsam property lists and memory pressure",
            discussion: "The priority list needs root or com.apple.private.memorystatus; without it the result carries 'priorities_error' and the rest still comes back."
        )
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, output) { try jetsamSnapshot() }
        }
    }

    struct Brightness: ParsableCommand {
        static var configuration = CommandConfiguration(subcommands: [Get.self, Set.self])
        struct Get: ParsableCommand {
            @OptionGroup var output: OutputOptions
            func run() {
                emit(output) { brightnessReport(brightness()) }
            }
        }

        struct Set: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument(help: "Brightness from 0 to 1.") var value: Double
            func run() {
                emit(output) {
                    try setBrightness(value)
                    return brightnessReport(value)
                }
            }
        }
    }

    struct Volume: ParsableCommand {
        static var configuration = CommandConfiguration(subcommands: [Get.self, Set.self])
        struct Get: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Option var category: String = "Audio/Video"
            func run() {
                emit(output) {
                    var state = try audioState()
                    state["volume"] = volume(category)
                    state["category"] = category
                    return state
                }
            }
        }

        struct Set: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument(help: "Volume from 0 to 1.") var value: Double
            @Option var category: String = "Audio/Video"
            func run() {
                emit(output) { try setVolume(value, category: category) }
            }
        }
    }

    struct Rotation: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Display orientation",
            subcommands: [Get.self, Set.self, Lock.self]
        )
        struct Get: ParsableCommand {
            @OptionGroup var output: OutputOptions
            func run() {
                emit(output) { rotationInfo() }
            }
        }

        struct Set: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument(
                help: "Orientation: portrait (0), landscape-left (90), upside-down (180), or landscape-right (270)."
            )
            var value: String
            func run() {
                emit(output) { try setRotation(value) }
            }
        }

        struct Lock: ParsableCommand {
            static var configuration = CommandConfiguration(subcommands: [Get.self, Set.self])
            struct Get: ParsableCommand {
                @OptionGroup var output: OutputOptions
                func run() {
                    emit(output) { ["locked": rotationInfo()["locked"] ?? false] }
                }
            }

            struct Set: ParsableCommand {
                @OptionGroup var output: OutputOptions
                @Argument(help: "Set orientation lock to on or off.") var value: String
                func run() {
                    emit(output) { try setRotationLock(parseOnOff(value)) }
                }
            }
        }
    }

    struct Devmode: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Developer Mode status, and arming it when it is off",
            subcommands: [Get.self, Enable.self]
        )
        struct Get: ParsableCommand {
            static var configuration = CommandConfiguration(
                abstract: "Whether Developer Mode is on, armed for the next restart, and changeable"
            )
            @OptionGroup var output: OutputOptions
            func run() {
                emit(allowWhenLocked: true, output) { try developerModeStatus() }
            }
        }

        struct Enable: ParsableCommand {
            static var configuration = CommandConfiguration(
                abstract: "Arm Developer Mode so it turns on after the next restart",
                discussion: "Does nothing when Developer Mode is already on or armed. It does not restart the device; after the restart the user confirms the prompt on the device."
            )
            @OptionGroup var output: OutputOptions
            func run() {
                emit(allowWhenLocked: true, output) { try enableDeveloperMode() }
            }
        }
    }

    struct LowPower: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "low-power",
            abstract: "Low Power Mode",
            subcommands: [Get.self, Set.self]
        )
        struct Get: ParsableCommand {
            @OptionGroup var output: OutputOptions
            func run() {
                emit(allowWhenLocked: true, output) { try lowPowerMode() }
            }
        }

        struct Set: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument(help: "Turn Low Power Mode on or off.") var value: String
            func run() {
                emit(allowWhenLocked: true, output) { try setLowPowerMode(parseOnOff(value)) }
            }
        }
    }

    struct Network: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { networkInfo() }
        }
    }

    struct Ioreg: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option var plane: String = "IOService"
        func run() {
            emit(output) { try ioregistry(plane: plane) }
        }
    }
}

private func brightnessReport(_ level: Double) -> [String: Any] {
    var result: [String: Any] = ["brightness": level]
    if let auto = autoBrightness() {
        result["auto_brightness"] = auto
    }
    return result
}
