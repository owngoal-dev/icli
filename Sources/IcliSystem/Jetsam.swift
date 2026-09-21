import IcliSystemPrivate
import Foundation
import Darwin

/// The kernel's memory policy: every process's jetsam band and limit, the
/// jetsam property lists shipped with the OS, and the memory pressure sysctls.
/// `priorities` needs root or `com.apple.private.memorystatus`; without it the
/// snapshot carries `priorities_error` and the rest still comes back.
public func jetsamSnapshot() throws -> [String: Any] {
    var result = try decodeBridgeJSON(takeCString(icli_jetsam_json()), "jetsam response")
    result["properties"] = jetsamProperties()
    return result
}

/// Every `com.apple.jetsamproperties.*.plist` in /System/Library/LaunchDaemons,
/// keyed by file name, with values reduced to JSON-safe types.
private func jetsamProperties() -> [String: Any] {
    let directory = "/System/Library/LaunchDaemons"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    var properties: [String: Any] = [:]
    for name in names.sorted() where name.hasPrefix("com.apple.jetsamproperties.") && name.hasSuffix(".plist") {
        let path = (directory as NSString).appendingPathComponent(name)
        guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
        properties[name] = jsonSafe(plist)
    }
    return properties
}

private func jsonSafe(_ value: Any) -> Any {
    switch value {
    case let dictionary as [String: Any]: return dictionary.mapValues(jsonSafe)
    case let array as [Any]: return array.map(jsonSafe)
    case let data as Data: return data.base64EncodedString()
    case let date as Date: return ISO8601DateFormatter().string(from: date)
    case let number as NSNumber: return number
    case let string as String: return string
    default: return String(describing: value)
    }
}
