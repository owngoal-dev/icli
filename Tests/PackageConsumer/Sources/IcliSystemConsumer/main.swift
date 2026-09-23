import Foundation
import IcliSystem

/// The read-only system product on its own: no IcliKit, no private bridge
/// import, and no UIKit, Vision or LibArchive in the link.
let systemAPIs: [Any] = [
    deviceSnapshot as () throws -> [String: Any],
    listProcesses as (String?) throws -> [String: Any],
    listApps as () throws -> [String: Any],
    listTweaks as () throws -> [String: Any],
    listServices as () throws -> [String: Any],
    serviceStatus as (String) throws -> [String: Any],
    printService as (String) throws -> [String: Any],
    servicesDump as () throws -> [String: Any],
    disabledServiceOverrides as () throws -> [String: Any],
    launchdEnvironment as (String) throws -> [String: Any],
    jetsamSnapshot as () throws -> [String: Any],
]
precondition(systemAPIs.count == 11)
let snapshot = try deviceSnapshot()
precondition(snapshot["model"] as? String != nil)
let jetsam = try jetsamSnapshot()
let report: [String: Any] = try [
    "library": "IcliSystem",
    "api_count": systemAPIs.count,
    "layout": (snapshot["jailbreak"] as? [String: Any])?["layout"] ?? "",
    "processes": listProcesses(filter: nil)["count"] ?? 0,
    "apps": listApps()["count"] ?? 0,
    "services": listServices()["count"] ?? 0,
    "jetsam_priorities": (jetsam["priorities"] as? [[String: Any]])?.count ?? 0,
    "jetsam_priorities_error": jetsam["priorities_error"] ?? "",
    "jetsam_properties": (jetsam["properties"] as? [String: Any])?.count ?? 0,
]
try print(String(decoding: JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
