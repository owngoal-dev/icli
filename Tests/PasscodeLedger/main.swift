import Foundation

// The passcode ledger behind `device passcode unlock`, checked on the Mac:
// what it stores, how it matches a passcode, and that it fails closed.

enum IcliError: Error {
    case failed(String)
}

enum TestFailure: Error {
    case check(String)
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure.check(message) }
}

let work = URL(fileURLWithPath: CommandLine.arguments[1])
let passcode = Array("123456".utf8)

func ledger(_ name: String) -> PasscodeLedger {
    PasscodeLedger(path: work.appendingPathComponent(name).appendingPathComponent("ledger.json").path)
}

func recordsAndMatchesAcrossRuns() throws {
    let subject = ledger("persist")
    try subject.withLock { state in
        try check(state.failures == 0, "a new ledger is empty")
        state.recordRejected(PasscodeLedger.digest(passcode, salt: state.salt))
        state.recordRejected(PasscodeLedger.digest(passcode, salt: state.salt))
    }
    try subject.withLock { state in
        try check(state.failures == 1, "a repeated passcode is recorded once")
        try check(state.contains(PasscodeLedger.digest(passcode, salt: state.salt)), "the passcode matches in a later run")
        try check(!state.contains(PasscodeLedger.digest(Array("123457".utf8), salt: state.salt)), "another passcode does not match")
    }
}

func storesNoPasscodeAndStaysPrivate() throws {
    let subject = ledger("private")
    try subject.withLock { $0.recordRejected(PasscodeLedger.digest(passcode, salt: $0.salt)) }
    let text = try String(contentsOfFile: subject.path, encoding: .utf8)
    try check(!text.contains("123456"), "the ledger holds no passcode")
    let file = try FileManager.default.attributesOfItem(atPath: subject.path)
    try check((file[.posixPermissions] as? Int) == 0o600, "the ledger is 0600")
    let directory = try FileManager.default.attributesOfItem(atPath: (subject.path as NSString).deletingLastPathComponent)
    try check((directory[.posixPermissions] as? Int) == 0o700, "its directory is 0700")
}

func saltsDiffer() throws {
    var first = Data(), second = Data()
    try ledger("salt-a").withLock { first = PasscodeLedger.digest(passcode, salt: $0.salt) }
    try ledger("salt-b").withLock { second = PasscodeLedger.digest(passcode, salt: $0.salt) }
    try check(first != second, "two ledgers digest the same passcode differently")
}

func clearEmpties() throws {
    let subject = ledger("clear")
    try subject.withLock { $0.recordRejected(PasscodeLedger.digest(passcode, salt: $0.salt)) }
    try check(try subject.clear() == 1, "clear reports what it removed")
    try subject.withLock { try check($0.failures == 0, "a cleared ledger is empty") }
}

func corruptFailsClosed() throws {
    let subject = ledger("corrupt")
    try FileManager.default.createDirectory(atPath: (subject.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data("{\"version\":1".utf8).write(to: URL(fileURLWithPath: subject.path))
    var ran = false
    var refused = false
    do {
        try subject.withLock { _ in ran = true }
    } catch IcliError.failed {
        refused = true
    }
    try check(refused && !ran, "nothing runs on a corrupt ledger")
    try check(try subject.clear() == nil, "clear reports the ledger was unreadable")
    try subject.withLock { try check($0.failures == 0, "a cleared corrupt ledger is usable and empty") }
}

let tests: [(String, () throws -> Void)] = [
    ("records and matches across runs", recordsAndMatchesAcrossRuns),
    ("stores no passcode and stays private", storesNoPasscodeAndStaysPrivate),
    ("salts differ", saltsDiffer),
    ("clear empties", clearEmpties),
    ("corrupt fails closed", corruptFailsClosed),
]
var failed = false
for (name, test) in tests {
    do {
        try test()
        print("PASS \(name)")
    } catch {
        failed = true
        print("FAIL \(name): \(error)")
    }
}
exit(failed ? 1 : 0)
