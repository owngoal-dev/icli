import IcliPrivate
import Foundation
import Darwin

// Debian packages handled entirely in-process: reading and unpacking use
// libarchive, and installation keeps dpkg's own database (status, info/*.list,
// info/*.md5sums, maintainer scripts) up to date so dpkg and apt still see a
// consistent state afterwards. Maintainer scripts are never executed; the
// result names the ones that were skipped and reports app bundles that were
// registered natively instead.

private func decodePackage(_ raw: String?) throws -> [String: Any] {
    guard let raw, let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw IcliError.failed("invalid package response") }
    if let error = result["error"] as? String { throw IcliError.failed(error) }
    return result
}

private func validPackageName(_ name: String) throws {
    guard name.range(of: "^[a-z0-9][a-z0-9+.-]+$", options: .regularExpression) != nil else { throw IcliError.failed("invalid package identifier") }
}

/// Control metadata, maintainer scripts and the file list of a .deb, read without dpkg.
public func readDeb(_ path: String) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path) else { throw IcliError.failed("package file not found: \(path)") }
    var result = try decodePackage(takeCString(icli_deb_read_json(path, nil)))
    result.removeValue(forKey: "control_texts")
    return result
}

/// Unpacks control files to `<destination>/DEBIAN` and payload files below `destination`.
public func extractDeb(_ path: String, to destination: String) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path) else { throw IcliError.failed("package file not found: \(path)") }
    let existing = (try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? []
    guard existing.isEmpty else { throw IcliError.failed("destination must be empty or absent: \(destination)") }
    try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    var result = try decodePackage(takeCString(icli_deb_read_json(path, destination)))
    result.removeValue(forKey: "control_texts")
    return result
}

public func compareDebianVersions(_ left: String, _ right: String) throws -> [String: Any] {
    var comparison: Int32 = 0
    guard icli_compare_debian_versions(left, right, &comparison) != 0 else { throw IcliError.failed("invalid Debian version string") }
    return ["left": left, "right": right, "comparison": Int(comparison), "relation": comparison < 0 ? "lt" : comparison > 0 ? "gt" : "eq"]
}

// MARK: dpkg database

/// One stanza of /var/lib/dpkg/status, kept verbatim so untouched packages are rewritten byte for byte.
private struct Stanza {
    var raw: String
    var fields: [String: String]
    var order: [String]

    init(raw: String) {
        self.raw = raw
        var fields: [String: String] = [:]
        var order: [String] = []
        var current: String?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if let current { fields[current, default: ""] += "\n" + line.dropFirst() }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            order.append(key)
            current = key
        }
        self.fields = fields
        self.order = order
    }

    static let preferredOrder = ["Package", "Status", "Priority", "Section", "Installed-Size", "Maintainer", "Architecture", "Multi-Arch", "Source", "Version", "Replaces", "Provides", "Depends", "Pre-Depends", "Recommends", "Suggests", "Breaks", "Conflicts", "Conffiles", "Description"]

    /// dpkg's field order: the well-known fields first, then everything else as it appeared.
    static func compose(_ fields: [String: String], order: [String]) -> Stanza {
        var keys = preferredOrder.filter { fields[$0] != nil }
        keys += order.filter { fields[$0] != nil && !keys.contains($0) }
        keys += fields.keys.sorted().filter { !keys.contains($0) }
        let text = keys.map { key in
            let value = fields[key]!
            let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
            return "\(key): " + lines.enumerated().map { $0 == 0 ? String($1) : " " + $1 }.joined(separator: "\n")
        }.joined(separator: "\n")
        return Stanza(raw: text)
    }

    var package: String? { fields["Package"] }
    var installed: Bool { (fields["Status"] ?? "").hasSuffix(" installed") }
}

private struct DpkgDatabase {
    let directory: String
    var stanzas: [Stanza]
    private var lock: Int32 = -1

