import IcliSystemPrivate
import Foundation
import Darwin

/// LaunchServices' registrations, plus the application directories of every
/// bootstrap layout. Read-only: bundle identifier, name, paths (a `data_path`
/// means the record has a data container), version and build.
public func listApps() throws -> [String: Any] {
    var apps = decodeJSONArray(takeCString(icli_apps_json()) ?? "[]")
    apps.append(contentsOf: scanApplicationDirs())
    apps = uniqued(apps, key: "bundle_id")
    return ["apps": apps, "count": apps.count]
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
