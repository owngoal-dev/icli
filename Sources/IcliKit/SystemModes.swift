import IcliPrivate
import IcliSystem
import Foundation

private func amfiDeveloperMode(arm: Bool) throws -> [String: Any] {
    guard let raw = takeCString(icli_amfi_developer_mode_json(arm)),
          let reply = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
        throw IcliError.unavailable("amfid sent an unreadable Developer Mode reply.")
    }
    if let error = reply["error"] as? String { throw IcliError.unavailable(error) }
    guard reply["success"] as? Bool == true else {
        let privilege = geteuid() == 0 ? "" : " Try again as root."
        throw IcliError.unavailable("amfid refused the Developer Mode request.\(privilege)")
    }
    return reply
}

/// Developer Mode as amfid reports it. `enabled` is the current state,
/// `armed` means it turns on after the next restart once the user confirms,
/// and `writable` is whether this device lets the state change at all.
public func developerModeStatus() throws -> [String: Any] {
    let reply = try amfiDeveloperMode(arm: false)
    return [
        "enabled": reply["status"] as? Bool ?? false,
        "armed": reply["armed"] as? Bool ?? false,
        "writable": reply["writable"] as? Bool ?? false,
    ]
}

/// Arms Developer Mode when it is off: it turns on after the next restart,
/// once the user confirms the prompt. Does nothing when it is already on.
public func enableDeveloperMode() throws -> [String: Any] {
    var status = try developerModeStatus()
    status["already_enabled"] = status["enabled"]
    status["restart_required"] = false
    if status["enabled"] as? Bool == true || status["armed"] as? Bool == true {
        status["restart_required"] = status["enabled"] as? Bool != true
        return status
    }
    guard status["writable"] as? Bool == true else {
        throw IcliError.unavailable("This device does not allow Developer Mode to be changed.")
    }
    _ = try amfiDeveloperMode(arm: true)
    var armed = try developerModeStatus()
    guard armed["armed"] as? Bool == true else {
        throw IcliError.unavailable("amfid accepted the request, but Developer Mode is not armed.")
    }
    armed["already_enabled"] = false
    armed["restart_required"] = true
    return armed
}

/// Whether Low Power Mode is on, as every app sees it through NSProcessInfo.
/// Changes go through powerd, like the Control Center toggle.
public func lowPowerMode() throws -> [String: Any] {
    guard icli_low_power_mode_get() >= 0 else {
        throw IcliError.unavailable("powerd's Low Power Mode service is unavailable on this device.")
    }
    return ["enabled": ProcessInfo.processInfo.isLowPowerModeEnabled, "method": "powerd"]
}

/// Turns Low Power Mode on or off through powerd and confirms the change
/// through NSProcessInfo.
public func setLowPowerMode(_ enabled: Bool) throws -> [String: Any] {
    let before = try lowPowerMode()["enabled"] as? Bool ?? false
    guard icli_low_power_mode_set(enabled) else {
        throw IcliError.unavailable("powerd refused the Low Power Mode change. The process needs the com.apple.powerd.lowpowermode.allow entitlement.")
    }
    let deadline = Date().addingTimeInterval(2)
    while ProcessInfo.processInfo.isLowPowerModeEnabled != enabled || icli_low_power_mode_get() != (enabled ? 1 : 0) {
        guard Date() < deadline else {
            throw IcliError.unavailable("The device did not apply the Low Power Mode change.")
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return ["enabled": enabled, "changed": before != enabled, "method": "powerd"]
}
