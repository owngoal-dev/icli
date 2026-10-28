import Foundation
import IcliPrivate
import IcliSystem

// Unlocking the device keybag with a passcode the caller supplies, for test
// automation. It is built so that a script, or an agent, cannot lock a device
// out by retrying: see PasscodeLedger for the record behind the guards below.

/// iOS answers a fifth wrong passcode with a one-minute delay and keeps
/// lengthening it; icli never makes the attempt that would be the fifth.
public let passcodeFailureCeiling = 4
public let defaultPasscodeFailureLimit = 3

/// What `unlockDevice` answers with in `status`, which is also the exit code.
public enum PasscodeUnlockStatus: Int {
    case unlocked = 0
    /// The keybag rejected this passcode just now; it is in the ledger.
    case rejected = 3
    /// The ledger already lists this passcode as rejected; nothing was attempted.
    case rejectedCached = 4
    /// A guard refused to attempt: the budget is spent, or the keybag is
    /// backing off or blocked.
    case refused = 5
    /// The keybag returned an error without counting a failed attempt, such as
    /// a missing entitlement; the passcode was not recorded.
    case systemError = 6
}

extension PasscodeUnlockStatus {
    /// The `result` string in an answer.
    public var name: String {
        switch self {
        case .unlocked: "unlocked"
        case .rejected: "rejected"
        case .rejectedCached: "rejected_cached"
        case .refused: "refused"
        case .systemError: "system_error"
        }
    }
}

/// MobileKeyBag's lock state and attempt counters, with the ledger's count.
/// `lock_state` is MKBGetDeviceLockState's raw value: 0 unlocked, 1 locked,
/// 2 locking, 3 no passcode.
public func passcodeStatus(ledger: PasscodeLedger = PasscodeLedger()) throws -> [String: Any] {
    var report = try keybagInfo()
    let failures = try ledger.withLock { $0.failures }
    report["ledger_failures"] = failures
    report["ledger_path"] = ledger.path
    report["attempts_remaining"] = attemptsRemaining(keybag: report, ledgerFailures: failures, limit: defaultPasscodeFailureLimit)
    report["lock_screen"] = lockScreenReport()
    return report
}

/// Clears the ledger, so passcodes it rejected may be tried again; needed
/// after the device passcode changes.
public func forgetPasscodeAttempts(ledger: PasscodeLedger = PasscodeLedger()) throws -> [String: Any] {
    let cleared = try ledger.clear()
    return ["cleared": cleared ?? 0, "was_unreadable": cleared == nil, "ledger_path": ledger.path]
}

