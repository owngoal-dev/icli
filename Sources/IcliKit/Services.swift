import Darwin
import Foundation
import IcliPrivate
import IcliSystem

// launchd system-domain service mutations, spoken to directly over launchd's
// bootstrap pipe. They need root; the read-only half lives in IcliSystem.

private func decode(_ raw: String?) throws -> [String: Any] {
    try decodeBridgeJSON(raw, "launchd response")
}

/// Loads (or unloads) launchd property lists or directories of them. Files
/// that launchd rejects are reported per path; nothing is guessed.
public func loadServices(_ paths: [String], load: Bool, override: Bool) throws -> [String: Any] {
    let absolute = try absoluteServicePaths(paths)
    let rootHide = load && JailbreakRoot.current.layout == .roothide
    let patched = rootHide ? try patchRootHidePlists(absolute) : []
    var cStrings = absolute.map { UnsafePointer<CChar>(strdup($0)) }
    defer { cStrings.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
    let result = try decode(cStrings.withUnsafeMutableBufferPointer { buffer in
        takeCString(icli_launchd_load_json(buffer.baseAddress, Int32(buffer.count), load, override))
    })
    if let error = launchdStatusError(result, load ? "load" : "unload") {
        throw error
    }
    let errors = result["errors"] as? [String: Any] ?? [:]
    var services: [[String: Any]] = []
    for path in absolute {
        for plist in launchdPlists(at: path) {
            guard let label = NSDictionary(contentsOfFile: plist)?["Label"] as? String else { continue }
            var row = try serviceStatus(label)
            row["path"] = plist
            services.append(row)
        }
    }
    let unexpected = services.filter { ($0["loaded"] as? Bool) != load }
    var payload: [String: Any] = [
        "paths": absolute,
        "loaded": load,
        "services": services,
        "errors": errors,
        "verified": true,
    ]
    if rootHide {
        payload["patched"] = patched
    }
    if !errors.isEmpty {
        // launchd reports EEXIST/EALREADY (load) or 113 ENOSERVICE (unload) when a
        // service was already in the requested state.
        let benign = errors.values.allSatisfy {
            (($0 as? [String: Any])?["code"] as? Int).map { load ? $0 == EEXIST || $0 == EALREADY : $0 == 113 } ?? false
        }
        if !benign {
            throw IcliError.failed("launchd rejected \(errors.count) path(s): \(errors)")
        }
        payload["unchanged"] = true
    }
    if !unexpected.isEmpty {
        throw IcliError.failed("\(unexpected.count) service(s) did not reach the requested state: \(unexpected.compactMap { $0["label"] })")
    }
    return payload
}

/// RootHide's launchctl rewrites a plist's paths in place before it
/// bootstraps it (see LaunchdPlistPaths); icli speaks to launchd itself, so
/// it makes the same rewrite. Returns the plists it wrote. A plist launchd
/// cannot parse is left for launchd to refuse.
private func patchRootHidePlists(_ paths: [String]) throws -> [String] {
    let root = JailbreakRoot.current.jbroot
    var patched: [String] = []
    for plist in paths.flatMap(launchdPlists(at:)) {
        guard let (job, format) = readLaunchdJob(plist),
              let prepared = LaunchdPlistPaths.prepared(job, plistPath: plist, root: root)
        else { continue }
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: prepared, format: format, options: 0)
        } catch {
            throw IcliError.failed("cannot encode the RootHide paths of \(plist): \(error.localizedDescription)")
        }
        try replaceKeepingOwnership(plist, with: data)
        patched.append(plist)
    }
    return patched
}

