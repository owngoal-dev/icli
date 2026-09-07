import IcliPrivate
import Foundation
import Darwin

/// Physical paths for this process; bootstrap path conversion stays in Runtime.m.
public struct JailbreakRoot: Equatable {
    public enum Layout: String { case rootful, rootless, roothide }

    public let layout: Layout
    public let jbroot: String
    public let source: String
    public static let current = detect()

    public func jbrootPath(_ path: String) -> String {
        takeCString(icli_jbroot_path(path)) ?? path
    }

    /// Translate a path for an external bootstrap tool, not Foundation file APIs.
    public func rootfsPath(_ path: String) -> String {
        takeCString(icli_rootfs_path(path)) ?? path
    }

    public func scratchDirectory() -> String {
        let candidates = [NSTemporaryDirectory(), jbrootPath("/tmp")]
        return candidates.first { FileManager.default.isWritableFile(atPath: $0) } ?? NSTemporaryDirectory()
    }

    public func binary(_ name: String) -> String {
        if name.contains("/") {
            if FileManager.default.isExecutableFile(atPath: name) { return name }
            return jbrootPath(name)
        }
        let dirs = ["/usr/bin", "/usr/sbin", "/bin", "/sbin"]
        let candidates = dirs.map { jbrootPath($0 + "/" + name) } + dirs.map { $0 + "/" + name }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? jbrootPath("/usr/bin/" + name)
    }

    private static func detect() -> JailbreakRoot {
        let raw = takeCString(icli_bootstrap_json()) ?? "{}"
        let data = Data(raw.utf8)
        let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
        return JailbreakRoot(layout: Layout(rawValue: info["layout"] ?? "") ?? .rootful,
                            jbroot: info["jbroot"] ?? "/", source: info["source"] ?? "unavailable")
    }
}