    init() throws {
        directory = JailbreakRoot.current.jbrootPath("/var/lib/dpkg")
        let path = directory + "/status"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw IcliError.missing(path) }
        stanzas = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }.map(Stanza.init(raw:))
    }

    func stanza(_ name: String) -> Stanza? { stanzas.first { $0.package == name } }

    /// Real packages plus virtual ones from Provides, each with the version that satisfies constraints.
    func installedVersions() -> [String: [String]] {
        var versions: [String: [String]] = [:]
        for stanza in stanzas where stanza.installed {
            if let name = stanza.package { versions[name, default: []].append(stanza.fields["Version"] ?? "") }
            for provided in (stanza.fields["Provides"] ?? "").split(separator: ",") {
                let (name, constraint) = parseRelation(String(provided))
                versions[name, default: []].append(constraint?.version ?? "")
            }
        }
        return versions
    }

    /// dpkg's own lock: fails fast instead of racing a concurrent dpkg or apt.
    mutating func acquireLock() throws {
        guard geteuid() == 0 else { throw IcliError.failed("package installation requires root") }
        lock = open(directory + "/lock", O_RDWR | O_CREAT, 0o640)
        guard lock >= 0 else { throw IcliError.failed("cannot open dpkg lock: \(String(cString: strerror(errno)))") }
        var request = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(lock, F_SETLK, &request) == 0 else {
            close(lock)
            throw IcliError.failed("dpkg database is locked by another process")
        }
    }

    mutating func releaseLock() {
        if lock >= 0 { close(lock) }
        lock = -1
    }

    /// Writes status through a temp file, keeping dpkg's status-old copy.
    func save() throws {
        let path = directory + "/status"
        let text = stanzas.map(\.raw).joined(separator: "\n\n") + "\n\n"
        let temporary = path + ".icli-\(UUID().uuidString)"
        try text.write(toFile: temporary, atomically: false, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: directory + "/status-old")
        try? FileManager.default.copyItem(atPath: path, toPath: directory + "/status-old")
        guard rename(temporary, path) == 0 else {
            unlink(temporary)
            throw IcliError.failed("could not replace dpkg status: \(String(cString: strerror(errno)))")
        }
    }
}

private struct Constraint {
    let op: String
    let version: String
    func satisfied(by installed: String) -> Bool {
        var comparison: Int32 = 0
        guard icli_compare_debian_versions(installed, version, &comparison) != 0 else { return false }
        switch op {
        case "<<": return comparison < 0
        case "<=": return comparison <= 0
        case "=": return comparison == 0
        case ">=": return comparison >= 0
        case ">>": return comparison > 0
        default: return false
        }
    }
}

private func parseRelation(_ text: String) -> (String, Constraint?) {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")") else {
        return (trimmed.split(separator: ":").first.map(String.init) ?? trimmed, nil)
    }
    let name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
    let parts = trimmed[trimmed.index(after: open)..<close].split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count == 2 else { return (name, nil) }
    return (name, Constraint(op: String(parts[0]), version: String(parts[1])))
}

/// Dependencies of the control stanza that no installed or provided package satisfies.
private func unmetDependencies(_ control: [String: String], database: DpkgDatabase) -> [String] {
    let installed = database.installedVersions()
    var unmet: [String] = []
    for field in ["Pre-Depends", "Depends"] {
        for group in (control[field] ?? "").split(separator: ",") {
            let alternatives = group.split(separator: "|").map { parseRelation(String($0)) }
            let satisfied = alternatives.contains { name, constraint in
                (installed[name] ?? []).contains { version in constraint.map { $0.satisfied(by: version) } ?? true }
            }
            if !satisfied { unmet.append(group.trimmingCharacters(in: .whitespaces)) }
        }
    }
    return unmet
}

private func md5Hex(_ path: String) -> String? {
    guard let raw = takeCString(icli_file_md5(path)) else { return nil }
    return raw
}

private func infoPath(_ database: DpkgDatabase, _ name: String, _ suffix: String) -> String {
    database.directory + "/info/" + name + "." + suffix
}

