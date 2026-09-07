import IcliPrivate
import Foundation
import Darwin
import Security

public func listProcesses(filter: String?) throws -> [String: Any] {
    guard let raw = takeCString(icli_processes_json()),
          let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
    else { throw IcliError.failed("could not read process list") }
    if let error = result["error"] as? String { throw IcliError.failed(error) }
    var rows = result["processes"] as? [[String: Any]] ?? []
    if let filter {
        rows = rows.filter { ($0["name"] as? String ?? "").localizedCaseInsensitiveContains(filter) }
    }
    return ["processes": rows, "count": rows.count]
}

public func listRepos() throws -> [String: Any] {
    let dir = JailbreakRoot.current.jbrootPath("/etc/apt/sources.list.d")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    var entries: [String] = []
    for file in files {
        let path = (dir as NSString).appendingPathComponent(file)
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            entries.append(text)
        }
    }
    return ["repos": entries]
}

public func addRepo(_ url: String) throws -> [String: Any] {
    guard let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme), parsed.host != nil,
          !url.contains(where: { $0.isWhitespace }), parsed.user == nil, parsed.password == nil else {
        throw IcliError.failed("Provide an HTTP or HTTPS repository URL without credentials or whitespace.")
    }
    let dir = JailbreakRoot.current.jbrootPath("/etc/apt/sources.list.d")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let file = (dir as NSString).appendingPathComponent("icli.list")
    let line = "deb \(url) ./"
    let existing = FileManager.default.fileExists(atPath: file) ? try String(contentsOfFile: file, encoding: .utf8) : ""
    if existing.split(separator: "\n").contains(Substring(line)) {
        return ["added": false, "url": url]
    }
    let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
    try (existing + separator + line + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    return ["added": true, "url": url]
}

public func listTweaks() throws -> [String: Any] {
    let root = JailbreakRoot.current
    let dirs = [
        root.jbrootPath("/Library/MobileSubstrate/DynamicLibraries"),
        root.jbrootPath("/usr/lib/TweakInject"),
        "/usr/lib/TweakInject",
    ]
    var dylibs: [String] = []
    for dir in dirs {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        dylibs.append(contentsOf: names.filter { $0.hasSuffix(".dylib") }.map { (dir as NSString).appendingPathComponent($0) })
    }
    return ["tweaks": dylibs]
}

public func crashLogs(bundleID: String?) throws -> [String: Any] {
    let dirs = [
        "/var/mobile/Library/Logs/CrashReporter",
        "/var/mobile/Library/Logs/DiagnosticReports",
        "/var/mobile/Library/Logs/CrashReporter/Retired",
    ]
    var files: [(String, Date)] = []
    let appName = bundleID.flatMap { try? appInfo($0)["executable"] as? String }.map { ($0 as NSString).lastPathComponent }
    for dir in dirs {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for name in names {
            guard name.hasSuffix(".ips") || name.hasSuffix(".crash") else { continue }
            if let bundleID, !name.localizedCaseInsensitiveContains(bundleID), appName.map({ name.localizedCaseInsensitiveContains($0) }) != true { continue }
            let path = (dir as NSString).appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            files.append((path, attributes?[.modificationDate] as? Date ?? .distantPast))
        }
    }
    return ["crashes": files.sorted { $0.1 > $1.1 }.map(\.0), "count": files.count]
}

public func readCrashLog(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    guard let text = String(data: data, encoding: .utf8) else { throw IcliError.failed("crash report is not UTF-8 text") }
    return ["path": path, "content": text, "size": data.count, "encoding": "utf8", "truncated": false]
}

public func captureSyslog(seconds: TimeInterval, process: String? = nil, level: String = "all", maxLines: Int = 500) throws -> [String: Any] {
    guard seconds.isFinite, (0.1...60).contains(seconds), ["all", "error", "fault"].contains(level), (1...5000).contains(maxLines) else {
        throw IcliError.failed("seconds must be 0.1–60, level all/error/fault, and max-lines 1–5000")
    }
    guard let raw = takeCString(icli_syslog_json(seconds, process, level, Int32(maxLines))),
          let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
        throw IcliError.failed("invalid unified log response")
    }
    if let error = result["error"] as? String { throw IcliError.failed(error) }
    return result
}

