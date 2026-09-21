import ArgumentParser
import Foundation
import IcliKit
struct FS: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Filesystem",
        subcommands: [Ls.self, Read.self, Write.self, Find.self, Plist.self, PlistSet.self, Mkdir.self, Rm.self, Link.self, Chmod.self, Chown.self, Copy.self, Move.self]
    )
}

extension FS {
    struct PlistSet: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "plist-set", abstract: "Set (JSON value) or remove (--remove) one top-level plist key")
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Argument var key: String
        @Argument var value: String?
        @Flag var remove = false
        func run() { emit(allowWhenLocked: true, output) {
            guard remove != (value != nil) else { throw IcliError.failed("pass a JSON value or --remove") }
            return try setPlistValue(path, key: key, json: remove ? nil : value)
        } }
    }
    struct Mkdir: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Option(help: "Octal permissions, e.g. 755") var mode: String?
        func run() { emit(allowWhenLocked: true, output) { try makeDirectory(path, mode: mode) } }
    }
    struct Rm: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Flag var recursive = false
        @Flag(help: "Confirm removal; required to run this command.") var force = false
        func run() { emit(allowWhenLocked: true, output) { try removePath(path, recursive: recursive, force: force) } }
    }
    struct Link: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Create a symbolic link at <link> pointing to <target>")
        @OptionGroup var output: OutputOptions
        @Argument var target: String
        @Argument var link: String
        @Flag(help: "Replace an existing symbolic link at <link>.") var replace = false
        func run() { emit(allowWhenLocked: true, output) { try createSymlink(target: target, link: link, replace: replace) } }
    }
    struct Chmod: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Argument var mode: String
        func run() { emit(allowWhenLocked: true, output) { try changeMode(path, mode: mode) } }
    }
    struct Chown: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Argument(help: "uid:gid, numeric or by name") var owner: String
        func run() { emit(allowWhenLocked: true, output) { try changeOwner(path, owner: owner) } }
    }
    struct Copy: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var source: String
        @Argument var destination: String
        func run() { emit(allowWhenLocked: true, output) { try copyPath(source, to: destination) } }
    }
    struct Move: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var source: String
        @Argument var destination: String
        func run() { emit(allowWhenLocked: true, output) { try movePath(source, to: destination) } }
    }
    struct Ls: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        func run() { emit(output) { try listDirectory(path) } }
    }
    struct Read: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Flag(help: "Return file content as Base64, including text files.") var binary = false
        @Option(help: "Maximum bytes to read, from 0 to 67108864; defaults to 524288.") var limit: Int?
        func run() { emit(output) { try readFile(path, binary: binary, limit: limit) } }
    }
    struct Write: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Argument var content: String
        @Option(help: "Content encoding: utf8 or base64.") var encoding: String = "utf8"
        func run() { emit(output) { try writeFile(path, content: content, encoding: encoding) } }
    }
    struct Find: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var root: String
        @Argument var pattern: String
        func run() { emit(output) { try findFiles(root: root, pattern: pattern) } }
    }
    struct Plist: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        func run() { emit(output) { try readPlist(path) } }
    }
}

struct Log: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Capture system logs and read crash reports.", subcommands: [Syslog.self, Crashes.self, Crash.self])
}

extension Log {
    struct Syslog: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option var seconds: Double = 3
        @Option var process: String?
        @Option var level: String = "all"
        @Option var maxLines: Int = 500
        func run() { emit(allowWhenLocked: true, output) { try captureSyslog(seconds: seconds, process: process, level: level, maxLines: maxLines) } }
    }
    struct Crashes: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option var bundleID: String?
        func run() { emit(output) { try crashLogs(bundleID: bundleID) } }
    }
    struct Crash: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        func run() { emit(output) { try readCrashLog(path) } }
    }
}

struct Pkg: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Inspect, install, and remove Debian packages and manage package sources.",
        subcommands: [List.self, Install.self, Remove.self, Info.self, Extract.self, Status.self, Compare.self, Repos.self, AddRepo.self, Tweaks.self]
    )
}

