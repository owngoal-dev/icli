import CommonCrypto
import Darwin
import Foundation
import Security

/// The record `device passcode unlock` keeps between runs so that an automated
/// caller cannot lock the device out by repeating itself.
///
/// It holds a salted PBKDF2 digest of every passcode the keybag rejected since
/// the last successful unlock, never a passcode itself and never the correct
/// one. A passcode whose digest is listed is rejected here without reaching the
/// keybag, so the same wrong passcode costs at most one real attempt however
/// often it is sent. The number of listed digests is also the local failure
/// count that the attempt budget is measured against, next to the keybag's own
/// counter.
///
/// A device passcode is short, so these digests can be reversed offline by
/// anyone who can read the file; PBKDF2 only slows that down. The file is
/// therefore 0600 in a 0700 directory, and it lists only wrong passcodes.
///
/// Every operation runs under an exclusive flock(2) on the file, so concurrent
/// icli processes take turns and each sees the attempts the others made. A
/// ledger that cannot be parsed fails closed: nothing is attempted until it is
/// cleared.
public struct PasscodeLedger {
    public static let defaultPath = "/var/mobile/Library/Caches/com.icli.icli/passcode-ledger.json"
    static let iterations: UInt32 = 200_000

    public struct State {
        public var salt: Data
        public var rejected: [(digest: Data, at: Date)]

        public var failures: Int { rejected.count }
    }

    public let path: String

    public init(path: String = PasscodeLedger.defaultPath) {
        self.path = path
    }

    /// Runs `body` with the ledger's state under the lock and writes back what
    /// it leaves in `state`. The state is fresh, with a new random salt, when
    /// the file is empty.
    public func withLock<T>(_ body: (inout State) throws -> T) throws -> T {
        try withLockedFile { contents in
            var state = try contents.isEmpty ? Self.fresh() : Self.decode(contents)
            let result = try body(&state)
            return (result, state)
        }
    }

    /// Empties the ledger, unreadable or not: the next unlock may try any
    /// passcode again. Returns how many rejected passcodes it held, or nil when
    /// the file could not be read.
    public func clear() throws -> Int? {
        try withLockedFile { contents in
            let previous = contents.isEmpty ? 0 : (try? Self.decode(contents))?.failures
            return (previous, try Self.fresh())
        }
    }

    /// Opens and locks the file, hands `body` its contents, and replaces them
    /// with the state it returns.
    private func withLockedFile<T>(_ body: (Data) throws -> (T, State)) throws -> T {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw IcliError.failed("cannot open the passcode ledger \(path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw IcliError.failed("cannot lock the passcode ledger \(path)")
        }
        // mobile and root share one budget: a ledger root created stays
        // readable by mobile's next run.
        if geteuid() == 0 {
            chown(directory, 501, 501)
            fchown(fd, 501, 501)
        }
        fchmod(fd, 0o600)

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let (result, state) = try body(handle.readToEnd() ?? Data())
        let encoded = try Self.encode(state)
        guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else {
            throw IcliError.failed("cannot rewrite the passcode ledger \(path)")
        }
        try handle.write(contentsOf: encoded)
        fsync(fd)
        return result
    }

    /// The salted digest the ledger compares passcodes by.
    public static func digest(_ passcode: [UInt8], salt: Data) -> Data {
        var output = [UInt8](repeating: 0, count: 32)
        let status = passcode.withUnsafeBufferPointer { passcodeBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passcodeBytes.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                    passcodeBytes.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &output,
                    output.count,
                )
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return Data(output)
    }

    static func fresh() throws -> State {
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else {
            throw IcliError.failed("no random bytes for the passcode ledger salt")
        }
        return State(salt: Data(salt), rejected: [])
    }

    static func decode(_ data: Data) throws -> State {
        let corrupt = IcliError.failed(
            "the passcode ledger is unreadable; nothing was attempted. Clear it with `icli device passcode forget --force`.",
        )
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 1,
              let saltText = object["salt"] as? String, let salt = Data(base64Encoded: saltText), salt.count == 16,
              object["iterations"] as? Int == Int(iterations),
              let entries = object["rejected"] as? [[String: Any]]
        else { throw corrupt }
        var rejected: [(digest: Data, at: Date)] = []
        for entry in entries {
            guard let text = entry["digest"] as? String, let digest = Data(base64Encoded: text), digest.count == 32,
                  let at = entry["at"] as? Double
            else { throw corrupt }
            rejected.append((digest, Date(timeIntervalSince1970: at)))
        }
        return State(salt: salt, rejected: rejected)
    }

    static func encode(_ state: State) throws -> Data {
        let object: [String: Any] = [
            "version": 1,
            "iterations": Int(iterations),
            "salt": state.salt.base64EncodedString(),
            "rejected": state.rejected.map { ["digest": $0.digest.base64EncodedString(), "at": $0.at.timeIntervalSince1970] },
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

extension PasscodeLedger.State {
    public func contains(_ digest: Data) -> Bool {
        rejected.contains { $0.digest == digest }
    }

    public mutating func recordRejected(_ digest: Data, at date: Date = Date()) {
        guard !contains(digest) else { return }
        rejected.append((digest, date))
    }
}
