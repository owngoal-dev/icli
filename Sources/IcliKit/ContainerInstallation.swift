import Darwin
import Foundation
import IcliPrivate
import IcliSystem

/// How LaunchServices lists an app installed in its own container.
public enum AppRegistrationType: String, CaseIterable {
    case user, system
}

/// The file icli leaves in a bundle container it installed. Containers with
/// vphoned's or TrollStore's marker count as managed too; any other container
/// (App Store and system apps) is never replaced or removed here.
private let containerMarker = "_icli"
private let managedMarkers = [containerMarker, "_VPhone", "_TrollStore", "_TrollStoreLite"]

private struct CreatedContainer {
    let kind: String
    let identifier: String
}

private struct PlugIn {
    let path: String
    let bundleID: String
    let executable: String
}

private func container(_ kind: String, _ identifier: String, create: Bool) throws -> [String: Any] {
    try decodeBridgeJSON(takeCString(icli_container_json(kind, identifier, create)), "container response")
}

private func destroyContainer(_ kind: String, _ identifier: String) throws -> [String: Any] {
    try decodeBridgeJSON(takeCString(icli_container_destroy_json(kind, identifier)), "container response")
}

private func isManaged(_ bundleContainer: String) -> Bool {
    managedMarkers.contains { FileManager.default.fileExists(atPath: bundleContainer + "/" + $0) }
}

/// A path as LaunchServices reports it: symlinks resolved, without /private.
private func physicalPath(_ path: String) -> String {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    return resolved.hasPrefix("/private/var/") ? String(resolved.dropFirst(8)) : resolved
}

private func appBundle(in bundleContainer: String) -> String? {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: bundleContainer)) ?? []
    return names.sorted().first { $0.hasSuffix(".app") }.map { bundleContainer + "/" + $0 }
}

/// The app's PlugIns/*.appex bundles that name an executable. Plug-in
/// identifiers must extend the app's, so their data containers are the app's own.
private func appPlugIns(of app: String, owner: String) throws -> [PlugIn] {
    let directory = app + "/PlugIns"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    return try names.sorted().compactMap { name in
        let path = directory + "/" + name
        guard let info = NSDictionary(contentsOfFile: path + "/Info.plist"),
              let bundleID = info["CFBundleIdentifier"] as? String,
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty, !executable.contains("/"),
              FileManager.default.fileExists(atPath: path + "/" + executable) else { return nil }
        guard bundleID.hasPrefix(owner + ".") else {
            throw IcliError.failed("plug-in \(bundleID) does not extend the app identifier \(owner)")
        }
        return PlugIn(path: path, bundleID: bundleID, executable: executable)
    }
}

/// installd's ownership and modes: _installd owns everything, directories
/// and Mach-O files are 0755 and other files 0644.
private func fixPermissions(_ app: String) throws {
    var paths = [app]
    if let entries = FileManager.default.enumerator(atPath: app) {
        for case let relative as String in entries {
            paths.append(app + "/" + relative)
        }
    }
    for path in paths {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw IcliError.failed("could not read \(path): \(String(cString: strerror(errno)))")
        }
        guard lchown(path, 33, 33) == 0 else {
            throw IcliError.failed("could not change the owner of \(path): \(String(cString: strerror(errno)))")
        }
        let kind = status.st_mode & S_IFMT
        if kind == S_IFLNK {
            continue
        }
        let executable = kind == S_IFDIR || isMachO(path)
        guard chmod(path, executable ? 0o755 : 0o644) == 0 else {
            throw IcliError.failed("could not change the mode of \(path): \(String(cString: strerror(errno)))")
        }
    }
}

private func isMachO(_ path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? handle.close() }
    let magic = handle.readData(ofLength: 4)
    return magic.count == 4
        && [0xFEED_FACF, 0xCFFA_EDFE, 0xCAFE_BABE, 0xBEBA_FECA]
            .contains(magic.withUnsafeBytes { $0.load(as: UInt32.self) })
}

