import Darwin
import Foundation
import IcliPrivate
import IcliSystem

// MARK: - Plans

/// What uicache registers for an app bundle and its plug-ins, read from disk
/// before any container is made: Procursus' uikittools-ng, or roothide's fork
/// when `jbroot` names the roothide bootstrap the registration is made for.
struct RegistrationPlan {
    struct Bundle {
        let path: String
        let bundleID: String
        let entitlements: [String: Any]
        let containerized: Bool
        let dataContainerID: String
    }

    let app: Bundle
    let plugIns: [Bundle]
    let info: [String: Any]
    let type: AppRegistrationType
    let deletable: Bool
    let hasSettingsBundle: Bool
    let jbroot: String?
}

/// uicache's registerPath reading `app`. `type` and `deletable`, when given,
/// replace uicache's choice: a user app outside the bootstrap, deletable,
/// and a system app that is not deletable otherwise, except one iOS lets
/// users remove.
func registrationPlan(
    _ app: String,
    jbroot: String?,
    type: AppRegistrationType? = nil,
    deletable: Bool? = nil,
) throws -> RegistrationPlan {
    let path = ((app as NSString).resolvingSymlinksInPath as NSString).standardizingPath
    guard let info = NSDictionary(contentsOfFile: path + "/Info.plist") as? [String: Any],
          let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty
    else {
        throw IcliError.failed("not an app bundle: \(app)")
    }
    let directory = path + "/PlugIns"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    // Only app extensions: LaunchServices records nothing else under PlugIns
    // (a resource bundle, a framework, an .appex without NSExtension), so
    // registering one makes a container for nothing and leaves a record that
    // never matches the plan.
    let plugIns = names.sorted().compactMap { name -> RegistrationPlan.Bundle? in
        let plugIn = directory + "/" + name
        guard name.hasSuffix(".appex"),
              let plugInInfo = NSDictionary(contentsOfFile: plugIn + "/Info.plist") as? [String: Any],
              plugInInfo["NSExtension"] is [String: Any],
              let plugInID = plugInInfo["CFBundleIdentifier"] as? String, !plugInID.isEmpty
        else {
            return nil
        }
        return plannedBundle(plugIn, bundleID: plugInID, info: plugInInfo, plugIn: true, roothide: jbroot != nil)
    }
    let removable = FileManager.default.fileExists(atPath: "/System/Library/AppSignatures/" + bundleID)
    let location = normalizedAppPath(path)
    let outside = jbroot.map { !location.hasPrefix($0 + "/") } ?? location.hasPrefix("/var/containers/")
    let user = outside && !removable
    #if os(tvOS)
    // PineBoard disables a system app the programming guide did not provision
    // (EnforceProvisioningOnSystemApps), so tvOS lists every app as a user app.
    let listedType: AppRegistrationType = .user
    #else
    let listedType: AppRegistrationType = user ? .user : .system
    #endif
    return RegistrationPlan(
        app: plannedBundle(path, bundleID: bundleID, info: info, plugIn: false, roothide: jbroot != nil),
        plugIns: plugIns,
        info: info,
        type: type ?? listedType,
        deletable: deletable ?? (user || removable),
        hasSettingsBundle: FileManager.default.fileExists(atPath: path + "/Settings.bundle/Root.plist"),
        jbroot: jbroot,
    )
}

/// One bundle as uicache reads it: entitlements of its executable, none when
/// it cannot be read, and its containerization.
private func plannedBundle(
    _ path: String,
    bundleID: String,
    info: [String: Any],
    plugIn: Bool,
    roothide: Bool,
) -> RegistrationPlan.Bundle {
    let executable = info["CFBundleExecutable"] as? String
    let entitlements = executable.flatMap { try? machOSigning(at: path + "/" + $0).entitlements } ?? [:]
    func flag(_ key: String) -> Bool? {
        (entitlements[key] as? NSNumber)?.boolValue
    }
    var containerized = true
    var dataContainerID = bundleID
    if roothide, (flag("uicache.data-container-required") ?? flag("uicache.app-data-container-required")) == true {
        // roothide's way to keep an unsandboxed app's data container.
    } else if flag("com.apple.private.security.no-container") == true {
        containerized = false
    } else if let required = entitlements["com.apple.private.security.container-required"] {
        if (required as? NSNumber)?.boolValue == false {
            containerized = false
        } else if let identifier = required as? String {
            dataContainerID = identifier
        }
    }
    if containerized, roothide, flag("com.apple.private.security.no-sandbox") == true {
        containerized = false
    }
    // roothide's uicache: "pkd requires that App PlugIns be containerized".
    if plugIn, roothide {
        containerized = true
    }
    return RegistrationPlan.Bundle(
        path: path,
        bundleID: bundleID,
        entitlements: entitlements,
        containerized: containerized,
        dataContainerID: dataContainerID,
    )
}