/// Unlock the keybag with `passcode`, which is wiped before this returns.
///
/// In order, nothing reaches the keybag when: it is already unlocked or has no
/// passcode; the ledger lists this passcode as rejected; the larger of the
/// ledger's failures and the keybag's failed-attempt counter has reached
/// `limit` (at most `passcodeFailureCeiling`); or the keybag reports a back-off
/// or a permanent block. `checkOnly` runs the same guards and stops before the
/// attempt. A failed attempt is recorded when the keybag's counter rose, or
/// when the counter cannot be read; a success empties the ledger.
///
/// The keybag unlocking does not dismiss SpringBoard's lock screen;
/// `lock_screen` reports whether it is still up.
public func unlockDevice(
    passcode: inout [UInt8],
    limit: Int = defaultPasscodeFailureLimit,
    checkOnly: Bool = false,
    ledger: PasscodeLedger = PasscodeLedger(),
) throws -> [String: Any] {
    defer { wipe(&passcode) }
    guard (1 ... 128).contains(passcode.count), !passcode.contains(0) else {
        throw IcliError.failed("the passcode must be 1-128 bytes without NUL")
    }
    guard (1 ... passcodeFailureCeiling).contains(limit) else {
        throw IcliError.failed("--max-failures must be between 1 and \(passcodeFailureCeiling)")
    }

    return try ledger.withLock { state in
        let before = try keybagInfo()
        var report: [String: Any] = ["attempted": false, "ledger_path": ledger.path]
        func answer(_ status: PasscodeUnlockStatus, _ hint: String) -> [String: Any] {
            report["status"] = status.rawValue
            report["result"] = status.name
            report["hint"] = hint
            report["ledger_failures"] = state.failures
            report["lock_screen"] = lockScreenReport()
            return report
        }

        let lockState = before["lock_state"] as? Int
        report["lock_state"] = before["lock_state"]
        if lockState == 0 || lockState == 3 {
            report["already_unlocked"] = true
            return answer(.unlocked, lockState == 3
                ? "The device has no passcode; nothing to unlock."
                : "The keybag is already unlocked; nothing was attempted.")
        }

        let digest = PasscodeLedger.digest(passcode, salt: state.salt)
        if state.contains(digest) {
            return answer(.rejectedCached, "This passcode was already rejected and is not tried again. Supply the correct passcode; after changing the device passcode, run `icli device passcode forget --force`.")
        }

        let remaining = attemptsRemaining(keybag: before, ledgerFailures: state.failures, limit: limit)
        report["attempts_remaining"] = remaining
        if let backoff = before["backoff_seconds"] as? Int, backoff > 0 {
            report["backoff_seconds"] = backoff
            return answer(.refused, "The keybag is delaying passcode attempts for \(backoff) s; icli does not attempt during a back-off.")
        }
        if before["permanently_blocked"] as? Bool == true {
            return answer(.refused, "The keybag has blocked passcode entry; the device needs recovery by a person.")
        }
        if remaining <= 0 {
            return answer(.refused, "\(max(state.failures, before["failed_attempts"] as? Int ?? 0)) failed attempts reached the limit of \(limit); icli makes no further attempt. A person must unlock the device, which resets the count.")
        }
        if checkOnly {
            var checked = answer(.unlocked, "Every guard passed; --check made no attempt. \(remaining) attempt(s) remain.")
            checked["result"] = "check_passed"
            return checked
        }

        var available = false
        let code = passcode.withUnsafeBufferPointer { icli_keybag_unlock($0.baseAddress, $0.count, &available) }
        guard available else {
            throw IcliError.unavailable("MobileKeyBag does not offer MKBUnlockDevice on this system")
        }
        report["attempted"] = true
        report["keybag_result"] = Int(code)
        let after = try keybagInfo()
        report["lock_state"] = after["lock_state"]

        if code == 0 {
            state.rejected.removeAll()
            report["attempts_remaining"] = attemptsRemaining(keybag: after, ledgerFailures: 0, limit: limit)
            return answer(.unlocked, "The keybag is unlocked.")
        }
        let counted: Bool
        if let was = before["failed_attempts"] as? Int, let now = after["failed_attempts"] as? Int {
            counted = now > was
        } else {
            // Without the counter there is no telling a wrong passcode from a
            // refusal, so assume it counted: a passcode wrongly held back costs
            // a `forget`, one wrongly retried costs device time.
            counted = true
        }
        report["attempts_remaining"] = attemptsRemaining(keybag: after, ledgerFailures: state.failures + (counted ? 1 : 0), limit: limit)
        guard counted else {
            return answer(.systemError, "The keybag returned \(code) without counting a failed attempt (is com.apple.keystore.device in the signature?). The passcode was not recorded.")
        }
        state.recordRejected(digest)
        return answer(.rejected, "The keybag rejected the passcode. It is recorded and will not be tried again.")
    }
}

private func keybagInfo() throws -> [String: Any] {
    try decodeBridgeJSON(takeCString(icli_keybag_info_json()), "keybag state")
}

/// The attempts left before `limit`, counting the larger of the ledger's
/// failures and the keybag's own counter: the keybag's resets only when a
/// person unlocks, and the ledger's survives a counter that cannot be read.
private func attemptsRemaining(keybag: [String: Any], ledgerFailures: Int, limit: Int) -> Int {
    max(0, limit - max(ledgerFailures, keybag["failed_attempts"] as? Int ?? 0))
}

private func lockScreenReport() -> [String: Any] {
    let status = icli_lock_status()
    return ["locked": status.locked, "screen_off": status.screen_off]
}

private func wipe(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        memset_s(base, buffer.count, 0, buffer.count)
    }
    bytes.removeAll()
}
