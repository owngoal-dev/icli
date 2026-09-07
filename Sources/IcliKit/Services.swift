import IcliPrivate
import Foundation
import Darwin

// launchd system-domain services, spoken to directly over launchd's
// bootstrap pipe. Mutations need root; status works for any caller.

private func decode(_ raw: String?) throws -> [String: Any] {
    guard let raw, let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw IcliError.failed("invalid launchd response") }
    if let error = result["error"] as? String { throw IcliError.failed(error) }
    return result
}

private func launchdError(_ result: [String: Any], _ action: String) -> IcliError? {
    let status = result["status"] as? Int ?? 0
    if status == EPERM || status == EACCES { return .failed("\(action) requires root (launchd status \(status))") }
    if status != 0 { return .failed("\(action) failed: launchd status \(status) (\(result["message"] as? String ?? ""))") }
    return nil
}

private func validLabel(_ label: String) throws {
    guard label.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$", options: .regularExpression) != nil else { throw IcliError.failed("invalid service label") }
}

/// Loads (or unloads) launchd property lists or directories of them. Files
/// that launchd rejects are reported per path; nothing is guessed.
public func loadServices(_ paths: [String], load: Bool, override: Bool) throws -> [String: Any] {
    guard !paths.isEmpty else { throw IcliError.failed("at least one plist or directory path is required") }
    let absolute = paths.map { ($0 as NSString).standardizingPath }.map { $0.hasPrefix("/") ? $0 : FileManager.default.currentDirectoryPath + "/" + $0 }
    for path in absolute where !FileManager.default.fileExists(atPath: path) { throw IcliError.failed("path not found: \(path)") }
    var cStrings = absolute.map { UnsafePointer<CChar>(strdup($0)) }
    defer { cStrings.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
    let result = try decode(cStrings.withUnsafeMutableBufferPointer { buffer in takeCString(icli_launchd_load_json(buffer.baseAddress, Int32(buffer.count), load, override)) })
    if let error = launchdError(result, load ? "load" : "unload") { throw error }
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
    var payload: [String: Any] = ["paths": absolute, "loaded": load, "services": services, "errors": errors, "verified": unexpected.isEmpty && errors.isEmpty]
    if !errors.isEmpty {
        // launchd reports EEXIST/EALREADY (load) or 113 ENOSERVICE (unload) when a
        // service was already in the requested state.
        let benign = errors.values.allSatisfy { (($0 as? [String: Any])?["code"] as? Int).map { load ? $0 == EEXIST || $0 == EALREADY : $0 == 113 } ?? false }
        payload["unchanged"] = benign
        if !benign { throw IcliError.failed("launchd rejected \(errors.count) path(s): \(errors)") }
        payload["verified"] = unexpected.isEmpty
    }
    if !unexpected.isEmpty { throw IcliError.failed("\(unexpected.count) service(s) did not reach the requested state: \(unexpected.compactMap { $0["label"] })") }
    return payload
}

private func launchdPlists(at path: String) -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return [] }
    if !isDirectory.boolValue { return [path] }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    return names.filter { $0.hasSuffix(".plist") }.sorted().map { (path as NSString).appendingPathComponent($0) }
}

/// Persistent enable/disable override for a label in the system domain.
public func setServiceEnabled(_ label: String, enabled: Bool) throws -> [String: Any] {
    try validLabel(label)
    let before = try serviceStatus(label)
    if before["enabled"] as? Bool == enabled { return ["label": label, "enabled": enabled, "changed": false] }
    let result = try decode(takeCString(icli_launchd_enable_json(label, enabled)))
    if let error = launchdError(result, enabled ? "enable" : "disable") { throw error }
    let after = try serviceStatus(label)
    guard after["enabled"] as? Bool == enabled else { throw IcliError.failed("launchd accepted the request but the override did not change") }
    return ["label": label, "enabled": enabled, "changed": true]
}

/// enabled: no disabled override; loaded: launchd knows the service; running: it has a pid.
public func serviceStatus(_ label: String) throws -> [String: Any] {
    try validLabel(label)
    let disabled = try decode(takeCString(icli_launchd_disabled_json()))
    let overrides = disabled["disabled"] as? [String: Bool] ?? [:]
    if disabled["status"] as? Int != 0 {
        throw IcliError.failed("launchd did not report disabled services: status \(disabled["status"] ?? 0)")
    }
    let listed = try decode(takeCString(icli_launchd_service_json(label)))
    var payload: [String: Any] = ["label": label, "enabled": !(overrides[label] ?? false), "override": overrides[label] != nil, "loaded": false, "running": false]
    var domains: [String] = []
    for domain in ["system", "user"] {
        let record = listed[domain] as? [String: Any] ?? [:]
        let status = record["status"] as? Int ?? 0
        if status == 113 { continue } // ENOSERVICE
        if status != 0 { throw IcliError.failed("launchd list failed in the \(domain) domain: status \(status)") }
        let service = record["service"] as? [String: Any] ?? [:]
        let pid = service["PID"] as? Int ?? 0
        domains.append(domain)
        payload["loaded"] = true
        if pid > 0 || payload["pid"] == nil {
            payload["running"] = pid > 0
            payload["pid"] = pid
            payload["last_exit_status"] = service["LastExitStatus"] ?? 0
        }
        if let program = service["Program"] { payload["program"] = program }
    }
    payload["domains"] = domains
    return payload
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
            if let now = try springboardPID(), now != before { return now }
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
        guard status == 0 else { throw IcliError.failed("relaunch action ignored and launchd stop failed: \(status) \(String(cString: icli_launchd_strerror(status)))") }
        pid = try wait(seconds: 15, before: before)
    }
    guard let pid else { throw IcliError.failed("SpringBoard did not restart") }
    return ["restarted": true, "method": method, "previous_pid": before ?? 0, "pid": pid]
}
