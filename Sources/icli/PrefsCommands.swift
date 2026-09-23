import ArgumentParser
import Foundation
import IcliKit

struct Prefs: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Read and change preference domains through cfprefsd, like defaults.",
        discussion: "<domain> is a domain such as com.apple.springboard or an absolute path to a .plist file. --user defaults to mobile, even under sudo.",
        subcommands: [Read.self, Write.self, Delete.self]
    )
}

struct PreferenceUserOption: ParsableArguments {
    @Option(help: "Whose preferences: mobile, root, current or any.") var user: String = "mobile"

    func parsed() throws -> PreferenceUser {
        guard let user = PreferenceUser(rawValue: user) else { throw IcliError.failed("--user must be mobile, root, current or any") }
        return user
    }
}

private let notifyHelp: ArgumentHelp = "Darwin notification to post after the change."

extension Prefs {
    struct Read: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "One key with its type, or the whole domain as {key: {value, type}}")
        @OptionGroup var output: OutputOptions
        @OptionGroup var user: PreferenceUserOption
        @Argument var domain: String
        @Argument var key: String?
        func run() {
            emit(allowWhenLocked: true, output) { try readPreference(domain: domain, key: key, user: user.parsed()) }
        }
    }

    struct Write: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Set one key and return the value read back")
        @OptionGroup var output: OutputOptions
        @OptionGroup var user: PreferenceUserOption
        @Argument var domain: String
        @Argument var key: String
        @Argument var value: String
        @Option(help: "string, int, float, bool, date (ISO-8601 or epoch seconds), data (Base64) or json (array or object).") var type: String = "string"
        @Option(help: notifyHelp) var notify: String?
        func run() {
            emit(allowWhenLocked: true, output) {
                try writePreference(domain: domain, key: key, value: PreferenceValue(text: value, type: type), user: user.parsed(), notify: notify)
            }
        }
    }

    struct Delete: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Remove one key and confirm it is gone")
        @OptionGroup var output: OutputOptions
        @OptionGroup var user: PreferenceUserOption
        @Argument var domain: String
        @Argument var key: String
        @Option(help: notifyHelp) var notify: String?
        func run() {
            emit(allowWhenLocked: true, output) { try deletePreference(domain: domain, key: key, user: user.parsed(), notify: notify) }
        }
    }
}
