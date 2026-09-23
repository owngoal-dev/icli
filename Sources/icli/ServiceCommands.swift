import ArgumentParser
import Foundation
import IcliKit

struct Svc: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Inspect and manage launchd services.",
        discussion: "Use plist paths with bootstrap, bootout, load, and unload. For commands that accept a label, use the plist's Label value without a domain prefix.\n\nEnable and disable set persistent overrides; they do not start or stop a process. Start and stop request a process change; check status afterward. A service with KeepAlive enabled may restart after stop.\n\nService changes require root and the launchd privileges granted by your jailbreak. Root alone may not provide every required privilege.\n\nExamples:\n  icli svc list\n  icli svc status com.example.service\n  icli svc start com.example.service\n  icli svc stop com.example.service\n\nRun 'icli svc <command> --help' for its arguments.",
        subcommands: [
            Bootstrap.self, Bootout.self, Load.self, Unload.self,
            Enable.self, Disable.self, Start.self, Stop.self,
            Kill.self, Remove.self, List.self, Print.self, PrintDisabled.self,
            Dump.self, Getenv.self, Setenv.self, Unsetenv.self, Status.self,
        ]
    )
}

private let servicePathsHelp: ArgumentHelp = "One or more existing service plist files or directories containing service plists."
private let serviceLabelHelp: ArgumentHelp = "Service label from its plist's Label key, without a domain prefix; for example, com.example.service."

extension Svc {
    struct Bootstrap: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Load services from plist files or directories.")
        @OptionGroup var output: OutputOptions
        @Argument(help: servicePathsHelp) var paths: [String]
        func run() {
            emit(allowWhenLocked: true, output) { try loadServices(paths, load: true, override: false) }
        }
    }

    struct Bootout: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Unload services from plist files or directories.")
        @OptionGroup var output: OutputOptions
        @Argument(help: servicePathsHelp) var paths: [String]
        func run() {
            emit(allowWhenLocked: true, output) { try loadServices(paths, load: false, override: false) }
        }
    }

    struct Load: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Load services from plist files or directories.")
        @OptionGroup var output: OutputOptions
        @Argument(help: servicePathsHelp) var paths: [String]
        @Flag(help: "Also clear a persistent disabled override (launchctl load -w)") var enable = false
        func run() {
            emit(allowWhenLocked: true, output) { try loadServices(paths, load: true, override: enable) }
        }
    }

    struct Unload: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Unload services from plist files or directories.")
        @OptionGroup var output: OutputOptions
        @Argument(help: servicePathsHelp) var paths: [String]
        @Flag(help: "Also set a persistent disabled override (launchctl unload -w)") var disable = false
        func run() {
            emit(allowWhenLocked: true, output) { try loadServices(paths, load: false, override: disable) }
        }
    }

    struct Enable: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Persistently enable a service by label.")
        @OptionGroup var output: OutputOptions
        @Argument(help: serviceLabelHelp) var label: String
        func run() {
            emit(allowWhenLocked: true, output) { try setServiceEnabled(label, enabled: true) }
        }
    }

    struct Disable: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Persistently disable a service by label.")
        @OptionGroup var output: OutputOptions
        @Argument(help: serviceLabelHelp) var label: String
        func run() {
            emit(allowWhenLocked: true, output) { try setServiceEnabled(label, enabled: false) }
        }
    }

    struct Start: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Request that a loaded service start.", discussion: "The service must already be loaded. An accepted request does not guarantee that the process stays running. Use 'icli svc status <label>' to check its state.")
        @OptionGroup var output: OutputOptions
        @Argument(help: serviceLabelHelp) var label: String
        func run() {
            emit(allowWhenLocked: true, output) { try startService(label) }
        }
    }

    struct Stop: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Request that a running service stop.", discussion: "Stopping does not unload or disable the service. launchd may restart it if its KeepAlive conditions apply. Use 'icli svc status <label>' to check its state.")
        @OptionGroup var output: OutputOptions
        @Argument(help: serviceLabelHelp) var label: String
        func run() {
            emit(allowWhenLocked: true, output) { try stopService(label) }
        }
    }

    struct Kill: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Send a signal number or name to a service instance")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Signal number from 1 to 31, or a name such as TERM or SIGTERM.") var signal: String
        @Argument(help: serviceLabelHelp) var label: String
        func run() {
            emit(allowWhenLocked: true, output) { try signalService(label, signal: signal) }
        }
    }

    struct Remove: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Remove a loaded service by label")
        @OptionGroup var output: OutputOptions
        @Argument(help: serviceLabelHelp) var label: String
        func run() {
            emit(allowWhenLocked: true, output) { try removeService(label) }
        }
    }

    struct List: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "List services, or show the status of one service by label.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Service label without a domain prefix; omit to list all visible services.") var label: String?
        func run() {
            emit(allowWhenLocked: true, output) { try label.map(serviceStatus) ?? listServices() }
        }
    }

    struct Print: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Print launchd's detailed description of a service")
        @OptionGroup var output: OutputOptions
        @Argument(help: serviceLabelHelp) var label: String
        func run() {
            emit(allowWhenLocked: true, output) { try printService(label) }
        }
    }

    struct PrintDisabled: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "print-disabled", abstract: "Print persistent disabled-service overrides")
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, output) { try disabledServiceOverrides() }
        }
    }

    struct Dump: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Every visible service with launchd's description, in one document.", discussion: "A label launchd refuses to describe is listed in 'errors'; the rest of the document is still returned.")
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, output) { try servicesDump() }
        }
    }

    struct Getenv: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Read a launchd environment variable.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Launchd environment variable name, such as PATH.") var key: String
        func run() {
            emit(allowWhenLocked: true, output) { try launchdEnvironment(key) }
        }
    }

    struct Setenv: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Set a launchd environment variable and verify its value.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Launchd environment variable name, such as PATH.") var key: String
        @Argument(help: "Value to store; quote values containing spaces.") var value: String
        func run() {
            emit(allowWhenLocked: true, output) { try setLaunchdEnvironment(key, value: value) }
        }
    }

    struct Unsetenv: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Remove a launchd environment variable and verify removal.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Launchd environment variable name, such as PATH.") var key: String
        func run() {
            emit(allowWhenLocked: true, output) { try setLaunchdEnvironment(key, value: nil) }
        }
    }

    struct Status: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Show whether a service is enabled, loaded, and running.")
        @OptionGroup var output: OutputOptions
        @Argument(help: serviceLabelHelp) var label: String
        func run() {
            emit(allowWhenLocked: true, output) { try serviceStatus(label) }
        }
    }
}
