import ArgumentParser
import Foundation
import IcliKit
struct Screen: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Touch, screenshot, OCR",
        subcommands: [Tap.self, Swipe.self, LongPress.self, DoubleTap.self, Drag.self, Shot.self, Info.self, OCR.self, Describe.self]
    )
}

extension Screen {
    struct Tap: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var x: Double
        @Argument var y: Double
        func run() { emit(output) { try tap(x: x, y: y) } }
    }

    struct Swipe: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option var fromX: Double
        @Option var fromY: Double
        @Option var toX: Double
        @Option var toY: Double
        @Option var seconds: Double = 0.25
        @Option var steps: Int = 20
        func run() { emit(output) { try swipe(x1: fromX, y1: fromY, x2: toX, y2: toY, seconds: seconds, steps: steps) } }
    }

    struct LongPress: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "long-press")
        @OptionGroup var output: OutputOptions
        @Argument var x: Double
        @Argument var y: Double
        @Option var seconds: Double = 0.6
        func run() { emit(output) { try longPress(x: x, y: y, seconds: seconds) } }
    }

    struct DoubleTap: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "double-tap")
        @OptionGroup var output: OutputOptions
        @Argument var x: Double
        @Argument var y: Double
        @Option var interval: Double = 0.1
        func run() { emit(output) { try doubleTap(x: x, y: y, interval: interval) } }
    }

    struct Drag: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option var fromX: Double?
        @Option var fromY: Double?
        @Option var toX: Double?
        @Option var toY: Double?
        @Option(help: "JSON array of {x,y} points") var points: String?
        @Option var seconds: Double = 0.3
        @Option var hold: Double = 0.5
        @Option var steps: Int = 20
        func run() {
            emit(output) {
                let path: [(Double, Double)]
                if let points {
                    guard fromX == nil, fromY == nil, toX == nil, toY == nil else { throw IcliError.failed("provide points or endpoints, not both") }
                    guard let rows = try JSONSerialization.jsonObject(with: Data(points.utf8)) as? [[String: Double]] else { throw IcliError.failed("points must be a JSON array of {x,y}") }
                    path = try rows.map { row in
                        guard let x = row["x"], let y = row["y"] else { throw IcliError.failed("each point needs x and y") }
                        return (x, y)
                    }
                } else {
                    guard let fromX, let fromY, let toX, let toY else { throw IcliError.failed("provide points or all four endpoint coordinates") }
                    path = [(fromX, fromY), (toX, toY)]
                }
                return try drag(points: path, seconds: seconds, hold: hold, steps: steps)
            }
        }
    }

    struct Shot: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option(name: .customLong("output")) var path: String?
        @Flag var base64 = false
        @Flag var nativeResolution = false
        func run() { emit(allowWhenLocked: true, output) { try takeScreenshot(path: path, base64: base64, nativeResolution: nativeResolution) } }
    }

    struct Info: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(allowWhenLocked: true, output) { screenInfo() } }
    }

    struct OCR: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option var lang: [String] = ["zh-Hans", "en-US"]
        @Option var minConfidence: Float = 0.3
        func run() { emit(output) { try recognizeScreen(languages: lang, minConfidence: minConfidence) } }
    }

    struct Describe: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(output) { try describeScreen() } }
    }
}

struct Button: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Hardware buttons",
        subcommands: [Home.self, Power.self, VolumeUp.self, VolumeDown.self, Mute.self, Wake.self]
    )
}

extension Button {
    struct Home: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(output) { try pressButton("home") } }
    }
    struct Power: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(output) { try pressButton("power") } }
    }
    struct VolumeUp: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "volume-up")
        @OptionGroup var output: OutputOptions
        func run() { emit(output) { try pressButton("volume-up") } }
    }
    struct VolumeDown: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "volume-down")
        @OptionGroup var output: OutputOptions
        func run() { emit(output) { try pressButton("volume-down") } }
    }
    struct Mute: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(output) { try pressButton("mute") } }
    }
    struct Wake: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(allowWhenLocked: true, output) { try pressButton("wake") } }
    }
}

struct Input: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Text input",
        subcommands: [Paste.self, TypeText.self, Key.self]
    )
}

extension Input {
    struct Paste: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var text: String
        func run() { emit(output) { try pasteText(text) } }
    }
    struct TypeText: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "type")
        @OptionGroup var output: OutputOptions
        @Argument var text: String
        @Option(name: .customLong("delay-ms")) var delayMS: Double = 30
        func run() { emit(output) { try typeText(text, delayMS: delayMS) } }
    }
    struct Key: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var name: String
        func run() { emit(output) { try pressKey(name) } }
    }
}

struct UI: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Accessibility / OCR elements",
        subcommands: [Tree.self, At.self, Tap.self, Wait.self, WaitGone.self]
    )
}

struct ElementOptions: ParsableArguments {
    @Argument var text: String?
    @Option var identifier: String?
    @Option var role: String?
    @Option var match: String = "contains"
    @Option var index: Int = 0
    func selector() throws -> ElementSelector {
        try ElementSelector(text: text, identifier: identifier, role: role, match: match, index: index)
    }
}

extension UI {
    struct Tree: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option var maxElements: Int = 250
        @Option var limit: Int?
        @Flag var includeOffscreen = false
        @Flag var clickableOnly = false
        func run() { emit(output) { try uiElements(maxElements: maxElements, visibleOnly: !includeOffscreen, clickableOnly: clickableOnly, limit: limit) } }
    }
    struct At: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var x: Double
        @Argument var y: Double
        func run() { emit(output) { try elementAt(x: x, y: y) } }
    }
    struct Tap: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @OptionGroup var selection: ElementOptions
        func run() { emit(output) { try tapElement(selection.selector()) } }
    }
    struct Wait: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @OptionGroup var selection: ElementOptions
        @Option var timeout: Double = 10
        @Option var interval: Double = 0.3
        func run() { emit(output) { try waitForElement(selection.selector(), appear: true, timeout: timeout, interval: interval) } }
    }
    struct WaitGone: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "wait-gone")
        @OptionGroup var output: OutputOptions
        @OptionGroup var selection: ElementOptions
        @Option var timeout: Double = 10
        @Option var interval: Double = 0.3
        func run() { emit(output) { try waitForElement(selection.selector(), appear: false, timeout: timeout, interval: interval) } }
    }
}