/// The part of a LaunchServices registration an app and its plug-ins share,
/// in the shape installd records: entitlements, data container, group
/// containers and sandbox environment. Containers created for it are added
/// to `created`.
private func registrationRecord(
    bundleID: String,
    executable: String,
    dataKind: String,
    created: inout [CreatedContainer]
) throws -> [String: Any] {
    let entitlements = try machOInfo(at: executable)["entitlements"] as? [String: Any] ?? [:]
    let containerized = entitlements["com.apple.private.security.no-container"] as? Bool != true
        && entitlements["com.apple.private.security.container-required"] as? Bool != false
    let dataID = entitlements["com.apple.private.security.container-required"] as? String ?? bundleID
    let data = try container(dataKind, dataID, create: true)
    guard let dataPath = data["path"] as? String else { throw IcliError.failed("no data container for \(bundleID)") }
    if data["existed"] as? Bool == false {
        created.append(CreatedContainer(kind: dataKind, identifier: dataID))
    }
    let home = containerized ? dataPath : "/var/mobile"
    var record: [String: Any] = [
        "CFBundleIdentifier": bundleID,
        "CodeInfoIdentifier": bundleID,
        "CompatibilityState": 0,
        "IsContainerized": containerized,
        "Container": dataPath,
        "EnvironmentVariables": [
            "CFFIXED_USER_HOME": home,
            "HOME": home,
            "TMPDIR": containerized ? dataPath + "/tmp" : "/var/tmp"
        ],
        "Entitlements": entitlements,
        "SignerOrganization": "Apple Inc.",
        "SignatureVersion": 132_352,
        "SignerIdentity": "Apple iPhone OS Application Signing",
    ]
    if let team = entitlements["com.apple.developer.team-identifier"] as? String {
        record["TeamIdentifier"] = team
    }
    var groups: [String: String] = [:]
    for (key, kind, flag) in [("com.apple.security.application-groups", "group", "HasAppGroupContainers"),
                              ("com.apple.security.system-groups", "system-group", "HasSystemGroupContainers")]
    {
        for identifier in entitlements[key] as? [String] ?? [] {
            let group = try container(kind, identifier, create: true)
            guard let path = group["path"] as? String else { continue }
            if group["existed"] as? Bool == false {
                created.append(CreatedContainer(kind: kind, identifier: identifier))
            }
            groups[identifier] = path
            record[flag] = true
        }
    }
    if !groups.isEmpty {
        record["GroupContainers"] = groups
    }
    return record
}

/// Registers a container app and its plug-ins, then reads the record back,
/// adding the data container and whether the app is sandboxed in it.
private func registerContainerApp(
    _ app: String,
    bundleID: String,
    executable: String,
    plugIns: [PlugIn],
    registration: AppRegistrationType,
    created: inout [CreatedContainer]
) throws -> [String: Any] {
    var record = try registrationRecord(
        bundleID: bundleID,
        executable: app + "/" + executable,
        dataKind: "data",
        created: &created
    )
    record["ApplicationType"] = registration == .system ? "System" : "User"
    record["Path"] = app
    record["IsDeletable"] = true
    record["IsAdHocSigned"] = true
    record["LSInstallType"] = 1
    record["HasMIDBasedSINF"] = 0
    record["MissingSINF"] = 0
    record["FamilyID"] = 0
    record["IsOnDemandInstallCapable"] = 0
    var bundlePlugIns: [String: Any] = [:]
    for plugIn in plugIns {
        var plugInRecord = try registrationRecord(
            bundleID: plugIn.bundleID,
            executable: plugIn.path + "/" + plugIn.executable,
            dataKind: "plugin",
            created: &created
        )
        plugInRecord["ApplicationType"] = "PluginKitPlugin"
        plugInRecord["Path"] = plugIn.path
        plugInRecord["PluginOwnerBundleID"] = bundleID
        bundlePlugIns[plugIn.bundleID] = plugInRecord
    }
    record["_LSBundlePlugins"] = bundlePlugIns
    let plist = try PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0)
    guard let xml = String(data: plist, encoding: .utf8), icli_register_app_dictionary(xml) else {
        throw IcliError.failed("LaunchServices refused the app registration")
    }
    var registered = try appRegistration(app)
    guard registered["registered"] as? Bool == true else {
        throw IcliError.failed("LaunchServices did not list the app after registration: \(app)")
    }
    registered["data_container"] = record["Container"]
    registered["containerized"] = record["IsContainerized"]
    return registered
}

/// Installs an IPA the way installd lays out an App Store app: its own bundle
/// container under /var/containers/Bundle/Application, a data container, and
/// a containerized LaunchServices registration. The app is installed as it is
/// signed; nothing in it is re-signed or modified, so its signature must be
/// one this device runs. An app icli (or vphoned or TrollStore) installed
/// this way is upgraded in place; any other app with the identifier is left
/// alone. A failed install removes what it added and restores an upgraded app.
public func installIPAInContainer(_ path: String, registration: AppRegistrationType = .user) throws -> [String: Any] {
    try installIPAInContainer(path, registration: registration, prepareApp: { _ in })
}