extension Pkg {
    struct Info: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Control fields, scripts and file list of a .deb")
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        func run() { emit(allowWhenLocked: true, output) { try readDeb(path) } }
    }
    struct Extract: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Unpack a .deb into an empty directory (DEBIAN/ plus payload)")
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Argument var destination: String
        func run() { emit(allowWhenLocked: true, output) { try extractDeb(path, to: destination) } }
    }
    struct Status: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Installed state and version from dpkg's database")
        @OptionGroup var output: OutputOptions
        @Argument var name: String
        func run() { emit(allowWhenLocked: true, output) { try packageStatus(name) } }
    }
    struct Compare: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Compare two Debian version strings")
        @OptionGroup var output: OutputOptions
        @Argument var left: String
        @Argument var right: String
        func run() { emit(allowWhenLocked: true, output) { try compareDebianVersions(left, right) } }
    }
    struct List: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option var filter: String?
        func run() { emit(allowWhenLocked: true, output) { try listPackages(filter: filter) } }
    }
    struct Install: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Install a local .deb natively (root); maintainer scripts are reported, not run")
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Flag(help: "Install even when Depends/Pre-Depends are not satisfied") var ignoreDepends = false
        func run() { emit(allowWhenLocked: true, output) { try installDebFile(path, ignoreDependencies: ignoreDepends) } }
    }
    struct Remove: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Remove an installed Debian package. Requires root; keeps package configuration files unless --purge is supplied.")
        @OptionGroup var output: OutputOptions
        @Argument var name: String
        @Flag var purge = false
        func run() { emit(allowWhenLocked: true, output) { try removeDeb(name, purge: purge) } }
    }
    struct Repos: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(allowWhenLocked: true, output) { try listRepos() } }
    }
    struct AddRepo: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "add-repo")
        @OptionGroup var output: OutputOptions
        @Argument var url: String
        func run() { emit(allowWhenLocked: true, output) { try addRepo(url) } }
    }
    struct Tweaks: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(allowWhenLocked: true, output) { try listTweaks() } }
    }
}

struct SB: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Refresh app registrations, restart SpringBoard, and manage system app visibility.", subcommands: [Uicache.self, Respring.self, SystemApps.self])
}

extension SB {
    struct Uicache: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Refresh app registrations in the bootstrap's /Applications")
        @OptionGroup var output: OutputOptions
        func run() { emit(allowWhenLocked: true, output) { try refreshApps(directory: nil) } }
    }
    struct Respring: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(allowWhenLocked: true, output) { try respring() } }
    }
    struct SystemApps: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "system-apps", abstract: "Visibility of non-default system apps", subcommands: [Get.self, Set.self])
        struct Get: ParsableCommand {
            @OptionGroup var output: OutputOptions
            func run() { emit(allowWhenLocked: true, output) { try systemAppsVisibility(set: nil) } }
        }
        struct Set: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Argument var value: String
            func run() { emit(allowWhenLocked: true, output) { try systemAppsVisibility(set: try parseOnOff(value)) } }
        }
    }
}

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

