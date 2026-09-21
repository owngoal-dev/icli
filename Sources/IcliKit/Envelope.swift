import IcliPrivate
// The read-only system library is part of IcliKit's own API: a consumer that
// links IcliKit gets every IcliSystem function without a second import.
@_exported import IcliSystem
import Foundation
import Darwin

public enum Envelope {
    public static var human = false
    public static var warning: String?

    public static func applyLockPolicy(allowWhenLocked: Bool) throws {
        warning = nil
        icli_private_init()
        let status = icli_lock_status()
        guard status.locked || status.screen_off else { return }
        #if DEBUG
        let message = "device is locked or screen is off; debug build allowing execution"
        warning = message
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
        #else
        if !allowWhenLocked {
            throw IcliError.locked
        }
        #endif
    }

    public static func printJSON(_ value: Any) {
        let payload: Any
        if let warning, var dict = value as? [String: Any] {
            dict["warning"] = warning
            payload = dict
        } else {
            payload = value
        }
        if human, let dict = payload as? [String: Any] {
            fputs(humanText(dict), stdout)
            return
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data("{\"error\":\"failed\",\"message\":\"unencodable\"}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    public static func run(allowWhenLocked: Bool = false, _ body: () throws -> [String: Any]) {
        do {
            try applyLockPolicy(allowWhenLocked: allowWhenLocked)
            let result = try body()
            printJSON(result)
            if let status = result["status"] as? Int, status != 0 { Darwin.exit(Int32(min(max(status, 1), 255))) }
        } catch let error as IcliError {
            printJSON(error.payload)
            if case .locked = error { Darwin.exit(2) }
            if case .commandFailed(let result) = error {
                Darwin.exit(Int32(min(max(result["status"] as? Int ?? 1, 1), 255)))
            }
            Darwin.exit(1)
        } catch {
            printJSON(IcliError.failed(error.localizedDescription).payload)
            Darwin.exit(1)
        }
    }
}

private func humanText(_ dict: [String: Any], indent: String = "") -> String {
    dict.keys.sorted().map { key in
        let value = dict[key]!
        if let nested = value as? [String: Any] {
            return "\(indent)\(key):\n" + humanText(nested, indent: indent + "  ")
        }
        if let array = value as? [[String: Any]] {
            return "\(indent)\(key): (\(array.count))\n" + array.enumerated().map { i, item in
                "\(indent)  [\(i)]\n" + humanText(item, indent: indent + "    ")
            }.joined()
        }
        return "\(indent)\(key): \(value)\n"
    }.joined()
}