/// The group identifiers a bundle's entitlements name: application groups,
/// then system groups.
private func groupIdentifiers(_ bundle: RegistrationPlan.Bundle) -> (application: [String], system: [String]) {
    (
        bundle.entitlements["com.apple.security.application-groups"] as? [String] ?? [],
        bundle.entitlements["com.apple.security.system-groups"] as? [String] ?? [],
    )
}

/// HOME and TMPDIR of a bundle outside a data container: the mobile user's,
/// inside the jbroot for roothide.
private func uncontainedHome(_ plan: RegistrationPlan) -> (home: String, temporary: String) {
    let root = plan.jbroot ?? ""
    return (root + "/var/mobile", root + "/var/tmp")
}

// MARK: - Registration Dictionaries

struct CreatedContainer {
    let kind: String
    let identifier: String
}

func container(_ kind: String, _ identifier: String, create: Bool) throws -> [String: Any] {
    try decodeBridgeJSON(takeCString(icli_container_json(kind, identifier, create)), "container response")
}

/// The path of a container, made when missing and then added to `created`.
private func makeContainer(_ kind: String, _ identifier: String, created: inout [CreatedContainer]) throws -> String {
    let made = try container(kind, identifier, create: true)
    guard let path = made["path"] as? String else { throw IcliError.failed("no \(kind) container for \(identifier)") }
    if made["existed"] as? Bool == false {
        created.append(CreatedContainer(kind: kind, identifier: identifier))
    }
    return path
}

/// The dictionary uicache gives registerApplicationDictionary: for `plan`,
/// with the plug-ins under _LSBundlePlugins. The data and group containers it
/// names are made, and those that did not exist are added to `created`.
func registrationDictionary(_ plan: RegistrationPlan, created: inout [CreatedContainer]) throws -> [String: Any] {
    var record = try bundleDictionary(plan.app, plan: plan, dataKind: "data", created: &created)
    record["ApplicationType"] = plan.type == .system ? "System" : "User"
    record["BundleNameIsLocalized"] = 1
    record["IsDeletable"] = plan.deletable
    record["IsAdHocSigned"] = true
    record["LSInstallType"] = 1
    record["HasMIDBasedSINF"] = 0
    record["MissingSINF"] = 0
    record["FamilyID"] = 0
    record["IsOnDemandInstallCapable"] = 0
    // Not in uicache: without it the Settings app shows no page for the app.
    if plan.hasSettingsBundle {
        record["HasSettingsBundle"] = true
    }
    var plugIns: [String: Any] = [:]
    for plugIn in plan.plugIns {
        var plugInRecord = try bundleDictionary(plugIn, plan: plan, dataKind: "plugin", created: &created)
        plugInRecord["ApplicationType"] = "PluginKitPlugin"
        plugInRecord["PluginOwnerBundleID"] = plan.app.bundleID
        plugIns[plugIn.bundleID] = plugInRecord
    }
    record["_LSBundlePlugins"] = plugIns
    return record
}

/// The keys an app and its plug-ins share. roothide gives an unsandboxed app
/// no data container; Procursus makes one for every bundle.
private func bundleDictionary(
    _ bundle: RegistrationPlan.Bundle,
    plan: RegistrationPlan,
    dataKind: String,
    created: inout [CreatedContainer],
) throws -> [String: Any] {
    var record: [String: Any] = [
        "CFBundleIdentifier": bundle.bundleID,
        "CodeInfoIdentifier": bundle.bundleID,
        "CompatibilityState": 0,
        "IsContainerized": bundle.containerized,
        "Path": bundle.path,
        "SignerOrganization": "Apple Inc.",
        "SignatureVersion": 132_352,
        "SignerIdentity": "Apple iPhone OS Application Signing",
    ]
    if !bundle.entitlements.isEmpty {
        record["Entitlements"] = bundle.entitlements
    }
    if let team = bundle.entitlements["com.apple.developer.team-identifier"] as? String {
        record["TeamIdentifier"] = team
    }
    var home = uncontainedHome(plan)
    if bundle.containerized || plan.jbroot == nil {
        let data = try makeContainer(dataKind, bundle.dataContainerID, created: &created)
        record["Container"] = data
        if bundle.containerized {
            home = (data, data + "/tmp")
        }
    }
    record["EnvironmentVariables"] = ["CFFIXED_USER_HOME": home.home, "HOME": home.home, "TMPDIR": home.temporary]
    let identifiers = groupIdentifiers(bundle)
    var groups: [String: String] = [:]
    for identifier in identifiers.application {
        groups[identifier] = try makeContainer("group", identifier, created: &created)
    }
    for identifier in identifiers.system {
        let path = try makeContainer("system-group", identifier, created: &created)
        // roothide makes system group containers but does not register them.
        if plan.jbroot == nil {
            groups[identifier] = path
        }
    }
    if !groups.isEmpty {
        record["GroupContainers"] = groups
        if !identifiers.application.isEmpty {
            record["HasAppGroupContainers"] = true
        }
        if !identifiers.system.isEmpty {
            record["HasSystemGroupContainers"] = true
        }
    }
    return record
}

