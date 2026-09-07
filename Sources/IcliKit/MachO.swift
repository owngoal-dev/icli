import Foundation

/// Read public Mach-O metadata without launching ldid or inspecting process memory.
func machOInfo(at path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    func u32(_ offset: Int, bigEndian: Bool = false) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { throw IcliError.failed("truncated Mach-O metadata") }
        let values = (0..<4).map { UInt32(data[offset + $0]) }
        if bigEndian { return values[0] << 24 | values[1] << 16 | values[2] << 8 | values[3] }
        return values[0] | values[1] << 8 | values[2] << 16 | values[3] << 24
    }
    var base = 0
    let magic = try u32(0)
    if magic == 0xbebafeca {
        let count = Int(try u32(4, bigEndian: true))
        guard count > 0, count <= 128 else { throw IcliError.failed("invalid universal Mach-O") }
        var arm64: Int?
        for i in 0..<count {
            let entry = 8 + i * 20
            if try u32(entry, bigEndian: true) == 0x0100000c { arm64 = Int(try u32(entry + 8, bigEndian: true)); break }
        }
        guard let arm64 else { throw IcliError.failed("Mach-O has no arm64 slice") }
        base = arm64
    }
    guard try u32(base) == 0xfeedfacf else { throw IcliError.failed("expected a 64-bit Mach-O") }
    let count = Int(try u32(base + 16)), bytes = Int(try u32(base + 20))
    var offset = base + 32
    guard bytes <= data.count - offset, count <= bytes / 8 else { throw IcliError.failed("invalid Mach-O load commands") }
    let end = offset + bytes
    var encrypted = false
    var entitlements: [String: Any] = [:]
    for _ in 0..<count {
        guard offset <= end - 8 else { throw IcliError.failed("truncated load command") }
        let command = try u32(offset), size = Int(try u32(offset + 4))
        guard size >= 8, size <= end - offset else { throw IcliError.failed("invalid load command size") }
        if command == 0x2c || command == 0x21 {
            guard size >= 20 else { throw IcliError.failed("invalid encryption command") }
            encrypted = try u32(offset + 16) != 0
        }
        if command == 0x1d {
            guard size >= 16 else { throw IcliError.failed("invalid signature command") }
            let signature = base + Int(try u32(offset + 8)), length = Int(try u32(offset + 12))
            guard length >= 12, signature <= data.count - length else { throw IcliError.failed("invalid signature bounds") }
            if try u32(signature, bigEndian: true) == 0xfade0cc0 {
                let blobLength = Int(try u32(signature + 4, bigEndian: true))
                let slots = Int(try u32(signature + 8, bigEndian: true))
                guard blobLength <= length, blobLength >= 12, slots <= (blobLength - 12) / 8 else { throw IcliError.failed("invalid signature index") }
                for i in 0..<slots {
                    let entry = signature + 12 + i * 8
                    if try u32(entry, bigEndian: true) != 5 { continue }
                    let relative = Int(try u32(entry + 4, bigEndian: true))
                    guard relative <= blobLength - 8 else { throw IcliError.failed("invalid entitlement offset") }
                    let blob = signature + relative
                    guard try u32(blob, bigEndian: true) == 0xfade7171 else { continue }
                    let size = Int(try u32(blob + 4, bigEndian: true))
                    guard size >= 8, size <= blobLength - relative else { throw IcliError.failed("invalid entitlement size") }
                    entitlements = try PropertyListSerialization.propertyList(from: data.subdata(in: blob + 8..<blob + size), format: nil) as? [String: Any] ?? [:]
                }
            }
        }
        offset += size
    }
    return ["encrypted": encrypted, "entitlements": entitlements]
}
