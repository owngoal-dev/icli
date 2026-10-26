import Foundation
import IcliPrivate

// MARK: - Pointer

/// Buttons of the virtual pointer: bit 0 primary, bit 1 secondary, bit 2
/// middle, as a HID mouse reports them.
public struct PointerButtons: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let primary = PointerButtons(rawValue: 1)
    public static let secondary = PointerButtons(rawValue: 2)
    public static let middle = PointerButtons(rawValue: 4)

    /// Every button a report can carry.
    public static let all: PointerButtons = [.primary, .secondary, .middle]

    /// One button by name: `primary`, `secondary` or `middle`.
    public init(name: String) throws {
        switch name {
        case "primary": self = .primary
        case "secondary": self = .secondary
        case "middle": self = .middle
        default: throw IcliError.failed("button must be primary, secondary or middle")
        }
    }
}

/// The phase of one scroll event. A scroll goes `began`, a `changed` per
/// delta, then `ended` or `cancelled`, the way a trackpad's does.
public enum ScrollPhase: String, CaseIterable, Sendable {
    case began, changed, ended, cancelled

    /// The `IOHIDEventPhaseBits` value the scroll event carries.
    public var bits: Int32 {
        switch self {
        case .began: 1
        case .changed: 2
        case .ended: 4
        case .cancelled: 8
        }
    }
}

/// The largest delta one scroll event may carry, in points. A trackpad's are a
/// few dozen; this only refuses nonsense.
public let maximumScrollDelta = 10000.0

/// Puts the virtual pointer at x, y with `buttons` held, released or kept.
///
/// The pointer is a HID mouse with an absolute position that the process
/// creates on first use and keeps until it exits. iPadOS shows it, and a
/// button held in a report is a pointer click, the same as a trackpad's: an
/// alert button or a context menu answers it as it would a trackpad. iOS on an
/// iPhone uses the device only through AssistiveTouch's pointer devices.
///
/// Points are upright UI points unless `normalized`, in which case x and y are
/// 0…1 of the interface as it is shown, from its top-left corner, in any
/// orientation. `buttons` nil keeps the buttons held as they are.
public func pointerMove(x: Double, y: Double, normalized: Bool = false, buttons: PointerButtons? = nil) throws -> [String: Any] {
    try requirePointInput()
    let (nx, ny) = try pointerPoint(x, y, normalized: normalized)
    if let buttons { try validateButtons(buttons) }
    try checkPointer(icli_pointer_move(nx, ny, Int32(buttons?.rawValue ?? -1)))
    var result: [String: Any] = ["x": x, "y": y, "normalized": normalized, "pointer_x": nx, "pointer_y": ny]
    if let buttons { result["buttons"] = buttons.rawValue }
    return result
}

/// Holds `buttons` where the pointer is, releasing every other one.
public func pointerButtons(_ buttons: PointerButtons) throws -> [String: Any] {
    try requirePointInput()
    try validateButtons(buttons)
    try checkPointer(icli_pointer_buttons(Int32(buttons.rawValue)))
    return ["buttons": buttons.rawValue]
}

/// One scroll event to the view under the pointer. dx and dy are interface
/// points with a browser wheel event's signs: positive dy goes toward the end
/// of the content under the device's natural scrolling setting (on by
/// default). The view moves by the deltas and by nothing else: iPadOS does not
/// run on after `ended`, so a caller that wants momentum sends it as more
/// `changed` deltas first. The first few points of a scroll start the gesture
/// and do not move the view (about 15 points on iPadOS 26).
public func pointerScroll(_ phase: ScrollPhase, dx: Double = 0, dy: Double = 0) throws -> [String: Any] {
    try requirePointInput()
    for (name, delta) in [("dx", dx), ("dy", dy)] {
        guard delta.isFinite, abs(delta) <= maximumScrollDelta else {
            throw IcliError.failed("\(name) must be a number within ±\(Int(maximumScrollDelta))")
        }
    }
    try checkPointer(icli_pointer_scroll(phase.bits, dx, dy))
    return ["phase": phase.rawValue, "dx": dx, "dy": dy]
}