public func dumpKeychain() throws -> [String: Any] {
    try listKeychain(className: nil, service: nil, account: nil, server: nil, group: nil, includeData: false)
}

public func listKeychain(
    className: String?,
    service: String?,
    account: String?,
    server: String?,
    group: String?,
    includeData: Bool
) throws -> [String: Any] {
    var items: [[String: Any]] = []
    for entry in keychainClasses(className) {
        var query = keychainQuery(entry.secClass, service: service, account: account, server: server, group: group)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        let withData = includeData && entry.passwords
        if withData {
            query[kSecReturnData as String] = true
        }
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess && withData {
            query.removeValue(forKey: kSecReturnData as String)
            result = nil
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecInteractionNotAllowed {
            throw IcliError.failed("keychain unavailable while device is locked")
        }
        if status == errSecItemNotFound {
            continue
        }
        if status != errSecSuccess {
            throw IcliError.failed("keychain query status \(status)")
        }
        let rows = result as? [[String: Any]] ?? []
        items.append(contentsOf: rows.map { encodeKeychainItem($0, className: entry.name, includeData: withData) })
    }
    return ["items": items, "count": items.count]
}

public func getKeychain(className: String, service: String?, account: String?, server: String?, group: String?) throws -> [String: Any] {
    let listed = try listKeychain(
        className: className,
        service: service,
        account: account,
        server: server,
        group: group,
        includeData: true
    )
    let items = listed["items"] as? [[String: Any]] ?? []
    if items.isEmpty {
        throw IcliError.failed("keychain item not found")
    }
    return listed
}

public func addKeychain(
    className: String,
    service: String?,
    account: String,
    server: String?,
    label: String?,
    group: String?,
    data: String
) throws -> [String: Any] {
    var item: [String: Any] = [
        kSecClass as String: try secClass(named: className),
        kSecAttrAccount as String: account,
        kSecValueData as String: Data(data.utf8),
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecReturnAttributes as String: true,
        kSecReturnPersistentRef as String: true,
    ]
    if let service, !service.isEmpty { item[kSecAttrService as String] = service }
    if let server, !server.isEmpty { item[kSecAttrServer as String] = server }
    if let label, !label.isEmpty { item[kSecAttrLabel as String] = label }
    if let group, !group.isEmpty { item[kSecAttrAccessGroup as String] = group }
    var result: CFTypeRef?
    try throwIfKeychain(SecItemAdd(item as CFDictionary, &result), action: "add")
    guard let result else {
        throw IcliError.failed("keychain add did not persist")
    }
    if let dict = result as? [String: Any] {
        var encoded = encodeKeychainItem(dict, className: className, includeData: true)
        encoded["ok"] = true
        encoded["data"] = data
        return encoded
    }
    return [
        "ok": true,
        "class": className,
        "account": account,
        "service": service ?? "",
        "data": data,
    ]
}

public func updateKeychain(
    className: String,
    service: String?,
    account: String,
    server: String?,
    group: String?,
    data: String
) throws -> [String: Any] {
    let query = keychainQuery(try secClass(named: className), service: service, account: account, server: server, group: group)
    try throwIfKeychain(
        SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(data.utf8)] as CFDictionary),
        action: "update"
    )
    return try getKeychain(className: className, service: service, account: account, server: server, group: group)
}

public func deleteKeychain(className: String, service: String?, account: String?, server: String?, group: String?) throws -> [String: Any] {
    let query = keychainQuery(try secClass(named: className), service: service, account: account, server: server, group: group)
    let status = SecItemDelete(query as CFDictionary)
    if status == errSecItemNotFound {
        return ["deleted": false, "message": "keychain item not found"]
    }
    try throwIfKeychain(status, action: "delete")
    return ["deleted": true]
}

private struct KeychainClass {
    let name: String
    let secClass: CFString
    let passwords: Bool
}