extension Svc {
    struct Bootstrap: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Load services from plist files or directories.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "One or more existing service plist files or directories containing service plists.") var paths: [String]
        func run() { emit(allowWhenLocked: true, output) { try loadServices(paths, load: true, override: false) } }
    }
    struct Bootout: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Unload services from plist files or directories.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "One or more existing service plist files or directories containing service plists.") var paths: [String]
        func run() { emit(allowWhenLocked: true, output) { try loadServices(paths, load: false, override: false) } }
    }
    struct Load: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Load services from plist files or directories.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "One or more existing service plist files or directories containing service plists.") var paths: [String]
        @Flag(help: "Also clear a persistent disabled override (launchctl load -w)") var enable = false
        func run() { emit(allowWhenLocked: true, output) { try loadServices(paths, load: true, override: enable) } }
    }
    struct Unload: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Unload services from plist files or directories.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "One or more existing service plist files or directories containing service plists.") var paths: [String]
        @Flag(help: "Also set a persistent disabled override (launchctl unload -w)") var disable = false
        func run() { emit(allowWhenLocked: true, output) { try loadServices(paths, load: false, override: disable) } }
    }
    struct Enable: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Persistently enable a service by label.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Service label from its plist's Label key, without a domain prefix; for example, com.example.service.") var label: String
        func run() { emit(allowWhenLocked: true, output) { try setServiceEnabled(label, enabled: true) } }
    }
    struct Disable: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Persistently disable a service by label.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Service label from its plist's Label key, without a domain prefix; for example, com.example.service.") var label: String
        func run() { emit(allowWhenLocked: true, output) { try setServiceEnabled(label, enabled: false) } }
    }
    struct Start: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Request that a loaded service start.", discussion: "The service must already be loaded. An accepted request does not guarantee that the process stays running. Use 'icli svc status <label>' to check its state.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Service label from its plist's Label key, without a domain prefix; for example, com.example.service.") var label: String
        func run() { emit(allowWhenLocked: true, output) { try startService(label) } }
    }
    struct Stop: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Request that a running service stop.", discussion: "Stopping does not unload or disable the service. launchd may restart it if its KeepAlive conditions apply. Use 'icli svc status <label>' to check its state.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Service label from its plist's Label key, without a domain prefix; for example, com.example.service.") var label: String
        func run() { emit(allowWhenLocked: true, output) { try stopService(label) } }
    }
    struct Kill: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Send a signal number or name to a service instance")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Signal number from 1 to 31, or a name such as TERM or SIGTERM.") var signal: String
        @Argument(help: "Service label from its plist's Label key, without a domain prefix; for example, com.example.service.") var label: String
        func run() { emit(allowWhenLocked: true, output) { try signalService(label, signal: signal) } }
    }
    struct Remove: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Remove a loaded service by label")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Service label from its plist's Label key, without a domain prefix; for example, com.example.service.") var label: String
        func run() { emit(allowWhenLocked: true, output) { try removeService(label) } }
    }
    struct List: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "List services, or show the status of one service by label.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Service label without a domain prefix; omit to list all visible services.") var label: String?
        func run() { emit(allowWhenLocked: true, output) { try label.map(serviceStatus) ?? listServices() } }
    }
    struct Print: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Print launchd's detailed description of a service")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Service label from its plist's Label key, without a domain prefix; for example, com.example.service.") var label: String
        func run() { emit(allowWhenLocked: true, output) { try printService(label) } }
    }
    struct PrintDisabled: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "print-disabled", abstract: "Print persistent disabled-service overrides")
        @OptionGroup var output: OutputOptions
        func run() { emit(allowWhenLocked: true, output) { try disabledServiceOverrides() } }
    }
    struct Dump: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Every visible service with launchd's description, in one document.", discussion: "A label launchd refuses to describe is listed in 'errors'; the rest of the document is still returned.")
        @OptionGroup var output: OutputOptions
        func run() { emit(allowWhenLocked: true, output) { try servicesDump() } }
    }
    struct Getenv: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Read a launchd environment variable.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Launchd environment variable name, such as PATH.") var key: String
        func run() { emit(allowWhenLocked: true, output) { try launchdEnvironment(key) } }
    }
    struct Setenv: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Set a launchd environment variable and verify its value.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Launchd environment variable name, such as PATH.") var key: String
        @Argument(help: "Value to store; quote values containing spaces.") var value: String
        func run() { emit(allowWhenLocked: true, output) { try setLaunchdEnvironment(key, value: value) } }
    }
    struct Unsetenv: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Remove a launchd environment variable and verify removal.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Launchd environment variable name, such as PATH.") var key: String
        func run() { emit(allowWhenLocked: true, output) { try setLaunchdEnvironment(key, value: nil) } }
    }
    struct Status: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Show whether a service is enabled, loaded, and running.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Service label from its plist's Label key, without a domain prefix; for example, com.example.service.") var label: String
        func run() { emit(allowWhenLocked: true, output) { try serviceStatus(label) } }
    }
}

struct Account: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Bootstrap user accounts", subcommands: [SetPassword.self])
}

extension Account {
    struct SetPassword: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "set-password", abstract: "Read the new password from stdin (first line) and store it for the bootstrap account")
        @OptionGroup var output: OutputOptions
        @Argument var user: String = "mobile"
        func run() {
            emit(allowWhenLocked: true, output) {
                guard let line = readLine(strippingNewline: true) else { throw IcliError.failed("no password on stdin") }
                return try setAccountPassword(user: user, password: line)
            }
        }
    }
}

