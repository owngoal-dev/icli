import ArgumentParser
import Foundation
import IcliKit
struct App: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Installed apps",
        subcommands: [
            List.self, Search.self, Running.self, Frontmost.self, Info.self,
            Launch.self, Open.self, Kill.self, Install.self, Uninstall.self,
            Register.self, Unregister.self, Refresh.self, UnregisterDir.self, Network.self,
            Handlers.self, Schemes.self, Binary.self, Data.self,
        ]
    )
}

extension App {
    struct Refresh: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Register new or moved apps, skip unchanged apps, and drop stale registrations")
        @OptionGroup var output: OutputOptions
        @Option(help: "Directory of .app bundles (default: the bootstrap's /Applications)") var directory: String?
        func run() { emit(allowWhenLocked: true, output) { try refreshApps(directory: directory) } }
    }
    struct UnregisterDir: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "unregister-dir", abstract: "Unregister every registered app whose bundle is directly inside a directory")
        @OptionGroup var output: OutputOptions
        @Argument var directory: String
        @Flag var force = false
        func run() { emit(allowWhenLocked: true, output) { try unregisterAppsInDirectory(directory, force: force) } }
    }
    struct Network: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Per-app Wi-Fi/cellular data policy", subcommands: [Get.self, Repair.self])
        struct Get: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument var bundleID: String
            func run() { emit(allowWhenLocked: true, output) { try appNetworkPolicy(bundleID, repair: false) } }
        }
        struct Repair: ParsableCommand {
            static var configuration = CommandConfiguration(abstract: "Set both policies to always-allow and read them back")
            @OptionGroup var output: OutputOptions
            @Argument var bundleID: String
            func run() { emit(allowWhenLocked: true, output) { try appNetworkPolicy(bundleID, repair: true) } }
        }
    }
    struct List: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(output) { try listApps() } }
    }
    struct Search: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var query: String
        func run() { emit(output) { try searchApps(query) } }
    }
    struct Running: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(output) { try runningApps() } }
    }
    struct Frontmost: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(output) { frontmostApp() } }
    }
    struct Info: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        func run() { emit(output) { try appInfo(bundleID) } }
    }
    struct Launch: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        func run() { emit(output) { try launchApp(bundleID) } }
    }
    struct Open: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var url: String
        @Option var bundle: String?
        func run() { emit(output) { try openAppURL(url, bundleID: bundle) } }
    }
    struct Kill: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        @Flag var force = false
        func run() { emit(output) { try killApp(bundleID, force: force) } }
    }
    struct Install: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        func run() { emit(output) { try installPackage(path) } }
    }
    struct Uninstall: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        @Flag var force = false
        @Flag(help: "Remove a DEB package identifier") var package = false
        func run() { emit(output) {
            if package {
                guard force else { throw IcliError.forceRequired("uninstall package \(bundleID)") }
                return try removeDeb(bundleID)
            }
            return try uninstallApp(bundleID, force: force)
        } }
    }
    struct Register: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        func run() { emit(allowWhenLocked: true, output) { try registerApp(path) } }
    }
    struct Unregister: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Flag var force = false
        func run() { emit(allowWhenLocked: true, output) { try unregisterApp(path, force: force) } }
    }
    struct Handlers: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var urlOrScheme: String
        func run() { emit(output) { try appHandlers(urlOrScheme) } }
    }
    struct Schemes: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(output) { try appURLSchemes() } }
    }
    struct Binary: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        func run() { emit(output) { try appBinaryInfo(bundleID) } }
    }
    struct Data: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        func run() { emit(output) { try appDataDir(bundleID) } }
    }
}

struct Clipboard: ParsableCommand {
    static var configuration = CommandConfiguration(subcommands: [Get.self, Set.self])
}

extension Clipboard {
    struct Get: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(output) { try clipboardText() } }
    }
    struct Set: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var text: String
        func run() { emit(output) { try setClipboard(text) } }
    }
}

struct URLCommand: ParsableCommand {
    static var configuration = CommandConfiguration(commandName: "url", subcommands: [Open.self])
}

extension URLCommand {
    struct Open: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var url: String
        func run() { emit(output) { try openURL(url) } }
    }
}