/// Writes `data` over the file `path` resolves to through a temporary file
/// beside it, keeping its owner and mode: launchd refuses a daemon plist that
/// is not root-owned or is writable by others.
private func replaceKeepingOwnership(_ path: String, with data: Data) throws {
    let target = (path as NSString).resolvingSymlinksInPath
    var original = stat()
    guard stat(target, &original) == 0 else {
        throw IcliError.failed("cannot read \(target): \(String(cString: strerror(errno)))")
    }
    var template = Array(((target as NSString).deletingLastPathComponent + "/.icli-plist.XXXXXX").utf8CString)
    let fd = mkstemp(&template)
    guard fd >= 0 else { throw IcliError.failed("cannot write beside \(target): \(String(cString: strerror(errno)))") }
    let temporary = String(cString: template)
    var written = data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if count <= 0 {
                return false
            }
            offset += count
        }
        return true
    }
    written = written && fchown(fd, original.st_uid, original.st_gid) == 0
        && fchmod(fd, original.st_mode & 0o7777) == 0 && fsync(fd) == 0
    let failure = String(cString: strerror(errno))
    close(fd)
    guard written, rename(temporary, target) == 0 else {
        unlink(temporary)
        throw IcliError.failed("cannot rewrite \(target) for RootHide: \(written ? String(cString: strerror(errno)) : failure)")
    }
}

/// Persistent enable/disable override for a label in the system domain.
public func setServiceEnabled(_ label: String, enabled: Bool) throws -> [String: Any] {
    try validateServiceLabel(label)
    let before = try serviceStatus(label)
    if before["enabled"] as? Bool == enabled {
        return ["label": label, "enabled": enabled, "changed": false]
    }
    let result = try decode(takeCString(icli_launchd_enable_json(label, enabled)))
    if let error = launchdStatusError(result, enabled ? "enable" : "disable") {
        throw error
    }
    let after = try serviceStatus(label)
    guard after["enabled"] as? Bool == enabled else {
        throw IcliError.failed("launchd accepted the request but the override did not change")
    }
    return ["label": label, "enabled": enabled, "changed": true]
}

private func serviceActionResult(
    _ raw: String?,
    label: String,
    action: String,
    benignStatuses: Set<Int> = [],
) throws -> [String: Any] {
    let result = try decode(raw)
    let status = result["status"] as? Int ?? 0
    if !benignStatuses.contains(status), let error = launchdStatusError(result, action) {
        throw error
    }
    var payload: [String: Any] = [
        "action": action,
        "label": label,
        "accepted": true,
        "unchanged": benignStatuses.contains(status),
        "launchd_status": status,
        "message": result["message"] as? String ?? "",
    ]
    if let pid = result["pid"] as? Int, pid > 0 {
        payload["pid"] = pid
    }
    if let domain = result["domain"] as? String, !domain.isEmpty {
        payload["domain"] = domain
    }
    return payload
}

public func startService(_ label: String) throws -> [String: Any] {
    try validateServiceLabel(label)
    return try serviceActionResult(
        takeCString(icli_launchd_start_json(label)),
        label: label,
        action: "start",
        benignStatuses: [Int(EALREADY)],
    )
}

/// launchctl kickstart: spawns the job now, whether or not its launch
/// conditions hold. With `kill`, a running instance is killed first and
/// launchd waits for it to exit, so the new process runs the binary as it is
/// on disk now; without it a running service is left alone and reported
/// unchanged.
public func kickstartService(_ label: String, kill: Bool) throws -> [String: Any] {
    try validateServiceLabel(label)
    guard geteuid() == 0 else { throw IcliError.failed("kickstart requires root") }
    let previousPID = kill ? nil : try serviceStatus(label)["pid"] as? Int
    var result = try serviceActionResult(
        takeCString(icli_launchd_kickstart_json(label, kill)),
        label: label,
        action: "kickstart",
        benignStatuses: [Int(EALREADY)],
    )
    // iOS 27 answers success and the existing pid for an already running
    // job, rather than EALREADY. Compare the process launchd reports.
    if !kill, let previousPID, previousPID > 0, result["pid"] as? Int == previousPID {
        result["unchanged"] = true
    }
    result["kill"] = kill
    return result
}

public func stopService(_ label: String) throws -> [String: Any] {
    try validateServiceLabel(label)
    return try serviceActionResult(
        takeCString(icli_launchd_stop_json(label)),
        label: label,
        action: "stop",
        benignStatuses: [Int(EALREADY)],
    )
}

