import Darwin
import Foundation
import IcliPrivate

/// Exercises actual on-device APIs. Passing this suite only covers the listed
/// checks; the separate acceptance runner covers interaction and system changes.
public func runSelfTests(expectedLayout: String? = nil, registrationFixture: String? = nil) throws -> [String: Any] {
    let environment = try environmentReport()
    if let expectedLayout, expectedLayout != JailbreakRoot.current.layout.rawValue {
        throw IcliError.failed("Expected \(expectedLayout), detected \(JailbreakRoot.current.layout.rawValue); no tests were run.")
    }
    var results: [[String: Any]] = []
    func check(_ name: String, _ body: () throws -> [String: Any]) {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let details = try body()
            results.append(["name": name, "result": "passed", "details": details, "seconds": ProcessInfo.processInfo.systemUptime - start])
        } catch {
            let message = (error as? IcliError)?.message ?? error.localizedDescription
            var result: [String: Any] = ["name": name, "result": "failed", "message": message, "seconds": ProcessInfo.processInfo.systemUptime - start]
            if let error = error as? IcliError { result["details"] = error.payload }
            results.append(result)
        }
    }

    check("device") {
        let info = try collectDeviceSnapshot()
        try requireSelfTest(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 16, "Requires iOS 16 or later.")
        try requireSelfTest((info["memory_bytes"] as? UInt64 ?? 0) > 0, "Device memory was not reported.")
        return info
    }
    check("bootstrap") {
        let path = JailbreakRoot.current.jbrootPath("/Applications")
        var directory: ObjCBool = false
        try requireSelfTest(FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue, "Bootstrap Applications directory is missing: \(path)")
        _ = try FileManager.default.contentsOfDirectory(atPath: path)
        return ["applications": path, "layout": JailbreakRoot.current.layout.rawValue]
    }
    check("processes") {
        let processes = try listProcesses(filter: nil)["processes"] as? [[String: Any]] ?? []
        try requireSelfTest(processes.contains { $0["pid"] as? Int == Int(getpid()) }, "Process list does not contain this process.")
        return ["count": processes.count, "self_pid": Int(getpid())]
    }
    check("launch_services") {
        let apps = try selfTestRegisteredApps()
        try requireSelfTest(!apps.isEmpty, "LaunchServices returned no applications.")
        return ["count": apps.count]
    }
    check("filesystem") {
        try withSelfTestDirectory { directory in
            let path = directory + "/original.txt"
            let content = "icli self-test 中文 🌱\n"
            _ = try writeFile(path, content: content, encoding: "utf8")
            try requireSelfTest(try readFile(path, binary: false, limit: nil)["content"] as? String == content, "File content did not round-trip.")
            _ = try copyPath(path, to: directory + "/copy.txt")
            _ = try movePath(directory + "/copy.txt", to: directory + "/moved.txt")
            try requireSelfTest(try readFile(directory + "/moved.txt", binary: false, limit: nil)["content"] as? String == content, "Copied and moved content differs.")
            try requireSelfTest(try readFile(path, binary: false, limit: 4)["truncated"] as? Bool == true, "Read limit was not enforced.")
            return ["write_read_copy_move": true, "truncation": true]
        }
    }
    check("debian_versions") {
        for (left, right, order) in [("1.0~rc1", "1.0", -1), ("1:1.0", "2.0", 1), ("1.0", "1.0", 0)] {
            let result = try compareDebianVersions(left, right)
            try requireSelfTest(result["comparison"] as? Int == order, "Unexpected Debian version ordering: \(left), \(right)")
        }
        return ["comparisons": 3]
    }
    check("screenshot") {
        try withSelfTestDirectory { directory in
            var capture = try takeScreenshot(path: directory + "/screen.jpg")
            try requireSelfTest((capture["width"] as? Int ?? 0) > 0 && (capture["height"] as? Int ?? 0) > 0, "Screenshot dimensions are invalid.")
            capture.removeValue(forKey: "path")
            return capture
        }
    }
    check("accessibility") {
        try requireSelfTestUnlocked()
        // A newly launched app can still be registering its AX endpoint.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var attempts = 0
        while true {
            attempts += 1
            do {
                let tree = try uiElements()
                try requireSelfTest((tree["count"] as? Int ?? 0) > 0, "No visible accessibility elements; open an accessible app and retry.")
                return ["count": tree["count"] ?? 0, "attempts": attempts]
            } catch {
                if ProcessInfo.processInfo.systemUptime >= deadline { throw error }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }
    check("ocr") {
        try requireSelfTestUnlocked()
        let result = try recognizeScreen(languages: ["en-US"], minConfidence: 0.3)
        return ["count": result["count"] ?? 0, "engine": result["engine"] ?? "", "note": "An empty screen may contain no recognized text."]
    }
    check("keychain") { try selfTestKeychain() }
    if let registrationFixture {
        check("app_registration_refresh") { try selfTestRegistration(registrationFixture) }
    } else {
        results.append(["name": "app_registration_refresh", "result": "skipped", "message": "Supply --registration-fixture with the signed SelfTestFixture.app."])
    }
    let failed = results.filter { $0["result"] as? String == "failed" }.count
    let skipped = results.filter { $0["result"] as? String == "skipped" }.count
    return ["status": failed == 0 ? 0 : 1, "passed": results.count - failed - skipped, "failed": failed, "skipped": skipped,
            "complete": failed == 0 && skipped == 0, "environment": environment, "tests": results,
            "not_tested": ["touch and keyboard interaction", "clipboard and device setting changes", "package installation/removal", "launchd service changes", "network capture", "respring and reboot", "RootHide-specific container and plugin behavior"]]
}

private func requireSelfTest(_ condition: Bool, _ message: String) throws {
    if !condition { throw IcliError.failed(message) }
}

private func requireSelfTestUnlocked() throws {
    let state = screenInfo()
    if state["locked"] as? Bool == true || state["screen_off"] as? Bool == true { throw IcliError.locked }
}

private func selfTestRegisteredApps() throws -> [[String: Any]] {
    guard let raw = takeCString(icli_apps_json()), let apps = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else {
        throw IcliError.failed("Invalid LaunchServices application list.")
    }
    return apps
}

private func withSelfTestDirectory(_ body: (String) throws -> [String: Any]) throws -> [String: Any] {
    let directory = JailbreakRoot.current.scratchDirectory() + "/icli-selftest-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
    let result: Result<[String: Any], Error>
    do { result = .success(try body(directory)) } catch { result = .failure(error) }
    do { try FileManager.default.removeItem(atPath: directory) } catch {
        throw IcliError.failed("Self-test cleanup failed at \(directory): \(error.localizedDescription); test result: \(result)")
    }
    return try result.get()
}

private func selfTestKeychain() throws -> [String: Any] {
    let account = UUID().uuidString
    let service = "icli.selftest"
    let group = "icli.test"
    var failure: Error?
    do {
        _ = try addKeychain(className: "generic", service: service, account: account, server: nil, label: nil, group: group, data: account)
        let rows = try getKeychain(className: "generic", service: service, account: account, server: nil, group: group)["items"] as? [[String: Any]] ?? []
        try requireSelfTest(rows.count == 1 && rows.first?["data"] as? String == account, "Keychain content did not round-trip.")
    } catch { failure = error }
    _ = try deleteKeychain(className: "generic", service: service, account: account, server: nil, group: group)
    let remaining = try listKeychain(className: "generic", service: service, account: account, server: nil, group: group, includeData: false)
    try requireSelfTest(remaining["count"] as? Int == 0, "Self-test Keychain item was not removed: \(account)")
    if let failure { throw failure }
    return ["write_read_delete": true, "group": group]
}

private func selfTestRegistration(_ fixture: String) throws -> [String: Any] {
    let bundleID = "dev.owngoal.icli.SelfTestFixture"
    let info = NSDictionary(contentsOfFile: fixture + "/Info.plist")
    try requireSelfTest(info?["CFBundleIdentifier"] as? String == bundleID, "Use the dedicated dev.owngoal.icli.SelfTestFixture bundle.")
    try requireSelfTest(try !selfTestRegisteredApps().contains { $0["bundle_id"] as? String == bundleID }, "SelfTestFixture is already registered; unregister it before testing.")
    return try withSelfTestDirectory { directory in
        let first = directory + "/first"
        let second = directory + "/second"
        let original = first + "/SelfTestFixture.app"
        let moved = second + "/SelfTestFixture.app"
        let alias = directory + "/linked"
        try FileManager.default.createDirectory(atPath: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: second)
        try FileManager.default.copyItem(atPath: fixture, toPath: original)
        var failure: Error?
        do {
            let registered = try refreshApps(directory: first)
            try requireSelfTest((registered["registered"] as? [String])?.count == 1, "New fixture was not registered.")
            let unchanged = try refreshApps(directory: first)
            try requireSelfTest((unchanged["registered"] as? [String])?.isEmpty == true && (unchanged["unchanged"] as? [String])?.count == 1, "Refresh re-registered an unchanged app.")
            let unregistered = try unregisterApp(original, force: true)
            try requireSelfTest(unregistered["unregistered"] as? Bool == true && FileManager.default.fileExists(atPath: original), "Explicit unregister failed or removed the bundle from disk.")
            try requireSelfTest(try appRegistration(original)["registered"] as? Bool == false, "LaunchServices still lists the explicitly unregistered bundle.")
            try requireSelfTest(try unregisterApp(original, force: true)["unregistered"] as? Bool == false, "Repeated unregister was not a no-op.")
            _ = try refreshApps(directory: first)
            try FileManager.default.moveItem(atPath: original, toPath: moved)
            _ = try refreshApps(directory: second)
            _ = try refreshApps(directory: first)
            try requireSelfTest(try appRegistration(moved)["registered"] as? Bool == true && appRegistration(original)["registered"] as? Bool == false, "Moved app registration was lost or still points at its old path.")
            try FileManager.default.removeItem(atPath: moved)
            try requireSelfTest(try unregisterApp(alias + "/SelfTestFixture.app", force: true)["unregistered"] as? Bool == true, "Could not explicitly unregister a deleted bundle through a symlinked parent.")
            try requireSelfTest(try appRegistration(moved)["registered"] as? Bool == false, "Deleted bundle remains registered after explicit unregister.")
            try FileManager.default.copyItem(atPath: fixture, toPath: moved)
            _ = try refreshApps(directory: second)
            try FileManager.default.removeItem(atPath: moved)
            let removed = try refreshApps(directory: second)
            try requireSelfTest((removed["unregistered"] as? [String])?.count == 1, "Missing app registration was not removed.")
            try requireSelfTest(try !selfTestRegisteredApps().contains { $0["bundle_id"] as? String == bundleID }, "Fixture is still registered after removal.")
        } catch { failure = error }
        // Cleanup also runs after a failed assertion or API call.
        var cleanupErrors: [String] = []
        for path in [original, moved] {
            do { _ = try unregisterApp(path, force: true) } catch {
                cleanupErrors.append("\(path): \((error as? IcliError)?.message ?? error.localizedDescription)")
            }
        }
        try requireSelfTest(cleanupErrors.isEmpty, "Fixture cleanup failed: \(cleanupErrors.joined(separator: "; "))")
        if let failure { throw failure }
        return ["new_registration": true, "unchanged_skipped": true, "unregister_existing": true, "unregister_missing": true,
                "unregister_idempotent": true, "missing_bundle_symlink_resolution": true, "relocation": true, "stale_removal": true, "cleanup": true]
    }
}
