import Darwin
import Foundation
import IcliSystemPrivate

public func listProcesses(filter: String?) throws -> [String: Any] {
    let result = try decodeBridgeJSON(takeCString(icli_processes_json()), "process list")
    var rows = result["processes"] as? [[String: Any]] ?? []
    if let filter {
        rows = rows.filter { ($0["name"] as? String ?? "").localizedCaseInsensitiveContains(filter) }
    }
    return ["processes": rows, "count": rows.count]
}

public func listTweaks() throws -> [String: Any] {
    let root = JailbreakRoot.current
    let dirs = [
        root.jbrootPath("/Library/MobileSubstrate/DynamicLibraries"),
        root.jbrootPath("/usr/lib/TweakInject"),
        "/usr/lib/TweakInject",
    ]
    var dylibs: [String] = []
    for dir in dirs {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        dylibs.append(contentsOf: names.filter { $0.hasSuffix(".dylib") }.map { (dir as NSString).appendingPathComponent($0) })
    }
    return ["tweaks": dylibs]
}
