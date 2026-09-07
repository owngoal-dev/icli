import IcliPrivate
import Foundation
import Darwin

private func decodeSystem(_ raw: String?) throws -> [String: Any] {
    guard let raw, let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw IcliError.failed("invalid response") }
    if let error = result["error"] as? String { throw IcliError.failed(error) }
    return result
}

/// Requests a userspace or full reboot. Success means the kernel accepted
/// the request; the caller proves completion by reconnecting.
public func requestReboot(userspace: Bool, force: Bool) throws -> [String: Any] {
    guard force else { throw IcliError.forceRequired(userspace ? "restart userspace" : "reboot the device") }
    guard geteuid() == 0 else { throw IcliError.failed("reboot requires root") }
    let status = icli_reboot(userspace)
    guard status == 0 else { throw IcliError.failed("reboot request rejected: \(String(cString: strerror(status)))") }
    return ["accepted": true, "kind": userspace ? "userspace" : "full", "completion": "verify by reconnecting"]
}

public func appNetworkPolicy(_ bundleID: String, repair: Bool) throws -> [String: Any] {
    guard bundleID.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{1,200}$", options: .regularExpression) != nil else { throw IcliError.failed("invalid app bundle identifier") }
    return try decodeSystem(takeCString(icli_app_network_policy_json(bundleID, repair)))
}

/// SpringBoard's "show non-default system apps" preference (read or set).
public func systemAppsVisibility(set visible: Bool?) throws -> [String: Any] {
    try decodeSystem(takeCString(icli_system_apps_visible_json(visible.map { $0 ? 1 : 0 } ?? -1)))
}

public func renderBootLogo(mark: String, output: String, dark: Bool, width: Int, height: Int, markPoints: Double) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: mark) else { throw IcliError.failed("mark image not found: \(mark)") }
    guard width >= 0, height >= 0, markPoints >= 0 else { throw IcliError.failed("sizes must not be negative") }
    return try decodeSystem(takeCString(icli_bootlogo_render_json(mark, output, dark, Int32(width), Int32(height), markPoints)))
}

/// Replaces the bootstrap account's password hash in master.passwd and the
/// spwd.db lookup database. The password itself never appears in argv.
public func setAccountPassword(user: String, password: String) throws -> [String: Any] {
    guard user.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else { throw IcliError.failed("invalid account name") }
    guard !password.isEmpty, password.utf8.count <= 256, !password.contains("\n"), !password.contains(":") else { throw IcliError.failed("password must be 1-256 bytes without newlines or colons") }
    guard geteuid() == 0 else { throw IcliError.failed("changing an account password requires root") }
    return try decodeSystem(takeCString(icli_account_set_password_json(JailbreakRoot.current.jbrootPath("/etc"), user, password)))
}

/// Structured runtime capabilities: layout, markers, platform services and
/// which bootstrap tools remain in the path of any icli command.
public func environmentReport() throws -> [String: Any] {
    icli_private_init()
    let root = JailbreakRoot.current
    let manager = FileManager.default
    func present(_ path: String) -> Bool { manager.fileExists(atPath: root.jbrootPath(path)) }
    let platformBinary = icli_platform_binary()
    let systemHook = dlopen("systemhook.dylib", RTLD_NOLOAD)
    var roothideRuntime = false
    if let systemHook {
        if let symbol = dlsym(systemHook, "get_jbroot") {
            typealias GetRoot = @convention(c) () -> UnsafePointer<CChar>?
            roothideRuntime = unsafeBitCast(symbol, to: GetRoot.self)().map { String(cString: $0) }.map { !$0.isEmpty } ?? false
        }
        dlclose(systemHook)
    }
    let markers = [".installed_dopamine", ".installed_relaxin", ".installed_palera1n", ".procursus_strapped", "basebin/.version", "basebin/.safe_mode"].filter(present)
    let basebinVersion = (try? String(contentsOfFile: root.jbrootPath("/basebin/.version"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    let tools = ["dpkg", "apt-get", "tcpdump", "sudo", "launchctl", "uicache", "sbreload", "jbctl"].reduce(into: [String: Bool]()) { $0[$1] = manager.isExecutableFile(atPath: root.binary($1)) }
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return [
        "layout": root.layout.rawValue,
        "jbroot": root.jbroot,
        "jbroot_source": root.source,
        "rootfs_prefix": root.rootfsPath("/"),
        "ios_version": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
        "euid": Int(geteuid()),
        "platform_binary": platformBinary,
        "roothide_runtime_active": roothideRuntime,
        "markers": markers,
        "basebin_version": basebinVersion ?? "",
        "bootstrap_tools_present": tools,
        "spawns_processes": false,
        "external_tools_used": [String: String](),
        "native": ["app registration and refresh", "launchd services", "respring", "reboot", "account password", "deb read/extract/install/remove with dpkg database", "package status and version comparison", "app network policy", "system app visibility", "boot logo", "packet capture", "filesystem maintenance"],
        "maintainer_scripts": "never executed; reported per transaction",
        "executable": Bundle.main.executablePath ?? "",
    ]
}

/// Compares the installed BaseBin version marker with `basebin/.version`
/// inside a bundled archive. Either side may be absent.
public func compareBaseBin(bundled archive: String?) throws -> [String: Any] {
    let installedPath = JailbreakRoot.current.jbrootPath("/basebin/.version")
    let installed = (try? String(contentsOfFile: installedPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    var payload: [String: Any] = ["installed_path": installedPath, "installed": installed ?? "", "installed_present": installed != nil]
    if let archive {
        guard FileManager.default.fileExists(atPath: archive) else { throw IcliError.failed("archive not found: \(archive)") }
        let bundled = takeCString(icli_tar_entry_text(archive, "basebin/.version"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        payload["bundled"] = bundled ?? ""
        payload["bundled_present"] = bundled != nil
        payload["matches"] = installed != nil && bundled != nil && installed == bundled
        payload["update_available"] = bundled != nil && installed != bundled
    }
    return payload
}
