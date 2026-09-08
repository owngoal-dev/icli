import IcliPrivate
import Foundation
import Darwin

public func listApps() throws -> [String: Any] {
    icli_private_init()
    var apps = decodeJSONArray(takeCString(icli_apps_json()) ?? "[]")
    apps.append(contentsOf: scanApplicationDirs())
    apps = uniqued(apps, key: "bundle_id")
    return ["apps": apps, "count": apps.count]
}

public func searchApps(_ query: String) throws -> [String: Any] {
    let all = try listApps()["apps"] as? [[String: Any]] ?? []
    let q = query.lowercased()
    let hits = all.filter { app in
        (app["bundle_id"] as? String)?.lowercased().contains(q) == true
            || (app["name"] as? String)?.lowercased().contains(q) == true
    }
    return ["query": query, "apps": hits]
}

public func frontmostApp() -> [String: Any] {
    icli_private_init()
    return ["bundle_id": takeCString(icli_frontmost_bundle_id()) ?? "com.apple.springboard"]
}

public func runningApps() throws -> [String: Any] {
    let apps = try listApps()["apps"] as? [[String: Any]] ?? []
    let processes = try listProcesses(filter: nil)["processes"] as? [[String: Any]] ?? []
    let running = apps.compactMap { app -> [String: Any]? in
        guard let process = processes.first(where: { processMatchesApp($0, app) }) else { return nil }
        var result = app
        result["pid"] = process["pid"]
        result["executable"] = process["executable"]
        return result
    }
    return ["apps": running, "count": running.count]
}

private func processMatchesApp(_ process: [String: Any], _ app: [String: Any]) -> Bool {
    guard let bundle = app["bundle_path"] as? String,
          let executable = Bundle(path: bundle)?.executablePath,
          let processPath = process["executable"] as? String, !processPath.isEmpty else { return false }
    return URL(fileURLWithPath: executable).resolvingSymlinksInPath().path == URL(fileURLWithPath: processPath).resolvingSymlinksInPath().path
}

func frontmostPID() throws -> Int32 {
    let bundleID = frontmostApp()["bundle_id"] as? String ?? "com.apple.springboard"
    let processes = try listProcesses(filter: nil)["processes"] as? [[String: Any]] ?? []
    if bundleID == "com.apple.springboard", let process = processes.first(where: { $0["name"] as? String == "SpringBoard" }), let pid = process["pid"] as? Int {
        return Int32(pid)
    }
    let app = try appInfo(bundleID)
    guard let process = processes.first(where: { processMatchesApp($0, app) }), let pid = process["pid"] as? Int else {
        throw IcliError.failed("frontmost app process not found: \(bundleID)")
    }
    return Int32(pid)
}

public func appInfo(_ bundleID: String) throws -> [String: Any] {
    let apps = try listApps()["apps"] as? [[String: Any]] ?? []
    guard let app = apps.first(where: { ($0["bundle_id"] as? String) == bundleID }) else {
        throw IcliError.failed("app not found: \(bundleID)")
    }
    var info = app
    if let bundle = app["bundle_path"] as? String {
        let executable = Bundle(path: bundle)?.executablePath ?? ""
        info["executable"] = executable
        let metadata = NSDictionary(contentsOfFile: bundle + "/Info.plist")
        info["minimum_os"] = metadata?["MinimumOSVersion"] ?? ""
        info["sdk"] = metadata?["DTSDKName"] ?? ""
        do {
            let signing = try machOInfo(at: executable)
            info["entitlements"] = signing["entitlements"]
            info["encrypted"] = signing["encrypted"]
        } catch { info["signing_error"] = String(describing: error) }
    }
    return info
}