// MARK: - Records

/// Every app LaunchServices lists, by normalized bundle path and by bundle
/// identifier: its identifier, path, type and signer (see
/// icli_app_index_plist). What a registration sets is read for one app at a
/// time with registeredRecord, since reading it for every app took most of
/// a refresh.
struct RegisteredApps {
    let byPath: [String: [String: Any]]
    let byID: [String: [String: Any]]

    init() throws {
        guard let xml = takeCString(icli_app_index_plist()),
              let records = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)
              as? [[String: Any]]
        else {
            throw IcliError.failed("LaunchServices application list unavailable")
        }
        var byPath: [String: [String: Any]] = [:]
        var byID: [String: [String: Any]] = [:]
        for record in records {
            if let path = record["path"] as? String {
                byPath[path] = record
            }
            if let bundleID = record["bundle_id"] as? String {
                byID[bundleID] = record
            }
        }
        self.byPath = byPath
        self.byID = byID
    }
}

func normalizedAppPath(_ path: String) -> String {
    takeCString(icli_normalized_app_path(path)) ?? path
}

/// Where LaunchServices' record of the app differs from what `plan`
/// registers, or nil when it records all of it.
func registrationDifference(_ record: [String: Any], _ plan: RegistrationPlan) -> String? {
    if record["bundle_id"] as? String != plan.app.bundleID {
        return "bundle identifier"
    }
    for (key, field) in [("CFBundleVersion", "build"), ("CFBundleShortVersionString", "version")] {
        if let expected = plan.info[key] as? String, record[field] as? String != expected {
            return field
        }
    }
    if record["type"] as? String != (plan.type == .system ? "System" : "User") {
        return "application type"
    }
    if record["settings"] as? Bool != plan.hasSettingsBundle {
        return "settings bundle"
    }
    if let difference = bundleDifference(record, plan.app, plan) {
        return difference
    }
    let plugIns = (record["plugins"] as? [[String: Any]] ?? []).reduce(into: [String: [String: Any]]()) {
        if let bundleID = $1["bundle_id"] as? String {
            $0[bundleID] = $1
        }
    }
    if Set(plugIns.keys) != Set(plan.plugIns.map(\.bundleID)) {
        return "plug-ins"
    }
    for plugIn in plan.plugIns {
        if let difference = bundleDifference(plugIns[plugIn.bundleID] ?? [:], plugIn, plan) {
            return "plug-in \(plugIn.bundleID) \(difference)"
        }
    }
    return nil
}

private func bundleDifference(
    _ record: [String: Any],
    _ bundle: RegistrationPlan.Bundle,
    _ plan: RegistrationPlan
) -> String? {
    if record["path"] as? String != normalizedAppPath(bundle.path) {
        return "path"
    }
    if !NSDictionary(dictionary: record["entitlements"] as? [String: Any] ?? [:]).isEqual(to: bundle.entitlements) {
        return "entitlements"
    }
    if record["containerized"] as? Bool != bundle.containerized {
        return "containerization"
    }
    if bundle.containerized, record["data_container"] == nil {
        return "data container"
    }
    let identifiers = groupIdentifiers(bundle)
    let groups = identifiers.application + (plan.jbroot == nil ? identifiers.system : [])
    if Set(record["groups"] as? [String] ?? []) != Set(groups) {
        return "group containers"
    }
    return nil
}

