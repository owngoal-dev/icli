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
        static var configuration = CommandConfiguration(
            commandName: "plist-set",
            abstract: "Set (JSON value) or remove (--remove) one top-level plist key"
        )
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Argument var key: String
        @Argument var value: String?
        @Flag var remove = false
        func run() {
            emit(allowWhenLocked: true, output) {
                guard remove != (value != nil) else { throw IcliError.failed("pass a JSON value or --remove") }
                return try setPlistValue(path, key: key, json: value)
            }
        }
    }

    struct Mkdir: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Option(help: "Octal permissions, e.g. 755") var mode: String?
        func run() {
            emit(allowWhenLocked: true, output) { try makeDirectory(path, mode: mode) }
        }
    }

    struct Rm: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Flag var recursive = false
        @Flag(help: "Confirm removal; required to run this command.") var force = false
        func run() {
            emit(allowWhenLocked: true, output) { try removePath(path, recursive: recursive, force: force) }
        }
    }

    struct Link: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Create a symbolic link at <link> pointing to <target>"
        )
        @OptionGroup var output: OutputOptions
        @Argument var target: String
        @Argument var link: String
        @Flag(help: "Replace an existing symbolic link at <link>.") var replace = false
        func run() {
            emit(allowWhenLocked: true, output) { try createSymlink(target: target, link: link, replace: replace) }
        }
    }

    struct Chmod: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Argument var mode: String
        func run() {
            emit(allowWhenLocked: true, output) { try changeMode(path, mode: mode) }
        }
    }

    struct Chown: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Argument(help: "uid:gid, numeric or by name") var owner: String
        func run() {
            emit(allowWhenLocked: true, output) { try changeOwner(path, owner: owner) }
        }
    }

    struct Copy: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var source: String
        @Argument var destination: String
        func run() {
            emit(allowWhenLocked: true, output) { try copyPath(source, to: destination) }
        }
    }

    struct Move: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var source: String
        @Argument var destination: String
        func run() {
            emit(allowWhenLocked: true, output) { try movePath(source, to: destination) }
        }
    }

    struct Ls: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        func run() {
            emit(output) { try listDirectory(path) }
        }
    }

    struct Read: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Flag(help: "Return file content as Base64, including text files.") var binary = false
        @Option(help: "Maximum bytes to read, from 0 to 67108864; defaults to 524288.") var limit: Int?
        func run() {
            emit(output) { try readFile(path, binary: binary, limit: limit) }
        }
    }

    struct Write: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        @Argument var content: String
        @Option(help: "Content encoding: utf8 or base64.") var encoding: String = "utf8"
        func run() {
            emit(output) { try writeFile(path, content: content, encoding: encoding) }
        }
    }

    struct Find: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var root: String
        @Argument var pattern: String
        func run() {
            emit(output) { try findFiles(root: root, pattern: pattern) }
        }
    }

    struct Plist: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Argument var path: String
        func run() {
            emit(output) { try readPlist(path) }
        }
    }
}
