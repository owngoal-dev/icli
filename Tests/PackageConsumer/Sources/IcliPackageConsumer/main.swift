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
let launchdAPIs: [Any] = [
    listServices as () throws -> [String: Any],
    disabledServiceOverrides as () throws -> [String: Any],
    serviceStatus as (String) throws -> [String: Any],
    printService as (String) throws -> [String: Any],
    startService as (String) throws -> [String: Any],
    stopService as (String) throws -> [String: Any],
    removeService as (String) throws -> [String: Any],
    kickstartService as (String, Bool, Bool) throws -> [String: Any],
    signalService as (String, String) throws -> [String: Any],
    launchdEnvironment as (String) throws -> [String: Any],
    setLaunchdEnvironment as (String, String?) throws -> [String: Any],
]
precondition(launchdAPIs.count == 11)
let report: [String: Any] = [
    "library": "IcliKit",
    "comparison": comparison,
    "installed_version": packages["version"] ?? "",
    "layout": environment["layout"] ?? "",
    "launchd_api_count": launchdAPIs.count,
]
print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
