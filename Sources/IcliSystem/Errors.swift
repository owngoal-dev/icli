import IcliSystemPrivate
import Foundation
import Darwin

public enum IcliError: Error {
    case locked
    case unavailable(String)
    case forceRequired(String)
    case missing(String)
    case failed(String)
    case commandFailed([String: Any])

    public var code: String {
        switch self {
        case .unavailable: return "unavailable"
        case .locked: return "device_locked"
        case .forceRequired: return "force_required"
        case .missing: return "missing_dependency"
        case .failed: return "failed"
        case .commandFailed: return "command_failed"
        }
    }

    public var message: String {
        switch self {
        case .locked:
            return "device is locked or screen is off; wake the device before interactive commands"
        case .forceRequired(let action):
            return "pass --force to \(action)"
        case .unavailable(let message):
            return message
        case .missing(let name):
            return "\(name) is not installed"
        case .failed(let message):
            return message
        case .commandFailed(let result):
            return "command exited with status \(result["status"] ?? 1)"
        }
    }

    public var payload: [String: Any] {
        var result: [String: Any] = [:]
        if case .commandFailed(let output) = self { result = output }
        result["error"] = code
        result["message"] = message
        return result
    }
}

public func takeCString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
    guard let ptr else { return nil }
    defer { icli_string_free(ptr) }
    return String(cString: ptr)
}

/// A JSON object from one of the private bridge's `*_json` functions, with an
/// `error` field turned into a thrown `IcliError`.
public func decodeBridgeJSON(_ raw: String?, _ what: String) throws -> [String: Any] {
    guard let raw, let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
        throw IcliError.failed("invalid \(what)")
    }
    if let error = result["error"] as? String { throw IcliError.failed(error) }
    return result
}