public func launchApp(_ bundleID: String) throws -> [String: Any] {
    _ = try appInfo(bundleID)
    guard icli_launch_app(bundleID) else { throw IcliError.failed("launch failed: \(bundleID)") }
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    repeat {
        if frontmostApp()["bundle_id"] as? String == bundleID { return ["launched": bundleID, "frontmost": true] }
        Thread.sleep(forTimeInterval: 0.1)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw IcliError.failed("app did not become frontmost: \(bundleID)")
}

public func killApp(_ bundleID: String, force: Bool) throws -> [String: Any] {
    if !force { throw IcliError.forceRequired("kill \(bundleID)") }
    let app = try appInfo(bundleID)
    let processes = try listProcesses(filter: nil)["processes"] as? [[String: Any]] ?? []
    let pids = processes.filter { processMatchesApp($0, app) }.compactMap { $0["pid"] as? Int }
    for pid in pids {
        if Darwin.kill(Int32(pid), SIGTERM) != 0 && errno != ESRCH { throw IcliError.failed("could not stop app: \(String(cString: strerror(errno)))") }
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    repeat {
        let remaining = try listProcesses(filter: nil)["processes"] as? [[String: Any]] ?? []
        if !remaining.contains(where: { processMatchesApp($0, app) }) { return ["killed": bundleID, "pids": pids, "already_stopped": pids.isEmpty] }
        Thread.sleep(forTimeInterval: 0.1)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw IcliError.failed("app is still running: \(bundleID)")
}

public func installPackage(_ path: String) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path) else { throw IcliError.failed("package not found: \(path)") }
    if path.lowercased().hasSuffix(".deb") {
        return try installDebFile(path)
    }
    if path.hasSuffix(".app") || path.hasSuffix(".app/") {
        return try registerApp(path)
    }
    if path.lowercased().hasSuffix(".ipa") {
        return try installIPA(path)
    }

    throw IcliError.failed("unsupported package: \(path)")
}

public func uninstallApp(_ bundleID: String, force: Bool) throws -> [String: Any] {
    if !force { throw IcliError.forceRequired("uninstall \(bundleID)") }
    if let result = try uninstallManagedApp(bundleID) { return result }
    guard icli_uninstall_app(bundleID) else {
        throw IcliError.failed("uninstall failed: \(bundleID)")
    }
    return ["uninstalled": bundleID]
}

private func decodeApps(_ raw: String?) throws -> [String: Any] {
    guard let raw, let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw IcliError.failed("invalid application response") }
    if let error = result["error"] as? String { throw IcliError.failed(error) }
    return result
}

/// LaunchServices' record for a bundle path, or registered=false.
public func appRegistration(_ path: String) throws -> [String: Any] {
    try decodeApps(takeCString(icli_app_registration_json(path)))
}

public func registerApp(_ path: String) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path + "/Info.plist") else { throw IcliError.failed("not an app bundle: \(path)") }
    guard icli_register_app(path) else { throw IcliError.failed("register failed: \(path)") }
    var record = try appRegistration(path)
    guard record["registered"] as? Bool == true else { throw IcliError.failed("LaunchServices did not list the app after registration: \(path)") }
    record["path"] = path
    return record
}

public func unregisterApp(_ path: String, force: Bool) throws -> [String: Any] {
    if !force { throw IcliError.forceRequired("unregister \(path)") }
    let before = try appRegistration(path)
    guard before["registered"] as? Bool == true else { return ["unregistered": false, "path": path, "message": "app is not registered"] }
    guard icli_unregister_app(path) else { throw IcliError.failed("unregister failed: \(path)") }
    guard try appRegistration(path)["registered"] as? Bool == false else { throw IcliError.failed("LaunchServices still lists the app after unregistration: \(path)") }
    return ["unregistered": true, "path": path, "bundle_id": before["bundle_id"] ?? ""]
}

/// Registers new or moved bundles in a directory (default: the bootstrap's
/// /Applications), skips unchanged apps, and drops missing bundles' registrations.
public func refreshApps(directory: String?) throws -> [String: Any] {
    let root = directory ?? JailbreakRoot.current.jbrootPath("/Applications")
    let result = try decodeApps(takeCString(icli_apps_refresh_json(root)))
    let failed = result["failed"] as? [String] ?? []
    let unverified = result["unverified"] as? [String] ?? []
    guard failed.isEmpty, unverified.isEmpty else { throw IcliError.commandFailed(result.merging(["error": "refresh_incomplete", "message": "\(failed.count) failed, \(unverified.count) unverified"]) { $1 }) }
    return result
}