/// Moves the pointer to x, y, waits `hover` seconds there, and clicks `button`
/// `count` times, holding it down for `hold` seconds each time.
public func pointerClick(
    x: Double,
    y: Double,
    normalized: Bool = false,
    button: PointerButtons = .primary,
    count: Int = 1,
    hold: Double = 0.05,
    hover: Double = 0,
) throws -> [String: Any] {
    try requirePointInput()
    try validateButtons(button)
    guard button.rawValue.nonzeroBitCount == 1 else { throw IcliError.failed("click one button at a time") }
    guard (1 ... 3).contains(count) else { throw IcliError.failed("count must be 1–3") }
    try validateDuration(hold, name: "hold", maximum: 10, allowZero: true)
    try validateDuration(hover, name: "hover", maximum: 10, allowZero: true)
    var result = try pointerMove(x: x, y: y, normalized: normalized, buttons: [])
    if hover > 0 { Thread.sleep(forTimeInterval: hover) }
    for index in 0 ..< count {
        if index > 0 { Thread.sleep(forTimeInterval: 0.08) }
        try checkPointer(icli_pointer_buttons(Int32(button.rawValue)))
        if hold > 0 { Thread.sleep(forTimeInterval: hold) }
        try checkPointer(icli_pointer_buttons(0))
    }
    result["button"] = button.rawValue
    result["count"] = count
    return result
}

/// A whole scroll at x, y: `began`, then dx and dy spread over `steps`
/// `changed` events across `seconds`, then `ended`.
public func pointerScrollGesture(
    x: Double,
    y: Double,
    normalized: Bool = false,
    dx: Double,
    dy: Double,
    seconds: Double = 0.3,
    steps: Int = 15,
) throws -> [String: Any] {
    try requirePointInput()
    guard (1 ... 2000).contains(steps) else { throw IcliError.failed("steps must be 1–2000") }
    try validateDuration(seconds, name: "seconds", allowZero: true)
    for (name, total) in [("dx", dx), ("dy", dy)] {
        guard total.isFinite, abs(total) / Double(steps) <= maximumScrollDelta else {
            throw IcliError.failed("\(name) per step must be a number within ±\(Int(maximumScrollDelta))")
        }
    }
    var result = try pointerMove(x: x, y: y, normalized: normalized)
    try checkPointer(icli_pointer_scroll(ScrollPhase.began.bits, 0, 0))
    let pause = seconds / Double(steps)
    do {
        for _ in 0 ..< steps {
            try checkPointer(icli_pointer_scroll(ScrollPhase.changed.bits, dx / Double(steps), dy / Double(steps)))
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        }
    } catch {
        _ = icli_pointer_scroll(ScrollPhase.cancelled.bits, 0, 0)
        throw error
    }
    try checkPointer(icli_pointer_scroll(ScrollPhase.ended.bits, 0, 0))
    result["dx"] = dx
    result["dy"] = dy
    result["steps"] = steps
    return result
}

private func pointerPoint(_ x: Double, _ y: Double, normalized: Bool) throws -> (Double, Double) {
    if normalized {
        guard x.isFinite, y.isFinite, (0 ... 1).contains(x), (0 ... 1).contains(y) else {
            throw IcliError.failed("normalized coordinates must be between 0 and 1")
        }
        return (x, y)
    }
    try validatePoint(x, y)
    let metrics = icli_screen_metrics()
    return (x / metrics.width, y / metrics.height)
}

private func validateButtons(_ buttons: PointerButtons) throws {
    guard PointerButtons.all.isSuperset(of: buttons) else {
        throw IcliError.failed("buttons must be a whole number within 0…7")
    }
}

private func checkPointer(_ status: Int32) throws {
    switch Int(status) {
    case ICLI_POINTER_OK:
        return
    case ICLI_POINTER_UNAVAILABLE:
        throw IcliError.unavailable("The virtual pointer is unavailable on this device.")
    case ICLI_POINTER_REFUSED:
        throw IcliError.unavailable("iOS refused to create the virtual pointing device.")
    case ICLI_POINTER_NOT_READY:
        throw IcliError.failed("The virtual pointing device is not ready yet; try again.")
    default:
        throw IcliError.failed("The pointer event could not be delivered.")
    }
}
