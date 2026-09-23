import IcliPrivate
import Foundation

/// One finger phase of a digitizer event.
public enum TouchPhase: String, CaseIterable {
    case down, move, up

    var bridgeValue: Int32 {
        switch self {
        case .down: return 0
        case .move: return 1
        case .up: return 2
        }
    }
}

/// One event of a touch sequence, followed by a pause before the next one.
public struct TouchEvent {
    public let phase: TouchPhase
    public let x: Double
    public let y: Double
    public let delayMS: Double

    public init(phase: TouchPhase, x: Double, y: Double, delayMS: Double = 0) {
        self.phase = phase; self.x = x; self.y = y; self.delayMS = delayMS
    }

    /// Decodes `[{"phase":"down","x":…,"y":…,"delay_ms":…}, …]`.
    public static func list(fromJSON json: String) throws -> [TouchEvent] {
        guard let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
            throw IcliError.failed("events must be a JSON array of {phase,x,y,delay_ms}")
        }
        return try rows.map { row in
            guard let phase = (row["phase"] as? String).flatMap(TouchPhase.init(rawValue:)) else {
                throw IcliError.failed("each event needs a phase: down, move or up")
            }
            guard let x = (row["x"] as? NSNumber)?.doubleValue, let y = (row["y"] as? NSNumber)?.doubleValue else {
                throw IcliError.failed("each event needs numeric x and y")
            }
            let delay = row["delay_ms"] ?? 0
            guard let delayMS = (delay as? NSNumber)?.doubleValue else { throw IcliError.failed("delay_ms must be a number") }
            return TouchEvent(phase: phase, x: x, y: y, delayMS: delayMS)
        }
    }
}

/// Sends one digitizer event. Points are upright UI points unless `normalized`,
/// in which case x and y are 0…1 in the fixed (portrait) digitizer space.
public func touch(_ phase: TouchPhase, x: Double, y: Double, normalized: Bool = false) throws -> [String: Any] {
    let (nx, ny) = try digitizerPoint(x, y, normalized: normalized)
    guard icli_hid_touch(phase.bridgeValue, nx, ny) else { throw hidUnavailable }
    return ["phase": phase.rawValue, "x": x, "y": y, "normalized": normalized, "digitizer_x": nx, "digitizer_y": ny]
}

/// Sends a whole sequence from one process, pausing `delayMS` after each event.
/// A finger still down at the end stays down.
public func touchSequence(_ events: [TouchEvent], normalized: Bool = false) throws -> [String: Any] {
    guard (1...10_000).contains(events.count) else { throw IcliError.failed("a sequence needs 1–10000 events") }
    guard events.allSatisfy({ $0.delayMS.isFinite && (0...60_000).contains($0.delayMS) }),
          events.reduce(0, { $0 + $1.delayMS }) <= 300_000 else {
        throw IcliError.failed("delay_ms must be 0–60000 per event and at most 300000 in total")
    }
    let points = try events.map { try digitizerPoint($0.x, $0.y, normalized: normalized) }
    let start = ProcessInfo.processInfo.systemUptime
    var down = false
    for (event, point) in zip(events, points) {
        guard icli_hid_touch(event.phase.bridgeValue, point.0, point.1) else {
            if down { _ = icli_hid_touch(TouchPhase.up.bridgeValue, point.0, point.1) }
            throw hidUnavailable
        }
        down = event.phase != .up
        if event.delayMS > 0 { Thread.sleep(forTimeInterval: event.delayMS / 1000) }
    }
    return ["events": events.count, "normalized": normalized, "finger_down": down,
        "duration_ms": Int((ProcessInfo.processInfo.systemUptime - start) * 1000)]
}

/// Sends one raw HID keyboard or consumer event: a key going down or up.
public func hidEvent(page: Int, usage: Int, down: Bool) throws -> [String: Any] {
    try validateUsage(page: page, usage: usage)
    guard icli_hid_key(UInt16(page), UInt16(usage), down) else { throw hidUnavailable }
    return ["page": page, "usage": usage, "action": down ? "down" : "up"]
}

/// Presses and releases a raw HID usage, holding it for 100 ms.
public func hidPress(page: Int, usage: Int) throws -> [String: Any] {
    try validateUsage(page: page, usage: usage)
    guard icli_hid_key(UInt16(page), UInt16(usage), true) else { throw hidUnavailable }
    usleep(100_000)
    guard icli_hid_key(UInt16(page), UInt16(usage), false) else { throw IcliError.failed("HID key release failed") }
    return ["page": page, "usage": usage, "action": "press"]
}

private let hidUnavailable = IcliError.unavailable("HID event injection is unavailable on this device.")

private func digitizerPoint(_ x: Double, _ y: Double, normalized: Bool) throws -> (Double, Double) {
    if normalized {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw IcliError.failed("normalized coordinates must be between 0 and 1")
        }
        return (x, y)
    }
    try validatePoint(x, y)
    var nx = 0.0, ny = 0.0
    icli_screen_point_to_digitizer(x, y, &nx, &ny)
    return (nx, ny)
}

private func validateUsage(page: Int, usage: Int) throws {
    guard (1...0xFFFF).contains(page), (1...0xFFFF).contains(usage) else {
        throw IcliError.failed("page and usage must be 1–0xFFFF")
    }
}
