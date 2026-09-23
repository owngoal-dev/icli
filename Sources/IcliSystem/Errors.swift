import Darwin
import Foundation
import IcliSystemPrivate

public enum IcliError: Error {
    case locked
    case unavailable(String)
    case forceRequired(String)
    case missing(String)
    case failed(String)
    case commandFailed([String: Any])

    public var code: String {
        switch self {
        case .unavailable: "unavailable"
        case .locked: "device_locked"
        case .forceRequired: "force_required"
        case .missing: "missing_dependency"
        case .failed: "failed"
        case .commandFailed: "command_failed"
        }
    }

    public var message: String {
        switch self {
        case .locked:
            "device is locked or screen is off; wake the device before interactive commands"
        case let .forceRequired(action):
            "pass --force to \(action)"
        case let .unavailable(message):
            message
        case let .missing(name):
            "\(name) is not installed"
        case let .failed(message):
            message
        case let .commandFailed(result):
            "command exited with status \(result["status"] ?? 1)"
        }
    }

    public var payload: [String: Any] {
        var result: [String: Any] = [:]
        if case let .commandFailed(output) = self {
            result = output
        }
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
    if let error = result["error"] as? String {
        throw IcliError.failed(error)
    }
    return result
}
