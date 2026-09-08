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
        @Flag var force = false
        func run() { emit(allowWhenLocked: true, output) { try removePath(path, recursive: recursive, force: force) } }
    }
    struct Link: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Create a symbolic link at <link> pointing to <target>")
        @OptionGroup var output: OutputOptions
        @Argument var target: String
        @Argument var link: String
        @Flag var replace = false
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
        @Flag var binary = false
        @Option var limit: Int?
        func run() { emit(output) { try readFile(path, binary: binary, limit: limit) } }
    }
    struct Write: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Argument var content: String
        @Option var encoding: String = "utf8"
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
    static var configuration = CommandConfiguration(subcommands: [Syslog.self, Crashes.self, Crash.self])
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
        static var configuration = CommandConfiguration(abstract: "Remove an installed package natively (root); conffiles are kept unless --purge")
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
    static var configuration = CommandConfiguration(subcommands: [Uicache.self, Respring.self, SystemApps.self])
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
    static var configuration = CommandConfiguration(abstract: "launchd system services", subcommands: [Load.self, Unload.self, Enable.self, Disable.self, Status.self])
}

extension Svc {
    struct Load: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Load plists or directories of plists into the system domain")
        @OptionGroup var output: OutputOptions
        @Argument var paths: [String]
        @Flag(help: "Also clear a persistent disabled override (launchctl load -w)") var enable = false
        func run() { emit(allowWhenLocked: true, output) { try loadServices(paths, load: true, override: enable) } }
    }
    struct Unload: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var paths: [String]
        @Flag(help: "Also set a persistent disabled override (launchctl unload -w)") var disable = false
        func run() { emit(allowWhenLocked: true, output) { try loadServices(paths, load: false, override: disable) } }
    }
    struct Enable: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var label: String
        func run() { emit(allowWhenLocked: true, output) { try setServiceEnabled(label, enabled: true) } }
    }
    struct Disable: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var label: String
        func run() { emit(allowWhenLocked: true, output) { try setServiceEnabled(label, enabled: false) } }
    }
    struct Status: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "enabled / loaded / running for one label")
        @OptionGroup var output: OutputOptions
        @Argument var label: String
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
    static var configuration = CommandConfiguration(subcommands: [List.self])
}

extension Proc {
    struct List: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option var filter: String?
        func run() { emit(output) { try listProcesses(filter: filter) } }
    }
}

struct Sec: ParsableCommand {
    static var configuration = CommandConfiguration(subcommands: [Keychain.self, SSLKillswitch.self])
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
        static var configuration = CommandConfiguration(commandName: "ssl-killswitch")
        @OptionGroup var output: OutputOptions
        func run() { emit(output) { sslKillswitchStatus() } }
    }
}

struct Net: ParsableCommand {
    static var configuration = CommandConfiguration(subcommands: [Capture.self])
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
