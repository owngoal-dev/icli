import ArgumentParser
import Foundation
import IcliKit

struct Sec: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "Manage keychain items and check for SSL Kill Switch files.", subcommands: [Keychain.self, SSLKillswitch.self])
}

private let defaultKeychainGroup = "icli.test"

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
            @Option var group: String = defaultKeychainGroup
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
            @Option var group: String = defaultKeychainGroup
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
            @Option var group: String = defaultKeychainGroup
            @Flag var force = false
            func run() {
                emit(output) {
                    guard force else { throw IcliError.forceRequired("delete keychain item") }
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
        func run() {
            emit(output) { sslKillswitchStatus() }
        }
    }
}