private func keychainClasses(_ className: String?) -> [KeychainClass] {
    let all = [
        KeychainClass(name: "generic_password", secClass: kSecClassGenericPassword, passwords: true),
        KeychainClass(name: "internet_password", secClass: kSecClassInternetPassword, passwords: true),
        KeychainClass(name: "certificate", secClass: kSecClassCertificate, passwords: false),
        KeychainClass(name: "key", secClass: kSecClassKey, passwords: false),
        KeychainClass(name: "identity", secClass: kSecClassIdentity, passwords: false),
    ]
    guard let className else { return all }
    guard let wanted = try? secClass(named: className) else { return [] }
    return all.filter { CFEqual($0.secClass, wanted) }
}

private func secClass(named name: String) throws -> CFString {
    switch name {
    case "generic_password", "generic": return kSecClassGenericPassword
    case "internet_password", "internet": return kSecClassInternetPassword
    case "certificate": return kSecClassCertificate
    case "key": return kSecClassKey
    case "identity": return kSecClassIdentity
    default: throw IcliError.failed("unknown keychain class: \(name)")
    }
}

private func keychainQuery(_ secClass: CFString, service: String?, account: String?, server: String?, group: String?) -> [String: Any] {
    var query: [String: Any] = [kSecClass as String: secClass]
    if let service, !service.isEmpty { query[kSecAttrService as String] = service }
    if let account, !account.isEmpty { query[kSecAttrAccount as String] = account }
    if let server, !server.isEmpty { query[kSecAttrServer as String] = server }
    if let group, !group.isEmpty { query[kSecAttrAccessGroup as String] = group }
    return query
}

private func encodeKeychainItem(_ item: [String: Any], className: String, includeData: Bool) -> [String: Any] {
    var copy: [String: Any] = ["class": className]
    if let acct = item[kSecAttrAccount as String] { copy["account"] = "\(acct)" }
    if let svc = item[kSecAttrService as String] { copy["service"] = "\(svc)" }
    if let label = item[kSecAttrLabel as String] { copy["label"] = "\(label)" }
    if let server = item[kSecAttrServer as String] { copy["server"] = "\(server)" }
    if let group = item[kSecAttrAccessGroup as String] { copy["group"] = "\(group)" }
    if includeData, let data = item[kSecValueData as String] as? Data {
        copy["data"] = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
    }
    return copy
}

private func throwIfKeychain(_ status: OSStatus, action: String) throws {
    if status == errSecSuccess { return }
    if status == errSecItemNotFound { throw IcliError.failed("keychain item not found") }
    if status == errSecDuplicateItem { throw IcliError.failed("keychain item already exists") }
    if status == errSecInteractionNotAllowed { throw IcliError.failed("keychain unavailable while device is locked") }
    throw IcliError.failed("keychain \(action) status \(status)")
}

public func sslKillswitchStatus() -> [String: Any] {
    let root = JailbreakRoot.current
    let candidates = [
        root.jbrootPath("/Library/MobileSubstrate/DynamicLibraries/SSLKillSwitch2.dylib"),
        root.jbrootPath("/usr/lib/TweakInject/SSLKillSwitch2.dylib"),
    ]
    return ["present": candidates.contains(where: FileManager.default.fileExists)]
}

/// Captures from the interface's BPF device (root) into a pcap file and
/// returns a summary of the first packets. Filters accept
/// `[tcp|udp|icmp] [src|dst] port N [src|dst] host A`, joined with `and`.
public func capturePackets(seconds: TimeInterval, interface: String = "en0", filter: String? = nil, output: String? = nil) throws -> [String: Any] {
    guard seconds.isFinite, (1...60).contains(seconds) else {
        throw IcliError.failed("Capture duration must be between 1 and 60 seconds.")
    }
    guard !interface.isEmpty, interface.utf8.count <= 15,
          interface.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
        throw IcliError.failed("Provide a network interface name.")
    }
    let out = output ?? JailbreakRoot.current.scratchDirectory() + "/icli-\(UUID().uuidString).pcap"
    guard let raw = takeCString(icli_capture_packets_json(interface, filter, seconds, out)),
          let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw IcliError.failed("invalid capture response") }
    if let error = result["error"] as? String {
        try? FileManager.default.removeItem(atPath: out)
        throw IcliError.failed(error)
    }
    var payload = result
    payload["seconds"] = seconds
    payload["file_bytes"] = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0
    return payload
}