public func removeService(_ label: String) throws -> [String: Any] {
    try validateServiceLabel(label)
    return try serviceActionResult(
        takeCString(icli_launchd_remove_json(label)),
        label: label,
        action: "remove",
        benignStatuses: [113],
    )
}

public func signalService(_ label: String, signal: String) throws -> [String: Any] {
    try validateServiceLabel(label)
    let number = try parseSignal(signal)
    var result = try serviceActionResult(
        takeCString(icli_launchd_kill_json(label, number)),
        label: label,
        action: "kill",
    )
    result["signal"] = number
    return result
}

public func setLaunchdEnvironment(_ key: String, value: String?) throws -> [String: Any] {
    try validateEnvironmentKey(key)
    if value?.contains("\0") == true {
        throw IcliError.failed("environment value contains a NUL byte")
    }
    let result = try decode(takeCString(icli_launchd_setenv_json(key, value ?? "", value == nil)))
    if let error = launchdStatusError(result, value == nil ? "unsetenv" : "setenv") {
        throw error
    }
    let after = try launchdEnvironment(key)
    let matches = value.map { after["value"] as? String == $0 } ?? (after["exists"] as? Bool == false)
    guard matches else { throw IcliError.failed("launchd accepted the environment change but read-back did not match") }
    var payload: [String: Any] = ["key": key, "exists": value != nil, "verified": true]
    payload["value"] = value ?? NSNull()
    return payload
}

private func parseSignal(_ value: String) throws -> Int32 {
    if let number = Int32(value), number > 0, number < 32 {
        return number
    }
    var name = value.uppercased()
    if name.hasPrefix("SIG") {
        name.removeFirst(3)
    }
    let names: [String: Int32] = [
        "HUP": 1, "INT": 2, "QUIT": 3, "ILL": 4, "TRAP": 5, "ABRT": 6,
        "EMT": 7, "FPE": 8, "KILL": 9, "BUS": 10, "SEGV": 11, "SYS": 12,
        "PIPE": 13, "ALRM": 14, "TERM": 15, "URG": 16, "STOP": 17,
        "TSTP": 18, "CONT": 19, "CHLD": 20, "TTIN": 21, "TTOU": 22,
        "IO": 23, "XCPU": 24, "XFSZ": 25, "VTALRM": 26, "PROF": 27,
        "WINCH": 28, "INFO": 29, "USR1": 30, "USR2": 31,
    ]
    guard let number = names[name] else { throw IcliError.failed("invalid signal: \(value)") }
    return number
}

/// Restarts SpringBoard with FrontBoard's relaunch action (what sbreload
/// sends); if the pid has not changed after a few seconds, asks launchd to
/// stop the service so KeepAlive brings it back. Returns the new pid.
public func respring() throws -> [String: Any] {
    func springboardPID() throws -> Int? {
        let processes = try listProcesses(filter: "SpringBoard")["processes"] as? [[String: Any]] ?? []
        return processes.first { $0["name"] as? String == "SpringBoard" }?["pid"] as? Int
    }
    func wait(seconds: Double, before: Int?) throws -> Int? {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if let now = try springboardPID(), now != before {
                return now
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }
    let before = try springboardPID()
    var method = "frontboard_relaunch"
    var pid = icli_springboard_relaunch() ? try wait(seconds: 5, before: before) : nil
    if pid == nil {
        method = "launchd_stop"
        let status = icli_launchd_stop("com.apple.SpringBoard")
        guard status == 0 else {
            throw IcliError.failed("relaunch action ignored and launchd stop failed: \(status) \(String(cString: icli_launchd_strerror(status)))")
        }
        pid = try wait(seconds: 15, before: before)
    }
    guard let pid else { throw IcliError.failed("SpringBoard did not restart") }
    return ["restarted": true, "method": method, "previous_pid": before ?? 0, "pid": pid]
}