private func fileList(_ database: DpkgDatabase, _ name: String) -> [String] {
    ((try? String(contentsOfFile: infoPath(database, name, "list"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

private enum Deletion { case removed, skipped, failed }

/// dpkg's removal rule: files and dangling symlinks go, directories go only
/// when empty, and anything that resolves to a directory through a symlink
/// (such as /var on iOS) is left alone.
private func deletePackagePath(_ full: String) -> Deletion {
    var info = stat(), resolved = stat()
    guard lstat(full, &info) == 0 else { return .skipped }
    if (info.st_mode & S_IFMT) == S_IFDIR || (stat(full, &resolved) == 0 && (resolved.st_mode & S_IFMT) == S_IFDIR && (info.st_mode & S_IFMT) == S_IFLNK) {
        return (info.st_mode & S_IFMT) == S_IFDIR && rmdir(full) == 0 ? .removed : .skipped
    }
    return unlink(full) == 0 ? .removed : .failed
}

private var installPrefix: String { JailbreakRoot.current.layout == .roothide ? JailbreakRoot.current.jbroot : "" }

private func acceptedArchitectures() -> Set<String> {
    switch JailbreakRoot.current.layout {
    case .rootless: return ["iphoneos-arm64", "all"]
    case .roothide: return ["iphoneos-arm64e", "all"]
    case .rootful: return ["iphoneos-arm", "all"]
    }
}

/// Registers every .app bundle among installed paths with LaunchServices.
private func registerBundles(_ paths: [String]) -> ([String], [String]) {
    var registered: [String] = [], failed: [String] = []
    for path in paths where path.hasSuffix(".app") {
        let bundle = installPrefix + path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundle + "/Info.plist"), FileManager.default.fileExists(atPath: bundle, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
        if icli_register_app(bundle), (try? appRegistration(bundle))?["registered"] as? Bool == true { registered.append(bundle) } else { failed.append(bundle) }
    }
    return (registered, failed)
}

private func unregisterBundles(_ paths: [String]) -> [String] {
    paths.filter { $0.hasSuffix(".app") }.map { installPrefix + $0 }.filter { (try? appRegistration($0))?["registered"] as? Bool == true && icli_unregister_app($0) }
}

/// Installed packages from the status database.
public func listPackages(filter: String?) throws -> [String: Any] {
    let database = try DpkgDatabase()
    var rows: [[String: Any]] = []
    for stanza in database.stanzas where stanza.installed {
        let row: [String: Any] = ["package": stanza.package ?? "", "name": stanza.fields["Name"] ?? "", "version": stanza.fields["Version"] ?? "", "architecture": stanza.fields["Architecture"] ?? "", "section": stanza.fields["Section"] ?? "", "status": stanza.fields["Status"] ?? ""]
        if let filter, !(row["package"] as! String).localizedCaseInsensitiveContains(filter), !(row["name"] as! String).localizedCaseInsensitiveContains(filter) { continue }
        rows.append(row)
    }
    return ["packages": rows, "count": rows.count]
}

/// One stanza of dpkg's status database, or known=false when the package is unknown.
public func packageStatus(_ name: String) throws -> [String: Any] {
    try validPackageName(name)
    let database = try DpkgDatabase()
    guard let stanza = database.stanza(name) else { return ["package": name, "known": false, "installed": false] }
    return ["package": name, "known": true, "installed": stanza.installed, "status": stanza.fields["Status"] ?? "", "version": stanza.fields["Version"] ?? "", "architecture": stanza.fields["Architecture"] ?? "", "fields": stanza.fields, "files": fileList(database, name)]
}

/// Native install of a local .deb: dependency and architecture checks, files
/// unpacked with dpkg's rename-over semantics, existing conffiles kept, the
/// previous version's stale files removed, dpkg's database updated, and app
/// bundles registered. Maintainer scripts are recorded, not run.
public func installDebFile(_ path: String, ignoreDependencies: Bool = false) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path) else { throw IcliError.failed("package file not found: \(path)") }
    let metadata = try decodePackage(takeCString(icli_deb_read_json(path, nil)))
    let control = metadata["control"] as? [String: String] ?? [:]
    var texts = metadata["control_texts"] as? [String: String] ?? [:]
    guard let name = control["Package"], let version = control["Version"] else { throw IcliError.failed("deb control lacks Package or Version") }
    try validPackageName(name)
    let architecture = control["Architecture"] ?? ""
    guard acceptedArchitectures().contains(architecture) else { throw IcliError.failed("package architecture \(architecture) does not match the \(JailbreakRoot.current.layout.rawValue) bootstrap") }
    var database = try DpkgDatabase()
    try database.acquireLock()
    defer { database.releaseLock() }
    let unmet = unmetDependencies(control, database: database)
    if !unmet.isEmpty && !ignoreDependencies { throw IcliError.commandFailed(["package": name, "error": "unmet_dependencies", "message": "dependencies not installed: " + unmet.joined(separator: ", "), "unmet": unmet]) }
    let previous = database.stanza(name)
    let previousVersion = previous?.installed == true ? previous?.fields["Version"] : nil
    let previousFiles = fileList(database, name)
    let conffiles = (texts["conffiles"] ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let keep = conffiles.filter { FileManager.default.fileExists(atPath: installPrefix + $0) }
    var keepPointers = keep.map { UnsafePointer<CChar>(strdup($0)) }
    defer { keepPointers.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
    let unpacked = try decodePackage(keepPointers.withUnsafeMutableBufferPointer { buffer in takeCString(icli_deb_unpack_json(path, installPrefix, buffer.baseAddress, Int32(buffer.count))) })
    let installed = unpacked["installed"] as? [String] ?? []

    // Files that belonged to the previous version and are gone from this one.
    var removedStale: [String] = []
    for stale in Set(previousFiles).subtracting(installed).sorted(by: { $0.count > $1.count }) where stale != "/." {
        if deletePackagePath(installPrefix + stale) == .removed { removedStale.append(stale) }
    }

    let infoDirectory = database.directory + "/info"
    try FileManager.default.createDirectory(atPath: infoDirectory, withIntermediateDirectories: true)
    try (installed.joined(separator: "\n") + "\n").write(toFile: infoPath(database, name, "list"), atomically: true, encoding: .utf8)
    if texts["md5sums"] == nil {
        // dpkg generates md5sums for packages that ship none.
        texts["md5sums"] = installed.compactMap { path -> String? in
            var info = stat()
            guard path != "/.", !conffiles.contains(path), lstat(installPrefix + path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, let digest = md5Hex(installPrefix + path) else { return nil }
            return "\(digest)  \(path.dropFirst())"
        }.joined(separator: "\n") + "\n"
    }
    var scripts: [String] = []
    for (file, text) in texts where file != "control" {
        let target = infoPath(database, name, file)
        try text.write(toFile: target, atomically: true, encoding: .utf8)
        let isScript = ["preinst", "postinst", "prerm", "postrm"].contains(file)
        try FileManager.default.setAttributes([.posixPermissions: isScript ? 0o755 : 0o644], ofItemAtPath: target)
        if isScript { scripts.append(file) }
    }
    for file in ["preinst", "postinst", "prerm", "postrm", "conffiles", "md5sums", "triggers", "shlibs", "symbols"] where texts[file] == nil {
        try? FileManager.default.removeItem(atPath: infoPath(database, name, file))
    }

    var fields = control
    fields["Status"] = "install ok installed"
    if !conffiles.isEmpty {
        // dpkg writes "Conffiles:" followed by one indented " path md5" line per file.
        fields["Conffiles"] = "\n" + conffiles.map { "\($0) \(md5Hex(installPrefix + $0) ?? "newconffile")" }.joined(separator: "\n")
    }
    let order = (metadata["control_order"] as? [String]) ?? Array(control.keys)
    let stanza = Stanza.compose(fields, order: order)
    if let index = database.stanzas.firstIndex(where: { $0.package == name }) { database.stanzas[index] = stanza } else { database.stanzas.append(stanza) }
    try database.save()

    let (registered, registrationFailed) = registerBundles(installed)
    let verification = try packageStatus(name)
    guard verification["installed"] as? Bool == true, verification["version"] as? String == version else { throw IcliError.failed("status database does not show \(name) \(version) installed after the transaction") }
    var result: String
    if let previousVersion {
        var comparison: Int32 = 0
        result = icli_compare_debian_versions(previousVersion, version, &comparison) == 0 ? "installed" : comparison == 0 ? "reinstalled" : comparison < 0 ? "upgraded" : "downgraded"
    } else {
        result = "installed"
    }
    var payload: [String: Any] = ["package": name, "version": version, "architecture": architecture, "path": path, "result": result, "previous_version": previousVersion ?? "", "status": verification["status"] ?? "", "files": installed.count, "kept_conffiles": unpacked["kept"] ?? [], "removed_stale_files": removedStale, "scripts_not_run": scripts.sorted(), "registered_apps": registered, "unmet_dependencies": unmet, "completion": scripts.isEmpty && registrationFailed.isEmpty ? "complete" : "partial"]
    if !registrationFailed.isEmpty { payload["registration_failed"] = registrationFailed }
    return payload
}

/// Native removal: unregister app bundles, delete the recorded files (directories
/// only when empty), keep conffiles as dpkg does, and update the database.
public func removeDeb(_ name: String, purge: Bool = false) throws -> [String: Any] {
    try validPackageName(name)
    var database = try DpkgDatabase()
    guard let stanza = database.stanza(name), stanza.installed || purge else { return ["package": name, "removed": false, "message": "package is not installed"] }
    try database.acquireLock()
    defer { database.releaseLock() }
    let files = fileList(database, name)
    let conffiles = purge ? [] : ((try? String(contentsOfFile: infoPath(database, name, "conffiles"), encoding: .utf8)) ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let scripts = ["prerm", "postrm"].filter { FileManager.default.fileExists(atPath: infoPath(database, name, $0)) }
    let unregistered = unregisterBundles(files)
    var removed: [String] = [], failed: [String] = []
    for path in files.sorted(by: { $0.count > $1.count }) where path != "/." && !conffiles.contains(path) {
        switch deletePackagePath(installPrefix + path) {
        case .removed: removed.append(path)
        case .failed: failed.append(path)
        case .skipped: break
        }
    }
    guard failed.isEmpty else { throw IcliError.commandFailed(["package": name, "error": "remove_failed", "message": "could not delete \(failed.count) file(s)", "failed": failed]) }
    let infoDirectory = database.directory + "/info/"
    let infoFiles = ((try? FileManager.default.contentsOfDirectory(atPath: infoDirectory)) ?? []).filter { $0.hasPrefix(name + ".") }
    if conffiles.isEmpty {
        for file in infoFiles { try? FileManager.default.removeItem(atPath: infoDirectory + file) }
        database.stanzas.removeAll { $0.package == name }
    } else {
        for file in infoFiles where !["list", "conffiles", "postrm", "md5sums"].contains(String(file.dropFirst(name.count + 1))) { try? FileManager.default.removeItem(atPath: infoDirectory + file) }
        try (conffiles.joined(separator: "\n") + "\n").write(toFile: infoPath(database, name, "list"), atomically: true, encoding: .utf8)
        var fields = stanza.fields
        fields["Status"] = "deinstall ok config-files"
        if let index = database.stanzas.firstIndex(where: { $0.package == name }) { database.stanzas[index] = Stanza.compose(fields, order: stanza.order) }
    }
    try database.save()
    let after = try packageStatus(name)
    guard after["installed"] as? Bool == false else { throw IcliError.failed("status database still shows \(name) installed") }
    return ["package": name, "removed": true, "previous_version": stanza.fields["Version"] ?? "", "status": after["status"] ?? "not-installed", "files_removed": removed.count, "kept_conffiles": conffiles, "unregistered_apps": unregistered, "scripts_not_run": scripts, "completion": scripts.isEmpty ? "complete" : "partial"]
}
