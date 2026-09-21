import IcliSystemPrivate
import Foundation
import Darwin

/// Model, kernel, boot, storage and bootstrap facts: everything about the
/// device that sysctl and the filesystem answer. Battery and lock state need
/// the UIKit/SpringBoard bridge and are added by IcliKit's
/// `collectDeviceSnapshot()`.
public func deviceSnapshot() throws -> [String: Any] {
    let root = JailbreakRoot.current
    var uts = utsname()
    uname(&uts)
    let machine = cStringField(&uts.machine)
    let release = cStringField(&uts.release)
    let sysname = cStringField(&uts.sysname)

    let info = ProcessInfo.processInfo
    let version = info.operatingSystemVersion
    let disk = try diskUsage("/")

    let boot = takeCString(icli_boot_info_json()).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
    return [
        "model": machine,
        "sysname": sysname,
        "kernel": release,
        "boot_time": boot["boot_time"] ?? 0,
        "boot_session_uuid": boot["boot_session_uuid"] ?? "",
        "uptime_seconds": boot["uptime_seconds"] ?? 0,
        "ios_version": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
        "host": info.hostName,
        "memory_bytes": info.physicalMemory,
        "processor_count": info.processorCount,
        "storage": disk,
        "jailbreak": [
            "layout": root.layout.rawValue,
            "jbroot": root.jbroot,
            "source": root.source,
        ],
    ]
}

private func diskUsage(_ path: String) throws -> [String: Any] {
    let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ])
    return [
        "total_bytes": values.volumeTotalCapacity ?? 0,
        "available_bytes": values.volumeAvailableCapacity ?? 0,
    ]
}

private func cStringField<T>(_ value: inout T) -> String {
    withUnsafeBytes(of: &value) { raw in
        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
}
