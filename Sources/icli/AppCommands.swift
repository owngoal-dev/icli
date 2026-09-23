import ArgumentParser
import Foundation
import IcliKit

extension AppRegistrationType: ExpressibleByArgument {}

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
        static var configuration = CommandConfiguration(
            abstract: "Register new, moved or updated apps, skip unchanged apps, and drop stale registrations"
        )
        @OptionGroup var output: OutputOptions
        @Option(help: "Directory of .app bundles (default: the bootstrap's /Applications)") var directory: String?
        func run() {
            emit(allowWhenLocked: true, output) { try refreshApps(directory: directory) }
        }
    }

    struct UnregisterDir: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "unregister-dir",
            abstract: "Unregister every registered app whose bundle is directly inside a directory"
        )
        @OptionGroup var output: OutputOptions
        @Argument var directory: String
        @Flag var force = false
        func run() {
            emit(allowWhenLocked: true, output) { try unregisterAppsInDirectory(directory, force: force) }
        }
    }

    struct Network: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Per-app Wi-Fi/cellular data policy",
            subcommands: [Get.self, Repair.self]
        )
        struct Get: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument var bundleID: String
            func run() {
                emit(allowWhenLocked: true, output) { try appNetworkPolicy(bundleID, repair: false) }
            }
        }

        struct Repair: ParsableCommand {
            static var configuration = CommandConfiguration(
                abstract: "Set both policies to always-allow and read them back"
            )
            @OptionGroup var output: OutputOptions
            @Argument var bundleID: String
            func run() {
                emit(allowWhenLocked: true, output) { try appNetworkPolicy(bundleID, repair: true) }
            }
        }
    }

    struct List: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { try listApps() }
        }
    }

    struct Search: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var query: String
        func run() {
            emit(output) { try searchApps(query) }
        }
    }

    struct Running: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { try runningApps() }
        }
    }

    struct Frontmost: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { frontmostApp() }
        }
    }

    struct Info: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        func run() {
            emit(output) { try appInfo(bundleID) }
        }
    }

    struct Launch: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        func run() {
            emit(output) { try launchApp(bundleID) }
        }
    }

    struct Open: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var url: String
        @Option var bundle: String?
        func run() {
            emit(output) { try openAppURL(url, bundleID: bundle) }
        }
    }

    struct Kill: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        @Flag var force = false
        func run() {
            emit(output) { try killApp(bundleID, force: force) }
        }
    }

    struct Install: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Install a .deb, an .ipa or a .app bundle",
            discussion: "An .ipa goes into the bootstrap's /Applications, or with --container into its own app container under /var/containers/Bundle/Application with a data container, like an App Store app. icli does not re-sign the app, so the IPA must already be signed so that this device can run it."
        )
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Flag(help: "Install the .ipa into its own app container; reinstalling an app icli installed this way upgrades it in place.")
        var container = false
        @Option(help: "How LaunchServices lists a --container app: user or system (default: user).")
        var registration: AppRegistrationType?
        func run() {
            emit(output) {
                guard container || registration == nil else {
                    throw IcliError.failed("--registration applies only with --container")
                }
                return try installPackage(path, container: container, registration: registration ?? .user)
            }
        }
    }

    struct Uninstall: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        @Flag(help: "Required. Removes an app icli installed from an IPA, including its app and data containers for a --container install.")
        var force = false
        @Flag(help: "Treat <bundle-id> as an installed Debian package identifier and remove that package; requires --force.")
        var package = false
        func run() {
            emit(output) {
                if package {
                    guard force else { throw IcliError.forceRequired("uninstall package \(bundleID)") }
                    return try removeDeb(bundleID)
                }
                return try uninstallApp(bundleID, force: force)
            }
        }
    }

    struct Register: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        func run() {
            emit(allowWhenLocked: true, output) { try registerApp(path) }
        }
    }

    struct Unregister: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Flag var force = false
        func run() {
            emit(allowWhenLocked: true, output) { try unregisterApp(path, force: force) }
        }
    }

    struct Handlers: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var urlOrScheme: String
        func run() {
            emit(output) { try appHandlers(urlOrScheme) }
        }
    }

    struct Schemes: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() {
            emit(output) { try appURLSchemes() }
        }
    }

    struct Binary: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        func run() {
            emit(output) { try appBinaryInfo(bundleID) }
        }
    }

    struct Data: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var bundleID: String
        func run() {
            emit(output) { try appDataDir(bundleID) }
        }
    }
}

struct Clipboard: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Read or replace the clipboard's text or image.",
        subcommands: [Get.self, Set.self]
    )
}

extension Clipboard {
    struct Get: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Text, change count, types, and the image's pixel size if there is one"
        )
        @OptionGroup var output: OutputOptions
        @Option(help: "Write the clipboard image to this path as PNG.") var imageOutput: String?
        func run() {
            emit(output) { try clipboardInfo(imageOutput: imageOutput) }
        }
    }

    struct Set: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Replace the clipboard with text or an image and read it back"
        )
        @OptionGroup var output: OutputOptions
        @Argument var text: String?
        @Option(help: "PNG, JPEG or HEIC file to copy instead of text.") var image: String?
        func run() {
            emit(output) {
                switch (text, image) {
                case (let text?, nil): return try setClipboard(text)
                case (nil, let image?):
                    return try setClipboardImage(Data(contentsOf: URL(fileURLWithPath: image)))
                default: throw IcliError.failed("pass either text or --image")
                }
            }
        }
    }
}

struct URLCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "url",
        abstract: "Open a URL in its registered app.",
        subcommands: [Open.self]
    )
}

extension URLCommand {
    struct Open: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var url: String
        func run() {
            emit(output) { try openURL(url) }
        }
    }
}
