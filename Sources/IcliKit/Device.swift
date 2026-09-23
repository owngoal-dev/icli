import Darwin
import Foundation
import IcliPrivate
import IcliSystem

/// IcliSystem's device snapshot plus the battery and lock state that only the
/// UIKit/SpringBoard bridge can answer.
public func collectDeviceSnapshot() throws -> [String: Any] {
    icli_private_init()
    let lock = icli_lock_status()
    var snapshot = try deviceSnapshot()
    snapshot["battery"] = [
        "fraction": icli_battery_fraction(),
        "state": icli_battery_state(),
    ] as [String: Any]
    snapshot["lock"] = [
        "locked": lock.locked,
        "screen_off": lock.screen_off,
        "passcode_enabled": icli_passcode_set(),
    ]
    return snapshot
}

public func screenInfo() -> [String: Any] {
    icli_private_init()
    let m = icli_screen_metrics()
    let lock = icli_lock_status()
    return [
        "width": m.width,
        "height": m.height,
        "scale": m.scale,
        "orientation": m.orientation,
        "locked": lock.locked,
        "screen_off": lock.screen_off,
    ]
}

public func brightness() -> Double {
    icli_brightness_get()
}

/// Whether auto-brightness is on, or nil when it cannot be read.
public func autoBrightness() -> Bool? {
    let auto = icli_auto_brightness()
    return auto < 0 ? nil : auto == 1
}

public func setBrightness(_ value: Double) throws {
    guard value.isFinite, (0 ... 1).contains(value) else { throw IcliError.failed("brightness must be between 0 and 1") }
    guard icli_brightness_set(value) else { throw IcliError.failed("could not set brightness") }
    Thread.sleep(forTimeInterval: 0.1)
    guard abs(icli_brightness_get() - value) <= 0.02 else {
        throw IcliError.unavailable("The device did not apply the requested brightness.")
    }
}

public func volume(_ category: String = "Audio/Video") -> Double {
    icli_volume_get(category)
}

public func audioState() throws -> [String: Any] {
    try decodeBridgeJSON(takeCString(icli_active_audio_json()), "audio state")
}

public func setVolume(_ value: Double, category: String = "Audio/Video") throws -> [String: Any] {
    guard value.isFinite, (0 ... 1).contains(value) else { throw IcliError.failed("volume must be between 0 and 1") }
    guard icli_volume_set(value, category) else { throw IcliError.failed("could not set volume") }
    return [
        "volume": icli_volume_get(category),
        "category": category,
    ]
}

public func rotationInfo() -> [String: Any] {
    icli_private_init()
    let rotation = icli_rotation_get()
    return [
        "degrees": rotation.degrees,
        "name": rotationName(rotation.degrees),
        "locked": rotation.locked,
        "device_orientation": rotation.device_orientation,
    ]
}

public func setRotation(_ spec: String) throws -> [String: Any] {
    let degrees = try parseRotationSpec(spec)
    guard icli_rotation_set(Int32(degrees)) else {
        throw IcliError.failed("could not set rotation to \(degrees)")
    }
    usleep(200_000)
    var info = rotationInfo()
    guard info["degrees"] as? Int32 == Int32(degrees) else {
        throw IcliError.unavailable("The device did not apply the requested rotation.")
    }
    info["requested"] = degrees
    return info
}

public func setRotationLock(_ locked: Bool) throws -> [String: Any] {
    guard icli_rotation_lock_set(locked) else {
        throw IcliError.failed("could not set rotation lock")
    }
    usleep(100_000)
    let info = rotationInfo()
    guard info["locked"] as? Bool == locked else {
        throw IcliError.unavailable("The device did not apply the orientation lock change.")
    }
    return info
}

private func rotationName(_ degrees: Int32) -> String {
    switch degrees {
    case 0: "portrait"
    case 90: "landscape-left"
    case 180: "upside-down"
    case 270: "landscape-right"
    default: "unknown"
    }
}

private func parseRotationSpec(_ spec: String) throws -> Int {
    switch spec.lowercased() {
    case "0", "portrait": return 0
    case "90", "landscape-left", "left": return 90
    case "180", "upside-down", "portrait-upside-down": return 180
    case "270", "landscape-right", "right": return 270
    default: throw IcliError.failed("unknown rotation: \(spec)")
    }
}

public func parseOnOff(_ spec: String) throws -> Bool {
    switch spec.lowercased() {
    case "on", "true", "1": return true
    case "off", "false", "0": return false
    default: throw IcliError.failed("expected on or off: \(spec)")
    }
}

public func networkInfo() -> [String: Any] {
    var addresses: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
        return ["addresses": []]
    }
    defer { freeifaddrs(ifaddr) }
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let iface = ptr {
        defer { ptr = iface.pointee.ifa_next }
        guard let address = iface.pointee.ifa_addr else { continue }
        let sa = address.pointee
        if sa.sa_family == UInt8(AF_INET) || sa.sa_family == UInt8(AF_INET6) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.pointee.ifa_addr, socklen_t(sa.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let name = String(cString: iface.pointee.ifa_name)
            let ip = String(cString: host)
            addresses.append("\(name) \(ip)")
        }
    }
    return ["addresses": addresses]
}

public func ioregistry(plane: String) throws -> [String: Any] {
    guard let raw = takeCString(icli_ioreg_json(plane)),
          let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw IcliError.failed("ioreg dump failed")
    }
    return obj
}