/// LaunchServices' record of the app at `path` registered as `bundleID`, or
/// nil when it lists none there.
func registeredRecord(_ bundleID: String, at path: String) throws -> [String: Any]? {
    guard let xml = takeCString(icli_app_record_plist(bundleID, path)),
          let record = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)
          as? [String: Any]
    else {
        throw IcliError.failed("LaunchServices application record unavailable")
    }
    return record.isEmpty ? nil : record
}

/// Registers `plan` and reads LaunchServices' record of the app back, for up
/// to a second while it does not record all of the plan yet. Returns the
/// record, or nil when LaunchServices does not list the app at its path.
func registerPlan(_ plan: RegistrationPlan, created: inout [CreatedContainer]) throws -> [String: Any]? {
    let dictionary = try registrationDictionary(plan, created: &created)
    let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    guard let xml = String(data: data, encoding: .utf8), icli_register_app_dictionary(xml) else {
        throw IcliError.failed("LaunchServices refused the registration of \(plan.app.path)")
    }
    var record: [String: Any]?
    for attempt in 0 ..< 10 {
        if attempt > 0 {
            usleep(100_000)
        }
        record = try registeredRecord(plan.app.bundleID, at: plan.app.path)
        if let record, registrationDifference(record, plan) == nil {
            break
        }
    }
    return record
}

// MARK: - Ownership

/// Whose app a bundle is, which decides whether and how icli registers it.
enum BundleOwner {
    /// A bootstrap's app, or a bundle outside every installer's location,
    /// registered as uicache does; `jbroot` selects roothide's uicache.
    case bootstrap(jbroot: String?)
    /// An app icli, vphoned or TrollStore installed in its own container.
    case container
    /// Apple's app or another installer's, which icli does not register.
    case foreign(String)
}

/// The owner of the bundle at `path`, which LaunchServices may list as
/// `record`. The bundle's location decides, not the bootstrap this process
/// runs from: vphoned, which registers bootstrap apps, runs from none.
func bundleOwner(_ path: String, record: [String: Any]?) -> BundleOwner {
    let location = normalizedAppPath(path)
    let containers = "/var/containers/Bundle/Application/"
    if location.hasPrefix(containers) {
        let container = containers + location.dropFirst(containers.count).prefix { $0 != "/" }
        if container.hasPrefix(containers + ".jbroot-") {
            return .bootstrap(jbroot: container)
        }
        return isManaged(container) ? .container : .foreign("an app the App Store or another installer installed")
    }
    let current = JailbreakRoot.current
    let system = ["/Applications/", "/System/", "/var/staged_system_apps/", "/AppleInternal/", "/Developer/",
                  "/private/preboot/Cryptexes/"]
    if system.contains(where: location.hasPrefix) {
        // A rootful bootstrap installs into /Applications beside Apple's
        // apps, which LaunchServices lists without a signer.
        guard current.layout == .rootful, location.hasPrefix("/Applications/"), record.map({ $0["signer"] != nil }) ?? true
        else {
            return .foreign("a system app")
        }
        return .bootstrap(jbroot: nil)
    }
    return .bootstrap(jbroot: current.layout == .roothide ? normalizedAppPath(current.jbroot) : nil)
}

/// The plan for registering the bundle at `path`, or an error naming why icli
/// does not register it: Apple's or another installer's app, at this path or
/// under its identifier elsewhere, which the registration would replace. An
/// app icli installed in a container keeps the type it was registered with.
func ownedRegistrationPlan(_ path: String, apps: RegisteredApps) throws -> RegistrationPlan {
    let record = apps.byPath[normalizedAppPath(path)]
    let plan: RegistrationPlan
    switch bundleOwner(path, record: record) {
    case let .foreign(owner):
        throw IcliError.failed("\(path) is \(owner); icli registers only bootstrap apps and apps it installed")
    case .container:
        let type: AppRegistrationType = record?["type"] as? String == "System" ? .system : .user
        plan = try registrationPlan(path, jbroot: nil, type: type, deletable: true)
    case let .bootstrap(jbroot):
        plan = try registrationPlan(path, jbroot: jbroot)
    }
    if let other = apps.byID[plan.app.bundleID], let otherPath = other["path"] as? String,
       otherPath != normalizedAppPath(plan.app.path), case let .foreign(owner) = bundleOwner(otherPath, record: other)
    {
        throw IcliError.failed("\(plan.app.bundleID) is already installed at \(otherPath), \(owner)")
    }
    return plan
}

// MARK: - Register and Refresh

