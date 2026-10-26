import Foundation
import IcliProbe
import IcliSystem

// `icli probe` is a JavaScriptCore scripting shell: a script reaches the
// device frameworks through an ObjC reflection bridge and calls back into
// icli through api(). The engine and bridge live in the IcliProbe target;
// this file is its Swift face and the default api() handler.

/// The outcome of one probe evaluation. `result` holds the described value on
/// success and `error` the message on failure — exactly one is present — and
/// `output` is everything the script printed either way.
public struct ProbeResult {
    public let result: String?
    public let error: String?
    public let output: String

    /// Whether the script ran to a value, which is whether it has no error.
    public var ok: Bool { error == nil }
}

/// A host's api() handler: it receives the method name and its parameters and
/// returns a JSON-serializable value, or throws to make api() throw in the
/// script. `defaultProbeAPI` is the in-process mapping used when a caller
/// passes none.
///
/// api() throws `code: message` in the script. An `IcliError` gives its own
/// code and message, a `ProbeAPIError` the host's, and any other error
/// `failed` with its localized description.
public typealias ProbeAPIHandler = (String, [String: Any]) throws -> Any

/// A handler's failure with the host's own error code, for a host whose
/// scripts tell its failures apart by code.
public struct ProbeAPIError: Error {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Whether this platform can run a probe. False only where JavaScriptCore is
/// absent (icli targets iOS and tvOS, which both ship it); `evaluateProbe`
/// then returns `ok == false` with the error "This platform has no
/// JavaScriptCore" instead of evaluating.
public func probeAvailable() -> Bool {
    icli_probe_available()
}

/// Evaluate `source` as a script and return its described value or its error,
/// with everything it printed collected into `output`.
///
/// The script runs INLINE, in this very process and on the calling thread:
/// there is no detach. A script that crashes or never returns takes this
/// process down with it, and it has this process's own memory, file access and
/// entitlements. A host that needs to survive a bad script spawns `icli probe`
/// as a separate process and reads its one JSON line — which is what vphoned
/// does, and why icli itself offers no `--detach`.
///
/// The probe keeps one JavaScriptCore context per process, built on first use,
/// so a later call sees the variables an earlier one defined. It is not
/// reentrant: serialize calls, as the one shared context already requires.
///
/// `api(method, params)` in a script calls `api` when one is given, or
/// `defaultProbeAPI` otherwise; a host passes its own to add capabilities
/// (vphoned injects `proc.run` this way) and may call `defaultProbeAPI` from
/// within it to fall back to icli's own.
public func evaluateProbe(_ source: String, api: ProbeAPIHandler? = nil) -> ProbeResult {
    icli_probe_set_api_handler(probeAPITrampoline)
    currentProbeAPI = api
    defer { currentProbeAPI = nil }

    var errorPointer: UnsafeMutablePointer<CChar>?
    var outputPointer: UnsafeMutablePointer<CChar>?
    let resultPointer = source.withCString { icli_probe_evaluate($0, &errorPointer, &outputPointer) }
    let output = takeCString(outputPointer) ?? ""
    if let described = takeCString(resultPointer) {
        return ProbeResult(result: described, error: nil, output: output)
    }
    return ProbeResult(result: nil, error: takeCString(errorPointer) ?? "Unknown error", output: output)
}

/// icli's own capabilities, reachable from a script as `api('svc.list')` and
/// the like. The set is deliberately small and read-oriented: enough to reach
/// icli's reports from a script without re-exposing every command, and a host
/// that wants more passes its own handler. A `.label`/`.filter` parameter is
/// read from `params` where the method takes one.
public func defaultProbeAPI(_ method: String, _ params: [String: Any]) throws -> Any {
    func string(_ key: String) throws -> String {
        guard let value = params[key] as? String, !value.isEmpty else {
            throw IcliError.failed("\(method) needs a '\(key)' parameter")
        }
        return value
    }
    switch method {
    case "env.info": return try environmentReport()
    case "device.info": return try collectDeviceSnapshot()
    case "screen.info": return screenInfo()
    case "svc.list": return try listServices()
    case "svc.status": return try serviceStatus(string("label"))
    case "app.list": return try listApps()
    case "proc.list": return try listProcesses(filter: params["filter"] as? String)
    default: throw IcliError.failed("unknown api method: \(method)")
    }
}

/// Run the interactive REPL inline, returning its exit status. The REPL reads
/// this process's stdin and writes its stdout as output happens;
/// `evaluateProbe` is the non-interactive form. Drives `icli probe repl`, and
/// a host's interactive shell (vphoned's `/v1/shell` session).
///
/// `api` answers api() for every statement until the REPL returns, as it does
/// for one `evaluateProbe` call; nil means `defaultProbeAPI`. The REPL shares
/// the one context, so do not call `evaluateProbe` while it runs.
///
/// The REPL catches SIGINT only while it reads a line, where ^C abandons a
/// half-finished statement, and puts the caller's own disposition back before
/// each evaluation: nothing inline can stop a runaway statement, so ^C then
/// does whatever SIGINT does to this process, which by default ends it.
public func runProbeREPL(api: ProbeAPIHandler? = nil) -> Int32 {
    icli_probe_set_api_handler(probeAPITrampoline)
    currentProbeAPI = api
    defer { currentProbeAPI = nil }
    return icli_probe_repl()
}

// MARK: - The api() Trampoline

/// The handler a caller passed `evaluateProbe` or `runProbeREPL`, while that
/// call runs; nil means `defaultProbeAPI`. A global because the one shared
/// context is single-threaded by design.
private var currentProbeAPI: ProbeAPIHandler?

/// Decode api()'s JSON request, run the current handler, and encode its reply
/// the way the prelude reads it: `{"result": value}`, or `{"error": {code,
/// message}}` for anything that throws. malloc-owned, which the C side frees.
private func probeAPITrampoline(_ request: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let request,
          let object = try? JSONSerialization.jsonObject(with: Data(String(cString: request).utf8)) as? [String: Any],
          let method = object["method"] as? String
    else {
        return probeReply(["error": ["code": "bad_request", "message": "the api request was not JSON"]])
    }
    let params = object["params"] as? [String: Any] ?? [:]
    do {
        return probeReply(["result": jsonSafe(try (currentProbeAPI ?? defaultProbeAPI)(method, params))])
    } catch let error as IcliError {
        return probeReply(["error": ["code": error.code, "message": error.message]])
    } catch let error as ProbeAPIError {
        return probeReply(["error": ["code": error.code, "message": error.message]])
    } catch {
        return probeReply(["error": ["code": "failed", "message": error.localizedDescription]])
    }
}

private func probeReply(_ object: [String: Any]) -> UnsafeMutablePointer<CChar>? {
    let safe = JSONSerialization.isValidJSONObject(object) ? object : ["error": ["code": "failed", "message": "unencodable reply"]]
    guard let data = try? JSONSerialization.data(withJSONObject: safe) else { return nil }
    return strdup(String(decoding: data, as: UTF8.self))
}
