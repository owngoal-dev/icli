import ArgumentParser
import Foundation
import IcliKit
struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Human-readable text instead of JSON")
    var human = false

    func apply() {
        Envelope.human = human
        if CommandLine.arguments.contains("--human") {
            Envelope.human = true
        }
    }
}

func emit(allowWhenLocked: Bool = false, _ output: OutputOptions, _ body: () throws -> [String: Any]) {
    output.apply()
    Envelope.run(allowWhenLocked: allowWhenLocked, body)
}

@main
struct Icli: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "icli",
        abstract: "On-device iOS control CLI",
        discussion: "Run 'icli <command> --help' to see its subcommands and 'icli <command> <subcommand> --help' for arguments and options.\n\nExamples:\n  icli device info\n  icli svc list --human\n  icli svc status com.example.service\n\nCommands return JSON by default. Add --human to an action command for readable text.",
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        subcommands: [
            Device.self, Screen.self, Button.self, Input.self, App.self,
            UI.self, Clipboard.self, FS.self, Log.self, URLCommand.self,
            Pkg.self, SB.self, Svc.self, Account.self, Env.self, Proc.self, Sec.self, Net.self, Prefs.self, Location.self, Tests.self,
        ]
    )
}
