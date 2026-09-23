import Darwin
import Foundation
import IcliSystemPrivate

// launchd system-domain services, read over launchd's bootstrap pipe. Status
// works for any caller; the mutations live in IcliKit.

/// launchd's own status code for an action, or nil when it succeeded.
/// Shared with IcliKit's service mutations.
public func launchdStatusError(_ result: [String: Any], _ action: String) -> IcliError? {
    let status = result["status"] as? Int ?? 0
    if status == EPERM || status == EACCES {
        return .failed("\(action) requires root (launchd status \(status))")
    }
    if status == 144 {
        return .failed("\(action) requires launchctl service-configure privilege (launchd status \(status))")
    }
    if status != 0 {
        return .failed("\(action) failed: launchd status \(status) (\(result["message"] as? String ?? ""))")
    }
    return nil
}

/// launchd's own labels include the `UIKitApplication:<bundle id>[hash][role]`
/// form that iOS gives app processes, so `:` and brackets are part of a valid
/// label; whitespace, slashes and control bytes are not.
public func validateServiceLabel(_ label: String) throws {
    guard label.range(of: "^[A-Za-z0-9][A-Za-z0-9._:\\[\\]-]{0,200}$", options: .regularExpression) != nil else {
        throw IcliError.failed("invalid service label")
    }
}

public func validateEnvironmentKey(_ key: String) throws {
    guard !key.isEmpty, key.count <= 1024, !key.contains("="), !key.contains("\0") else {
        throw IcliError.failed("invalid environment variable name")
    }
}

/// The launchctl-compatible service table, merged across the system domain
/// and the foreground user's domain used by iOS for proxied daemons.
public func listServices() throws -> [String: Any] {
    let result = try decodeBridgeJSON(takeCString(icli_launchd_services_json()), "launchd response")
    var rows: [String: [String: Any]] = [:]
    try forEachLaunchdDomain(in: result) { domain, record in
        let services = record["services"] as? [String: [String: Any]] ?? [:]
        for (label, service) in services {
            var row = rows[label] ?? ["label": label, "domains": [String](), "running": false]
            var domains = row["domains"] as? [String] ?? []
            domains.append(domain)
            row["domains"] = domains
            mergeLaunchdService(service, into: &row)
            rows[label] = row
        }
    }
    let services = rows.values.sorted { ($0["label"] as? String ?? "") < ($1["label"] as? String ?? "") }
    return ["count": services.count, "services": services]
}

public func disabledServiceOverrides() throws -> [String: Any] {
    let result = try decodeBridgeJSON(takeCString(icli_launchd_disabled_json()), "launchd response")
    if let error = launchdStatusError(result, "print disabled services") {
        throw error
    }
    let disabled = result["disabled"] as? [String: Bool] ?? [:]
    return ["count": disabled.count, "disabled": disabled]
}

public func printService(_ label: String) throws -> [String: Any] {
    try validateServiceLabel(label)
    let result = try decodeBridgeJSON(takeCString(icli_launchd_print_json(label)), "launchd response")
    if let error = launchdStatusError(result, "print") {
        throw error
    }
    return [
        "label": label,
        "domain": result["domain"] as? String ?? "system",
        "description": result["description"] as? String ?? "",
    ]
}

/// enabled: no disabled override; loaded: launchd knows the service; running: it has a pid.
public func serviceStatus(_ label: String) throws -> [String: Any] {
    try validateServiceLabel(label)
    let disabled = try decodeBridgeJSON(takeCString(icli_launchd_disabled_json()), "launchd response")
    if disabled["status"] as? Int != 0 {
        throw IcliError.failed("launchd did not report disabled services: status \(disabled["status"] ?? 0)")
    }
    let overrides = disabled["disabled"] as? [String: Bool] ?? [:]
    let listed = try decodeBridgeJSON(takeCString(icli_launchd_service_json(label)), "launchd response")
    var payload: [String: Any] = [
        "label": label,
        "enabled": !(overrides[label] ?? false),
        "override": overrides[label] != nil,
        "loaded": false,
        "running": false
    ]
    var domains: [String] = []
    try forEachLaunchdDomain(in: listed) { domain, record in
        let service = record["service"] as? [String: Any] ?? [:]
        domains.append(domain)
        payload["loaded"] = true
        mergeLaunchdService(service, into: &payload)
    }
    payload["domains"] = domains
    return payload
}

/// launchd's ENOSERVICE: nothing with that label is loaded in the domain.
private let launchdNoService = 113

/// Walks the system domain, then the user domain, of a launchd list response,
/// skipping a domain that reports ENOSERVICE.
private func forEachLaunchdDomain(in result: [String: Any], _ body: (String, [String: Any]) -> Void) throws {
    for domain in ["system", "user"] {
        let record = result[domain] as? [String: Any] ?? [:]
        let status = record["status"] as? Int ?? 0
        if status == launchdNoService {
            continue
        }
        if status != 0 {
            throw IcliError.failed("launchd list failed in the \(domain) domain: status \(status)")
        }
        body(domain, record)
    }
}

/// Folds one domain's launchd record into `row`: a running instance's pid wins,
/// otherwise the first domain's values stand.
private func mergeLaunchdService(_ service: [String: Any], into row: inout [String: Any]) {
    let pid = service["PID"] as? Int ?? 0
    if pid > 0 || row["pid"] == nil {
        row["pid"] = pid
        row["running"] = pid > 0
        row["last_exit_status"] = service["LastExitStatus"] ?? 0
    }
    if let program = service["Program"] {
        row["program"] = program
    }
}

/// Every visible service with its status and launchd's own description, for a
/// single system-state document. A label launchd refuses to describe is
/// recorded in `errors` and does not stop the rest.
public func servicesDump() throws -> [String: Any] {
    let services = try listServices()["services"] as? [[String: Any]] ?? []
    var rows: [[String: Any]] = []
    var errors: [String: String] = [:]
    for service in services {
        guard let label = service["label"] as? String else { continue }
        var row = service
        do {
            let described = try printService(label)
            row["domain"] = described["domain"]
            row["description"] = described["description"]
        } catch {
            errors[label] = (error as? IcliError)?.message ?? error.localizedDescription
        }
        rows.append(row)
    }
    return ["count": rows.count, "services": rows, "errors": errors, "described": rows.count - errors.count]
}

public func launchdEnvironment(_ key: String) throws -> [String: Any] {
    try validateEnvironmentKey(key)
    let result = try decodeBridgeJSON(takeCString(icli_launchd_getenv_json(key)), "launchd response")
    if result["status"] as? Int == Int(ESRCH) {
        return ["key": key, "exists": false]
    }
    if let error = launchdStatusError(result, "getenv") {
        throw error
    }
    var payload: [String: Any] = ["key": key, "exists": result["exists"] as? Bool ?? false]
    if let value = result["value"] as? String {
        payload["value"] = value
    }
    return payload
}
