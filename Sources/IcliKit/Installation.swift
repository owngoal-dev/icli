import IcliPrivate
import Foundation
import Darwin

private func managedAppPath(_ bundleID: String) throws -> String {
    guard bundleID.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{1,200}$", options: .regularExpression) != nil else { throw IcliError.failed("invalid app bundle identifier") }
    return JailbreakRoot.current.jbrootPath("/Applications/icli-" + bundleID + ".app")
}

private func managedReceipt(_ bundleID: String) -> String {
    JailbreakRoot.current.jbrootPath("/var/lib/icli/apps/" + bundleID + ".json")
}

func installIPA(_ path: String) throws -> [String: Any] {
    guard geteuid() == 0 else { throw IcliError.failed("IPA installation requires root; run sudo icli app install <file.ipa>") }
    let manager = FileManager.default
    let stage = JailbreakRoot.current.scratchDirectory() + "/icli-install-" + UUID().uuidString
    try manager.createDirectory(atPath: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(atPath: stage) }
    guard let raw = takeCString(icli_extract_ipa_json(path, stage)),
          let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw IcliError.failed("invalid IPA extraction response") }
    if let error = result["error"] as? String { throw IcliError.failed(error) }
    let payload = stage + "/Payload"
    let bundles = try manager.contentsOfDirectory(atPath: payload).filter { $0.hasSuffix(".app") }
    guard bundles.count == 1 else { throw IcliError.failed("IPA must contain exactly one Payload/*.app") }
    let source = payload + "/" + bundles[0]
    let infoData = try Data(contentsOf: URL(fileURLWithPath: source + "/Info.plist"))
    guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
          let bundleID = info["CFBundleIdentifier"] as? String,
          let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
          !executable.contains("/"), executable != ".", executable != ".." else { throw IcliError.failed("IPA has invalid bundle metadata") }
    _ = try machOInfo(at: source + "/" + executable)
    let bundleRoot = URL(fileURLWithPath: source).resolvingSymlinksInPath().path + "/"
    if let entries = manager.enumerator(at: URL(fileURLWithPath: source), includingPropertiesForKeys: [.isSymbolicLinkKey]) {
        for case let item as URL in entries {
            if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
               !item.resolvingSymlinksInPath().path.hasPrefix(bundleRoot) {
                throw IcliError.failed("IPA bundle contains a symlink outside the app")
            }
        }
    }
    let target = try managedAppPath(bundleID)
    let receipt = managedReceipt(bundleID)
    let installed = try? appInfo(bundleID)
    if installed != nil && !manager.fileExists(atPath: receipt) { throw IcliError.failed("an app with this identifier is already installed outside icli") }
    let upgrading = manager.fileExists(atPath: target)
    if upgrading && !manager.fileExists(atPath: receipt) { throw IcliError.failed("installation path already exists without an icli receipt") }
    if upgrading { _ = try killApp(bundleID, force: true) }
    try manager.createDirectory(atPath: (receipt as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try manager.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let backup = stage + "/previous.app"
    if upgrading { try manager.moveItem(atPath: target, toPath: backup) }
    do {
        try manager.moveItem(atPath: source, toPath: target)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target + "/" + executable)
        guard icli_register_app(target) else { throw IcliError.failed("installed app could not be registered") }
        try JSONSerialization.data(withJSONObject: ["bundle_id": bundleID, "path": target]).write(to: URL(fileURLWithPath: receipt), options: .atomic)
    } catch {
        _ = icli_unregister_app(target)
        try? manager.removeItem(atPath: target)
        if upgrading {
            try manager.moveItem(atPath: backup, toPath: target)
            _ = icli_register_app(target)
        }
        throw error
    }
    return ["installed": bundleID, "bundle_path": target, "method": "bootstrap_app_registration", "upgraded": upgrading]
}

func uninstallManagedApp(_ bundleID: String) throws -> [String: Any]? {
    let target = try managedAppPath(bundleID)
    let receipt = managedReceipt(bundleID)
    let manager = FileManager.default
    guard manager.fileExists(atPath: receipt) else { return nil }
    guard geteuid() == 0 else { throw IcliError.failed("removing an icli-installed IPA requires root") }
    guard let data = manager.contents(atPath: receipt),
          let record = try JSONSerialization.jsonObject(with: data) as? [String: String],
          record["path"] == target, record["bundle_id"] == bundleID else { throw IcliError.failed("invalid installation receipt") }
    _ = try killApp(bundleID, force: true)
    _ = try unregisterApp(target, force: true)
    try manager.removeItem(atPath: target)
    try manager.removeItem(atPath: receipt)
    return ["uninstalled": bundleID, "method": "bootstrap_app_registration"]
}