/// `uicache -p`: registers the app bundle at `path` with everything uicache
/// records (entitlements, data and group containers, environment, plug-ins),
/// replacing the app's record, and reads it back. A running app is stopped
/// by the registration.
public func registerApp(_ path: String) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path + "/Info.plist") else {
        throw IcliError.failed("not an app bundle: \(path)")
    }
    let plan = try ownedRegistrationPlan(path, apps: RegisteredApps())
    var created: [CreatedContainer] = []
    guard let record = try registerPlan(plan, created: &created) else {
        throw IcliError.failed("LaunchServices did not list the app after registration: \(path)")
    }
    if let difference = registrationDifference(record, plan) {
        throw IcliError.failed("LaunchServices did not record the \(difference) of \(path)")
    }
    var result = try appRegistration(path)
    result["path"] = path
    return result
}

/// `uicache -a` for a directory (default: the bootstrap's /Applications):
/// registers each app bundle in it that LaunchServices does not list there,
/// or lists without part of what uicache registers for it now (a new build,
/// version, entitlements or plug-in, or a record a registration left
/// incomplete), and drops the records of bundles that are gone. Records that
/// match are left alone, since registering an app stops it. Apple's and other
/// installers' apps are skipped.
public func refreshApps(directory: String?) throws -> [String: Any] {
    let root = normalizedAppPath(directory ?? JailbreakRoot.current.jbrootPath("/Applications"))
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw IcliError.failed("not a directory: \(root)")
    }
    var installed: [String: String] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: root).sorted() where name.hasSuffix(".app") {
        let path = root + "/" + name
        guard let info = NSDictionary(contentsOfFile: path + "/Info.plist") else { continue }
        guard let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw IcliError.failed("missing bundle identifier: \(path)")
        }
        guard installed[bundleID] == nil else { throw IcliError.failed("duplicate bundle identifier: \(bundleID)") }
        installed[bundleID] = path
    }

    var registered: [String] = [], unchanged: [String] = [], skipped: [String] = []
    var unregistered: [String] = [], failed: [String] = []
    var plans: [String: RegistrationPlan] = [:]
    let before = try RegisteredApps()
    for (_, path) in installed.sorted(by: { $0.key < $1.key }) {
        let plan: RegistrationPlan
        do { plan = try ownedRegistrationPlan(path, apps: before) } catch {
            skipped.append(path)
            continue
        }
        plans[path] = plan
        if before.byPath[normalizedAppPath(path)] != nil,
           let record = try registeredRecord(plan.app.bundleID, at: path),
           registrationDifference(record, plan) == nil
        {
            unchanged.append(path)
            continue
        }
        var created: [CreatedContainer] = []
        if (try? registerPlan(plan, created: &created)) != nil {
            registered.append(path)
        } else {
            failed.append(path)
        }
    }

    // A moved app is registered at its new path first: both records share
    // the identifier, so the old one is dropped only for identifiers gone.
    let prefix = root + "/"
    for (path, record) in try RegisteredApps().byPath.sorted(by: { $0.key < $1.key }) {
        guard path.hasPrefix(prefix), !path.dropFirst(prefix.count).contains("/"),
              !FileManager.default.fileExists(atPath: path),
              installed[record["bundle_id"] as? String ?? ""] == nil else { continue }
        if case .foreign = bundleOwner(path, record: record) {
            continue
        }
        if icli_unregister_app(path) {
            unregistered.append(path)
        } else {
            failed.append(path)
        }
    }

    let after = try RegisteredApps()
    var problems = failed.map { "\($0) could not be registered or unregistered" }
    var unverified: [String] = []
    for (path, plan) in plans.sorted(by: { $0.key < $1.key }) {
        guard after.byPath[normalizedAppPath(path)] != nil, let record = try registeredRecord(plan.app.bundleID, at: path)
        else {
            unverified.append(path)
            problems.append("LaunchServices does not list \(path)")
            continue
        }
        if let difference = registrationDifference(record, plan) {
            unverified.append(path)
            problems.append("LaunchServices did not record the \(difference) of \(path)")
        }
    }
    for path in unregistered where after.byPath[path] != nil {
        unverified.append(path)
        problems.append("LaunchServices still lists \(path)")
    }
    let result: [String: Any] = [
        "directory": root,
        "registered": registered,
        "unchanged": unchanged,
        "unregistered": unregistered,
        "skipped": skipped,
        "failed": failed,
        "unverified": unverified,
    ]
    guard failed.isEmpty, unverified.isEmpty else {
        throw IcliError.commandFailed(result.merging([
            "error": "refresh_incomplete",
            "message": problems.joined(separator: "; "),
        ]) { $1 })
    }
    return result
}
