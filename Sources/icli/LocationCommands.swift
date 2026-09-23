import ArgumentParser
import Foundation
import IcliKit

struct Location: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Simulate the device location or read the current one",
        discussion: "A simulated location applies to every app and stays on after icli exits, until 'icli location clear'.",
        subcommands: [Set.self, Clear.self, Get.self]
    )

    struct Set: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Simulate a fixed location and confirm locationd reports it",
            discussion: "Negative coordinates work as they are: icli location set -33.8688 151.2093. Give a negative altitude as --altitude=-10."
        )
        @OptionGroup var output: OutputOptions
        // Captures values such as -33.8688 that would otherwise parse as
        // options; it captures --help too, so validate() hands that back.
        @Argument(
            parsing: .allUnrecognized,
            help: ArgumentHelp(
                "Latitude (-90 to 90) and longitude (-180 to 180) in degrees.",
                valueName: "latitude longitude"
            )
        )
        var coordinate: [String]
        @Option(help: "Altitude in metres.") var altitude: Double = 0
        @Option(help: "Horizontal accuracy in metres.") var horizontalAccuracy: Double = 5
        @Option(help: "Vertical accuracy in metres.") var verticalAccuracy: Double = 5
        @Option(help: "Speed in metres per second (default: unknown).") var speed: Double?
        @Option(help: "Course in degrees from true north, 0 to less than 360 (default: unknown).") var course: Double?
        func validate() throws {
            if coordinate.contains("-h") || coordinate.contains("--help") {
                throw CleanExit.helpRequest(self)
            }
        }

        func run() {
            emit(allowWhenLocked: true, output) {
                let degrees = coordinate.compactMap(Double.init)
                guard coordinate.count == 2, degrees.count == 2 else {
                    throw IcliError.failed("pass a latitude and a longitude in degrees")
                }
                return try simulateLocation(
                    latitude: degrees[0],
                    longitude: degrees[1],
                    altitude: altitude,
                    horizontalAccuracy: horizontalAccuracy,
                    verticalAccuracy: verticalAccuracy,
                    speed: speed,
                    course: course
                )
            }
        }
    }

    struct Clear: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Stop simulating and return to the real location")
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, output) { try clearSimulatedLocation() }
        }
    }

    struct Get: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "The location CoreLocation reports to a client",
            discussion: "'fresh' is false when no new fix arrived within the timeout and the reading is locationd's last known location. 'simulated' is CoreLocation's own flag for a software-simulated fix."
        )
        @OptionGroup var output: OutputOptions
        @Option(help: "Seconds to wait for a fresh fix.") var timeout: Double = 10
        func run() {
            emit(allowWhenLocked: true, output) { try currentLocation(timeout: timeout) }
        }
    }
}
