import Foundation
import IcliLaunchPrivate

// launchApp throws IcliSystem's IcliError, so a consumer of this product sees
// IcliSystem without a second import.
@_exported import IcliSystem

/// Whether the device is locked and whether its screen is off, from
/// SpringBoard's lock notification and its server port together.
public func lockState() -> [String: Any] {
    let lock = icli_lock_status()
    return ["locked": lock.locked, "screen_off": lock.screen_off]
}

public func frontmostApp() -> [String: Any] {
    (try? decodeBridgeJSON(takeCString(icli_frontmost_app_json()), "frontmost application"))
        ?? ["bundle_id": SystemShell.bundleID, "verified": false, "source": "unavailable"]
}

/// Brings an installed app to the front, launching it if it is not running,
/// and waits for the system to report it as the frontmost app, up to 30 seconds.
///
/// Throws `IcliError.locked` when the system refused because the device is
/// locked or its screen is off; it does not wait for an unlock. Any other
/// refusal (with the system shell's reason when it gave one), an app
/// LaunchServices does not know, or an app that did not report frontmost in
/// time is `IcliError.failed`.
public func launchApp(_ bundleID: String) throws -> [String: Any] {
    let apps = try listApps()["apps"] as? [[String: Any]] ?? []
    guard !bundleID.isEmpty, apps.contains(where: { $0["bundle_id"] as? String == bundleID }) else {
        throw IcliError.failed("app not found: \(bundleID)")
    }
    let watch = icli_frontmost_watch_start(bundleID)
    defer { icli_frontmost_watch_end(watch) }
    if frontmostApp()["bundle_id"] as? String == bundleID {
        return ["launched": bundleID, "frontmost": true]
    }
    var refusal: UnsafeMutablePointer<CChar>?
    let result = icli_launch_app(bundleID, &refusal)
    let reason = refusal.map { String(cString: $0) }
    free(refusal)
    switch result {
    case IcliLaunchAccepted:
        break
    case IcliLaunchLocked:
        throw IcliError.locked
    default:
        throw IcliError.failed("launch refused: \(bundleID)" + (reason.map { ": \($0)" } ?? ""))
    }
    guard icli_frontmost_watch_wait(watch, 30) else {
        throw IcliError.failed("launched but not frontmost: \(bundleID)")
    }
    return ["launched": bundleID, "frontmost": true]
}