struct Env: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Runtime environment and capability report", subcommands: [Info.self, Basebin.self], defaultSubcommand: Info.self)
}

extension Env {
    struct Info: ParsableCommand {
        @OptionGroup var output: OutputOptions
        func run() { emit(allowWhenLocked: true, output) { try environmentReport() } }
    }
    struct Basebin: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Compare the installed BaseBin version with a bundled basebin.tar")
        @OptionGroup var output: OutputOptions
        @Option(help: "Path to a basebin archive containing basebin/.version") var bundled: String?
        func run() { emit(allowWhenLocked: true, output) { try compareBaseBin(bundled: bundled) } }
    }
}

struct Proc: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "List running processes.", subcommands: [List.self])
}

extension Proc {
    struct List: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option var filter: String?
        func run() { emit(output) { try listProcesses(filter: filter) } }
    }
}

struct Sec: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Manage keychain items and check for SSL Kill Switch files.", subcommands: [Keychain.self, SSLKillswitch.self])
}

extension Sec {
    struct Keychain: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Keychain items",
            subcommands: [List.self, Get.self, Add.self, Update.self, Delete.self],
            defaultSubcommand: List.self
        )
        struct List: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Option(name: .long, help: "generic_password, internet_password, certificate, key, identity")
            var `class`: String?
            @Option var service: String?
            @Option var account: String?
            @Option var server: String?
            @Option var group: String?
            func run() {
                emit(output) {
                    try listKeychain(
                        className: `class`,
                        service: service,
                        account: account,
                        server: server,
                        group: group,
                        includeData: false
                    )
                }
            }
        }
        struct Get: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Option var `class`: String = "generic_password"
            @Option var service: String?
            @Option var account: String?
            @Option var server: String?
            @Option var group: String?
            func run() {
                emit(output) {
                    try getKeychain(className: `class`, service: service, account: account, server: server, group: group)
                }
            }
        }
        struct Add: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Option var `class`: String = "generic_password"
            @Option var service: String?
            @Option var account: String
            @Option var server: String?
            @Option var label: String?
            @Option var group: String = "icli.test"
            @Option var data: String
            func run() {
                emit(output) {
                    try addKeychain(
                        className: `class`,
                        service: service,
                        account: account,
                        server: server,
                        label: label,
                        group: group,
                        data: data
                    )
                }
            }
        }
        struct Update: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Option var `class`: String = "generic_password"
            @Option var service: String?
            @Option var account: String
            @Option var server: String?
            @Option var group: String = "icli.test"
            @Option var data: String
            func run() {
                emit(output) {
                    try updateKeychain(
                        className: `class`,
                        service: service,
                        account: account,
                        server: server,
                        group: group,
                        data: data
                    )
                }
            }
        }
        struct Delete: ParsableCommand {
            @OptionGroup var output: OutputOptions
            @Option var `class`: String = "generic_password"
            @Option var service: String?
            @Option var account: String?
            @Option var server: String?
            @Option var group: String = "icli.test"
            @Flag var force = false
            func run() {
                emit(output) {
                    if !force { throw IcliError.forceRequired("delete keychain item") }
                    return try deleteKeychain(
                        className: `class`,
                        service: service,
                        account: account,
                        server: server,
                        group: group
                    )
                }
            }
        }
    }
    struct SSLKillswitch: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "ssl-killswitch", abstract: "Check for SSL Kill Switch files in known installation locations.")
        @OptionGroup var output: OutputOptions
        func run() { emit(output) { sslKillswitchStatus() } }
    }
}

struct Net: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Capture network traffic to a packet capture file.", subcommands: [Capture.self])
}

extension Net {
    struct Capture: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option var seconds: Double = 5
        @Option var interface: String = "en0"
        @Option(help: "[tcp|udp|icmp] [src|dst] port N [src|dst] host A, joined with and") var filter: String?
        @Option(name: .customLong("output"), help: "pcap path (default: a temporary file)") var path: String?
        func run() { emit(allowWhenLocked: true, output) { try capturePackets(seconds: seconds, interface: interface, filter: filter, output: path) } }
    }
}
