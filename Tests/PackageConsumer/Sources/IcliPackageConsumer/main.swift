import Foundation
import IcliKit

// This consumer imports only the public library product. No CLI entry point,
// ArgumentParser dependency, or private bridge import is needed.
let comparison = try compareDebianVersions("1.0~beta", "1.0")
precondition(comparison["relation"] as? String == "lt")
let packages = try packageStatus("com.icli.icli")
precondition(packages["installed"] as? Bool == true)
let environment = try environmentReport()
precondition(environment["spawns_processes"] as? Bool == false)
let report: [String: Any] = [
    "library": "IcliKit",
    "comparison": comparison,
    "installed_version": packages["version"] ?? "",
    "layout": environment["layout"] ?? "",
]
print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
