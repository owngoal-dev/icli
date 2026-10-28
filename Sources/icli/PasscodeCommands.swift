import ArgumentParser
import Darwin
import Foundation
import IcliKit

extension Device {
    struct Passcode: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Unlock the keybag with a supplied passcode, guarded against lockout",
            subcommands: [Status.self, Unlock.self, Forget.self],
        )

        struct Status: ParsableCommand {
            static var configuration = CommandConfiguration(
                abstract: "Keybag lock state, its failed-attempt counter and back-off, and the ledger",
            )
            @OptionGroup var output: OutputOptions
            func run() {
                emit(allowWhenLocked: true, output) { try passcodeStatus() }
            }
        }

        struct Unlock: ParsableCommand {
            static var configuration = CommandConfiguration(
                abstract: "Unlock the keybag with a passcode read from stdin, a file, or the terminal",
                discussion: """
                The passcode never comes from argv. Give --passcode-stdin (first \
                line of stdin) or --passcode-file (first line of a regular file \
                owned by this user and closed to group and others); with neither, \
                an interactive terminal is prompted without echo.

                Nothing is attempted when the keybag is already unlocked, when \
                this passcode was rejected before (the ledger keeps a salted \
                digest of every rejected passcode until an unlock succeeds), when \
                the failures reach --max-failures, or while the keybag backs off. \
                icli never guesses or generates passcodes.

                Exit status: 0 unlocked, 3 rejected now, 4 rejected before (not \
                retried), 5 refused by a guard, 6 keybag error not counted.
                """,
            )
            @OptionGroup var output: OutputOptions
            @Flag(help: "Read the passcode from the first line of stdin") var passcodeStdin = false
            @Option(help: "Read the passcode from the first line of this file (mode 0600 or stricter)")
            var passcodeFile: String?
            @Option(help: "Stop before the failure count reaches this (1-\(passcodeFailureCeiling))")
            var maxFailures = defaultPasscodeFailureLimit
            @Flag(help: "Run every guard and the ledger lookup, then stop before the attempt") var check = false

            func validate() throws {
                if passcodeStdin, passcodeFile != nil {
                    throw ValidationError("give either --passcode-stdin or --passcode-file, not both")
                }
            }

            func run() {
                emit(allowWhenLocked: true, output) {
                    var passcode = try readPasscode()
                    return try unlockDevice(passcode: &passcode, limit: maxFailures, checkOnly: check)
                }
            }

            private func readPasscode() throws -> [UInt8] {
                if passcodeStdin {
                    return firstLine(FileHandle.standardInput.readDataToEndOfFile())
                }
                if let passcodeFile {
                    return try firstLine(readProtectedFile(passcodeFile))
                }
                guard isatty(STDIN_FILENO) == 1 else {
                    throw IcliError.failed("no passcode source: pass --passcode-stdin or --passcode-file")
                }
                var buffer = [CChar](repeating: 0, count: 130)
                defer { memset_s(&buffer, buffer.count, 0, buffer.count) }
                guard readpassphrase("Device passcode: ", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
                    throw IcliError.failed("could not read the passcode from the terminal")
                }
                return buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            }

            /// The file's bytes, refused unless it is a regular file this user
            /// (or root) owns that group and others cannot read or write, as
            /// ssh treats a private key.
            private func readProtectedFile(_ path: String) throws -> Data {
                let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard fd >= 0 else {
                    throw IcliError.failed("cannot open \(path): \(String(cString: strerror(errno)))")
                }
                defer { close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                    throw IcliError.failed("\(path) is not a regular file")
                }
                guard info.st_uid == geteuid() || info.st_uid == 0 else {
                    throw IcliError.failed("\(path) must be owned by this user or root")
                }
                guard info.st_mode & 0o077 == 0 else {
                    throw IcliError.failed("\(path) is open to group or others; chmod 600 it")
                }
                guard info.st_size <= 4096 else {
                    throw IcliError.failed("\(path) is larger than a passcode file should be")
                }
                return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
            }

            private func firstLine(_ data: Data) -> [UInt8] {
                var bytes = [UInt8](data.prefix { $0 != UInt8(ascii: "\n") })
                if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
                return bytes
            }
        }

        struct Forget: ParsableCommand {
            static var configuration = CommandConfiguration(
                abstract: "Clear the ledger of rejected passcodes, after the device passcode changes",
            )
            @OptionGroup var output: OutputOptions
            @Flag(help: "Confirm clearing the ledger; required to run this command.") var force = false
            func run() {
                emit(allowWhenLocked: true, output) {
                    guard force else { throw IcliError.forceRequired("clear the passcode ledger") }
                    return try forgetPasscodeAttempts()
                }
            }
        }
    }
}
