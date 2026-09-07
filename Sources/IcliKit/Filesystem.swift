import Foundation

private let defaultReadCap = 512 * 1024

public func listDirectory(_ path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
    ])
    let entries: [[String: Any]] = items.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { item in
        let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey, .contentModificationDateKey])
        return [
            "name": item.lastPathComponent,
            "path": item.path,
            "is_directory": values?.isDirectory ?? false,
            "size": values?.fileSize ?? 0,
            "is_symlink": values?.isSymbolicLink ?? false,
            "modified": values?.contentModificationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
        ]
    }
    return ["path": path, "entries": entries]
}

public func readFile(_ path: String, binary: Bool, limit: Int?) throws -> [String: Any] {
    let cap = limit ?? defaultReadCap
    guard (0...64 * 1024 * 1024).contains(cap) else { throw IcliError.failed("limit must be 0–67108864 bytes") }
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    try handle.seek(toOffset: 0)
    let data = try handle.read(upToCount: cap + 1) ?? Data()
    let truncated = data.count > cap
    let slice = truncated ? data.prefix(cap) : data
    if binary || !isLikelyText(slice) {
        return [
            "path": path,
            "encoding": "base64",
            "truncated": truncated,
            "size": size,
            "content": Data(slice).base64EncodedString(),
        ]
    }
    return [
        "path": path,
        "encoding": "utf8",
        "truncated": truncated,
        "size": size,
        "content": String(decoding: slice, as: UTF8.self),
    ]
}

public func writeFile(_ path: String, content: String, encoding: String) throws -> [String: Any] {
    let data: Data
    if encoding == "base64" {
        guard let decoded = Data(base64Encoded: content) else {
            throw IcliError.failed("invalid base64")
        }
        data = decoded
    } else if encoding == "utf8" {
        data = Data(content.utf8)
    } else {
        throw IcliError.failed("encoding must be utf8 or base64")
    }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    return ["path": path, "bytes": data.count]
}

// Directory, symlink, permission and ownership maintenance, so callers need
// no coreutils. Every mutation reports what changed.

public func makeDirectory(_ path: String, mode: String?) throws -> [String: Any] {
    let existed = FileManager.default.fileExists(atPath: path)
    var attributes: [FileAttributeKey: Any] = [:]
    if let mode { attributes[.posixPermissions] = try parseMode(mode) }
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: attributes)
    if existed, let mode { try FileManager.default.setAttributes([.posixPermissions: try parseMode(mode)], ofItemAtPath: path) }
    return ["path": path, "created": !existed]
}

public func removePath(_ path: String, recursive: Bool, force: Bool) throws -> [String: Any] {
    guard force else { throw IcliError.forceRequired("remove \(path)") }
    let standardized = (path as NSString).standardizingPath
    guard standardized.count > 1, !["/var", "/var/jb", "/private/var", JailbreakRoot.current.jbroot].contains(standardized) else { throw IcliError.failed("refusing to remove \(standardized)") }
    var info = stat()
    guard lstat(path, &info) == 0 else { return ["path": path, "removed": false, "message": "path does not exist"] }
    let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
    if isDirectory && !recursive {
        guard rmdir(path) == 0 else { throw IcliError.failed("directory not empty or not removable; pass --recursive: \(String(cString: strerror(errno)))") }
        return ["path": path, "removed": true, "type": "directory"]
    }
    try FileManager.default.removeItem(atPath: path)
    return ["path": path, "removed": true, "type": isDirectory ? "directory" : "file"]
}

public func createSymlink(target: String, link: String, replace: Bool) throws -> [String: Any] {
    var info = stat()
    if lstat(link, &info) == 0 {
        guard replace, (info.st_mode & S_IFMT) == S_IFLNK else { throw IcliError.failed("link path exists; pass --replace to replace an existing symlink: \(link)") }
        try FileManager.default.removeItem(atPath: link)
    }
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
    return ["link": link, "target": target, "resolved": (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) ?? ""]
}

