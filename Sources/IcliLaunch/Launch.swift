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
/// and waits up to five seconds for it to become the frontmost app.
///
/// Throws `IcliError.locked` when the system refused because the device is
/// locked or its screen is off; it does not wait for an unlock. Any other
/// refusal (with the system shell's reason when it gave one), an app
/// LaunchServices does not know, or an app that never came to the front is
/// `IcliError.failed`.
public func launchApp(_ bundleID: String) throws -> [String: Any] {
    let apps = try listApps()["apps"] as? [[String: Any]] ?? []
    guard !bundleID.isEmpty, apps.contains(where: { $0["bundle_id"] as? String == bundleID }) else {
        throw IcliError.failed("app not found: \(bundleID)")
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
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    repeat {
        if frontmostApp()["bundle_id"] as? String == bundleID {
            return ["launched": bundleID, "frontmost": true]
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw IcliError.failed("app did not become frontmost: \(bundleID)")
}