/// Runs `prepareApp` on the validated, temporary Payload/*.app before it is
/// copied into a container. The path is removed when this call returns.
public func installIPAInContainer(
    _ path: String,
    registration: AppRegistrationType,
    prepareApp: (String) throws -> Void
) throws -> [String: Any] {
    guard geteuid() == 0 else {
        throw IcliError.failed("container installation requires root; run sudo icli app install <file.ipa> --container")
    }
    guard FileManager.default.fileExists(atPath: path) else { throw IcliError.failed("package not found: \(path)") }
    let manager = FileManager.default
    let staged = try stageIPA(path)
    defer { try? manager.removeItem(atPath: staged.stage) }
    try prepareApp(staged.app)
    let bundleID = staged.bundleID
    let plugIns = try appPlugIns(of: staged.app, owner: bundleID)
    let existingContainer = try container("app", bundleID, create: false)["path"] as? String
    let previous = existingContainer.flatMap(appBundle(in:))
    if let existingContainer, previous != nil, !isManaged(existingContainer) {
        throw IcliError.failed("\(bundleID) is already installed and icli did not install it; remove it first")
    }
    if let installed = (try? appInfo(bundleID))?["bundle_path"] as? String,
       !physicalPath(installed).hasPrefix(physicalPath(existingContainer ?? "/nonexistent") + "/")
    {
        throw IcliError.failed("\(bundleID) is already installed at \(installed); only an app icli installed in a container can be replaced")
    }

    var created: [CreatedContainer] = []
    let bundleContainer: String
    if let existingContainer {
        bundleContainer = existingContainer
    } else {
        let made = try container("app", bundleID, create: true)
        guard let path = made["path"] as? String else { throw IcliError.failed("no bundle container for \(bundleID)") }
        if made["existed"] as? Bool == false {
            created.append(CreatedContainer(kind: "app", identifier: bundleID))
        }
        bundleContainer = path
    }
    let previousType = previous.flatMap { try? appRegistration($0)["type"] as? String }
    if previous != nil, (try? appInfo(bundleID)) != nil {
        _ = try killApp(bundleID, force: true)
    }

    let target = bundleContainer + "/" + (staged.app as NSString).lastPathComponent
    let backup = bundleContainer + "/.icli-previous"
    let marker = bundleContainer + "/" + containerMarker
    let markerExisted = manager.fileExists(atPath: marker)
    do {
        if let previous {
            try? manager.removeItem(atPath: backup)
            try manager.moveItem(atPath: previous, toPath: backup)
        }
        try manager.copyItem(atPath: staged.app, toPath: target)
        if !markerExisted, !manager.createFile(atPath: marker, contents: Data()) {
            throw IcliError.failed("could not mark the app container as installed by icli")
        }
        try fixPermissions(target)
        let record = try registerContainerApp(
            target,
            bundleID: bundleID,
            executable: staged.executable,
            plugIns: plugIns,
            registration: registration,
            created: &created
        )
        try? manager.removeItem(atPath: backup)
        return [
            "bundle_id": bundleID,
            "bundle_path": target,
            "bundle_container": bundleContainer,
            "data_container": record["data_container"] ?? "",
            "containerized": record["containerized"] ?? false,
            "registration": registration.rawValue,
            "plugins": plugIns.map(\.bundleID),
            "method": "container",
            "upgraded": previous != nil,
        ]
    } catch {
        if (try? appRegistration(target)["registered"] as? Bool) == true {
            _ = icli_unregister_app(target)
        }
        try? manager.removeItem(atPath: target)
        if let previous, manager.fileExists(atPath: backup),
           (try? manager.moveItem(atPath: backup, toPath: previous)) != nil,
           let executable = NSDictionary(contentsOfFile: previous + "/Info.plist")?["CFBundleExecutable"] as? String
        {
            var ignored: [CreatedContainer] = []
            _ = try? registerContainerApp(
                previous,
                bundleID: bundleID,
                executable: executable,
                plugIns: (try? appPlugIns(of: previous, owner: bundleID)) ?? [],
                registration: previousType == "System" ? .system : .user,
                created: &ignored
            )
        }
        if !markerExisted {
            try? manager.removeItem(atPath: marker)
        }
        for made in created.reversed() {
            _ = try? destroyContainer(made.kind, made.identifier)
        }
        throw error
    }
}

/// Removes an app icli (or vphoned or TrollStore) installed in its own
/// container: stops it, drops its registration, and deletes its bundle
/// container and the data containers of the app and its plug-ins through
/// MobileContainerManager. Group containers, which other apps may share, and
/// a data container named by a custom container-required entitlement are
/// kept. Returns nil for any other app.
func uninstallContainerApp(_ bundleID: String) throws -> [String: Any]? {
    guard let bundleContainer = try container("app", bundleID, create: false)["path"] as? String,
          isManaged(bundleContainer) else { return nil }
    guard geteuid() == 0 else { throw IcliError.failed("removing an app icli installed in a container requires root") }
    let app = appBundle(in: bundleContainer)
    let plugIns = app.flatMap { try? appPlugIns(of: $0, owner: bundleID) } ?? []
    if (try? appInfo(bundleID)) != nil {
        _ = try killApp(bundleID, force: true)
    }
    if let app {
        _ = try unregisterApp(app, force: true)
    }
    var removed: [String] = []
    for (kind, identifier) in plugIns.map({ ("plugin", $0.bundleID) }) + [("data", bundleID), ("app", bundleID)] {
        if let path = try destroyContainer(kind, identifier)["path"] as? String {
            removed.append(path)
        }
    }
    return ["uninstalled": bundleID, "method": "container", "removed_containers": removed]
}