public func changeMode(_ path: String, mode: String) throws -> [String: Any] {
    let value = try parseMode(mode)
    guard chmod(path, mode_t(value)) == 0 else { throw IcliError.failed("chmod \(path): \(String(cString: strerror(errno)))") }
    return ["path": path, "mode": String(value, radix: 8)]
}

/// Owner as `uid:gid` numbers or names known to the system directory.
public func changeOwner(_ path: String, owner: String) throws -> [String: Any] {
    let parts = owner.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2 else { throw IcliError.failed("owner must be uid:gid") }
    func resolve(_ text: String, group: Bool) throws -> UInt32 {
        if let number = UInt32(text) { return number }
        if group, let entry = getgrnam(text) { return entry.pointee.gr_gid }
        if !group, let entry = getpwnam(text) { return entry.pointee.pw_uid }
        throw IcliError.failed("unknown \(group ? "group" : "user"): \(text)")
    }
    let uid = try resolve(parts[0], group: false), gid = try resolve(parts[1], group: true)
    guard lchown(path, uid, gid) == 0 else { throw IcliError.failed("chown \(path): \(String(cString: strerror(errno)))") }
    return ["path": path, "uid": uid, "gid": gid]
}

public func copyPath(_ source: String, to destination: String) throws -> [String: Any] {
    if FileManager.default.fileExists(atPath: destination) { throw IcliError.failed("destination exists: \(destination)") }
    try FileManager.default.copyItem(atPath: source, toPath: destination)
    return ["source": source, "destination": destination]
}

public func movePath(_ source: String, to destination: String) throws -> [String: Any] {
    if FileManager.default.fileExists(atPath: destination) { throw IcliError.failed("destination exists: \(destination)") }
    try FileManager.default.moveItem(atPath: source, toPath: destination)
    return ["source": source, "destination": destination]
}

/// Sets (or with a nil value removes) one top-level key, keeping the file's
/// binary or XML format. The value is JSON.
public func setPlistValue(_ path: String, key: String, json: String?) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    var format = PropertyListSerialization.PropertyListFormat.xml
    guard var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else { throw IcliError.failed("plist root is not a dictionary") }
    let previous = plist[key]
    if let json {
        guard let value = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) else { throw IcliError.failed("value must be JSON") }
        plist[key] = value
    } else {
        plist.removeValue(forKey: key)
    }
    let output = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
    var info = stat()
    let existed = stat(path, &info) == 0
    try output.write(to: URL(fileURLWithPath: path), options: .atomic)
    if existed { chmod(path, info.st_mode & 0o7777); if geteuid() == 0 { chown(path, info.st_uid, info.st_gid) } }
    return ["path": path, "key": key, "value": plist[key].map(jsonSafe) ?? NSNull(), "previous": previous.map(jsonSafe) ?? NSNull(), "format": format == .binary ? "binary" : "xml"]
}

private func parseMode(_ text: String) throws -> Int {
    guard let value = Int(text, radix: 8), (0...0o7777).contains(value) else { throw IcliError.failed("mode must be octal, e.g. 755") }
    return value
}

public func findFiles(root: String, pattern: String) throws -> [String: Any] {
    let enumerator = FileManager.default.enumerator(atPath: root)
    var matches: [String] = []
    let pred = pattern.lowercased()
    while let rel = enumerator?.nextObject() as? String {
        if rel.lowercased().contains(pred) {
            matches.append((root as NSString).appendingPathComponent(rel))
        }
        if matches.count >= 500 { break }
    }
    return ["root": root, "pattern": pattern, "matches": matches]
}

public func readPlist(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return ["path": path, "plist": jsonSafe(plist)]
}

private func isLikelyText(_ data: Data) -> Bool {
    if data.isEmpty { return true }
    if data.contains(0) { return false }
    return String(data: data, encoding: .utf8) != nil
}

private func jsonSafe(_ value: Any) -> Any {
    switch value {
    case let d as Data:
        return d.base64EncodedString()
    case let d as Date:
        return ISO8601DateFormatter().string(from: d)
    case let dict as [String: Any]:
        return dict.mapValues { jsonSafe($0) }
    case let arr as [Any]:
        return arr.map { jsonSafe($0) }
    default:
        return value
    }
}
