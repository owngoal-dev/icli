import ArgumentParser
import Darwin
import Foundation
import IcliKit

struct Probe: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Run a JavaScriptCore script in-process: an ObjC bridge, files, and api() into icli.",
        discussion: """
        The script runs inline, in this icli process. There is no --detach: a \
        script that crashes or hangs takes icli down with it. To isolate one, \
        spawn `icli probe` as its own process.

        Examples:
          icli probe -e "ObjC.use('NSProcessInfo').processInfo().processName()"
          icli probe script.js
          echo "api('svc.list').count" | icli probe -
          icli probe repl

        Evaluation prints one JSON line {ok, result | error, output}: stdout \
        carries only that line, with everything the script printed collected \
        into output. The interactive REPL (`repl`, or no argument) writes its \
        output live instead.
        """,
    )

    @Option(name: [.customShort("e"), .customLong("eval")], help: "Evaluate this source instead of a file")
    var eval: String?

    @Argument(help: "A script file, '-' for stdin, or 'repl' for the interactive shell")
    var input: String?

    func run() throws {
        let source: String
        switch (eval, input) {
        case let (eval?, _):
            source = eval
        case (nil, nil), (nil, "repl"?):
            Darwin.exit(runProbeREPL())
        case (nil, "-"?):
            source = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        case let (nil, path?):
            do {
                source = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                // Answered on the same line as a script that threw, so a caller
                // that spawned `icli probe` has one shape to read.
                printProbeLine(["ok": false, "error": "cannot read script \(path): \(error.localizedDescription)", "output": ""])
                Darwin.exit(1)
            }
        }
        let result = evaluateProbe(source)
        var line: [String: Any] = ["ok": result.ok, "output": result.output]
        if let error = result.error { line["error"] = error } else { line["result"] = result.result }
        printProbeLine(line)
        Darwin.exit(result.ok ? 0 : 1)
    }

    /// The result as one compact line, so a reader can take stdout as a single
    /// JSON object and the script's own output stays inside `output`.
    private func printProbeLine(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"unencodable"}"#.utf8)
        try? FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
    }
}