public func unregisterAppsInDirectory(_ directory: String, force: Bool) throws -> [String: Any] {
    if !force { throw IcliError.forceRequired("unregister every app in \(directory)") }
    let result = try decodeApps(takeCString(icli_apps_unregister_directory_json(directory)))
    let failed = result["failed"] as? [String] ?? []
    let unverified = result["unverified"] as? [String] ?? []
    guard failed.isEmpty, unverified.isEmpty else { throw IcliError.commandFailed(result.merging(["error": "unregister_incomplete", "message": "\(failed.count) failed, \(unverified.count) unverified"]) { $1 }) }
    return result
}

public func appHandlers(_ urlOrScheme: String) throws -> [String: Any] {
    guard let raw = takeCString(icli_app_handlers_json(urlOrScheme)),
          let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw IcliError.failed("handlers lookup failed")
    }
    if let error = obj["error"] as? String {
        throw IcliError.failed(error)
    }
    return obj
}

public func openAppURL(_ url: String, bundleID: String?) throws -> [String: Any] {
    guard icli_open_url_in_app(url, bundleID) else {
        throw IcliError.failed("open failed: \(url)")
    }
    var payload: [String: Any] = ["url": url]
    if let bundleID { payload["bundle_id"] = bundleID }
    return payload
}

public func appURLSchemes() throws -> [String: Any] {
    let apps = try listApps()["apps"] as? [[String: Any]] ?? []
    var schemes: [String: [String]] = [:]
    for app in apps {
        guard let bid = app["bundle_id"] as? String, let bundle = app["bundle_path"] as? String else { continue }
        let plist = bundle + "/Info.plist"
        guard let info = NSDictionary(contentsOfFile: plist) else { continue }
        let types = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let names = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        if !names.isEmpty { schemes[bid] = names }
    }
    return ["schemes": schemes]
}

public func appBinaryInfo(_ bundleID: String) throws -> [String: Any] {
    let info = try appInfo(bundleID)
    let executable = info["executable"] as? String ?? ""
    var result = try machOInfo(at: executable)
    result["bundle_id"] = bundleID
    result["executable"] = executable
    return result
}

public func appDataDir(_ bundleID: String) throws -> [String: Any] {
    let info = try appInfo(bundleID)
    return ["bundle_id": bundleID, "data_path": info["data_path"] ?? ""]
}

private func scanApplicationDirs() -> [[String: Any]] {
    let root = JailbreakRoot.current
    let dirs = [
        "/Applications",
        "/var/containers/Bundle/Application",
        root.jbrootPath("/Applications"),
        "/cores/binpack/Applications",
        "/private/var/containers/Bundle/tweaksupport/Applications",
    ]
    var extra: [[String: Any]] = []
    for dir in dirs {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
        for name in names where name.hasSuffix(".app") {
            let path = (dir as NSString).appendingPathComponent(name)
            let plist = path + "/Info.plist"
            let info = NSDictionary(contentsOfFile: plist)
            extra.append([
                "name": info?["CFBundleDisplayName"] ?? info?["CFBundleName"] ?? name,
                "bundle_id": info?["CFBundleIdentifier"] ?? "",
                "bundle_path": path,
            ])
        }
    }
    return extra
}

private func uniqued(_ apps: [[String: Any]], key: String) -> [[String: Any]] {
    var seen = Set<String>()
    return apps.filter { app in
        let id = app[key] as? String ?? UUID().uuidString
        if seen.contains(id) { return false }
        seen.insert(id)
        return true
    }
}

private func decodeJSONArray(_ raw: String) -> [[String: Any]] {
    guard let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return obj
}
