import IcliPrivate
import Foundation
import UIKit
import Vision

public func takeScreenshot(path requestedPath: String? = nil, base64: Bool = false, nativeResolution: Bool = false) throws -> [String: Any] {
    icli_private_init()
    let path = requestedPath ?? (JailbreakRoot.current.scratchDirectory() + "/icli-\(UUID().uuidString).jpg")
    guard icli_screenshot_jpeg(path, 0.8, 800_000, nativeResolution) else { throw IcliError.failed("screenshot failed") }
    defer { if base64 && requestedPath == nil { try? FileManager.default.removeItem(atPath: path) } }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let image = UIImage(data: data)?.cgImage else { throw IcliError.failed("screenshot is not a valid image") }
    let metrics = icli_screen_metrics()
    var result: [String: Any] = ["bytes": data.count, "mime_type": "image/jpeg", "width": image.width,
        "height": image.height, "coordinate_scale": Double(image.width) / metrics.width]
    if base64 { result["data"] = data.base64EncodedString() }
    if !base64 || requestedPath != nil { result["path"] = path }
    return result
}

public func tap(x: Double, y: Double) throws -> [String: Any] {
    try validatePoint(x, y)
    guard icli_hid_tap(x, y) else { throw IcliError.failed("hid tap unavailable") }
    return ["x": x, "y": y]
}

public func doubleTap(x: Double, y: Double, interval: Double = 0.1) throws -> [String: Any] {
    try validatePoint(x, y)
    try validateDuration(interval, name: "interval", maximum: 1)
    guard icli_hid_double_tap(x, y, interval) else { throw IcliError.failed("hid double-tap unavailable") }
    return ["x": x, "y": y]
}

public func longPress(x: Double, y: Double, seconds: Double) throws -> [String: Any] {
    try validatePoint(x, y)
    try validateDuration(seconds, name: "seconds")
    guard icli_hid_long_press(x, y, seconds) else { throw IcliError.failed("hid long-press unavailable") }
    return ["x": x, "y": y, "seconds": seconds]
}

public func swipe(x1: Double, y1: Double, x2: Double, y2: Double, seconds: Double, steps: Int = 20) throws -> [String: Any] {
    try validatePoint(x1, y1)
    try validatePoint(x2, y2)
    try validateDuration(seconds, name: "seconds")
    guard (1...2000).contains(steps) else { throw IcliError.failed("steps must be 1–2000") }
    guard icli_hid_swipe(x1, y1, x2, y2, seconds, Int32(steps)) else { throw IcliError.failed("hid swipe unavailable") }
    return ["from": [x1, y1], "to": [x2, y2]]
}

public func drag(points: [(Double, Double)], seconds: Double, hold: Double = 0.5, steps: Int = 20) throws -> [String: Any] {
    guard (2...1000).contains(points.count), (points.count - 1...2000).contains(steps) else { throw IcliError.failed("drag needs 2–1000 points and steps >= segments, up to 2000") }
    for (x, y) in points { try validatePoint(x, y) }
    try validateDuration(seconds, name: "seconds")
    try validateDuration(hold, name: "hold", allowZero: true)
    var xs = points.map(\.0)
    var ys = points.map(\.1)
    let ok = xs.withUnsafeMutableBufferPointer { xb in
        ys.withUnsafeMutableBufferPointer { yb in
            icli_hid_drag(xb.baseAddress, yb.baseAddress, Int32(points.count), hold, seconds, Int32(steps))
        }
    }
    guard ok else { throw IcliError.failed("hid drag unavailable") }
    return ["points": points.count]
}

public func pressButton(_ name: String) throws -> [String: Any] {
    if ["volume-up", "volume-down", "mute"].contains(name) {
        guard let raw = takeCString(icli_audio_button_json(name)), let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw IcliError.failed("invalid audio button response") }
        if let error = result["error"] as? String { throw IcliError.failed(error) }
        return result
    }
    if name == "wake" {
        guard icli_wake() else { throw IcliError.failed("wake failed") }
        return ["button": name]
    }
    guard icli_hid_button(name) else { throw IcliError.failed("unknown or failed button: \(name)") }
    return ["button": name]
}

public func typeText(_ text: String, delayMS: Double = 30) throws -> [String: Any] {
    guard !text.isEmpty, text.utf8.count <= 64 * 1024, delayMS.isFinite, (0...1000).contains(delayMS) else {
        throw IcliError.failed("text must contain 1–65536 bytes and delay-ms must be 0–1000")
    }
    for character in text {
        guard icli_hid_text(String(character)) else { throw IcliError.failed("Unicode HID input unavailable") }
        Thread.sleep(forTimeInterval: delayMS / 1000)
    }
    return ["sent": text.count, "method": "unicode_hid"]
}

public func pressKey(_ name: String) throws -> [String: Any] {
    let keys: [String: UInt16] = ["return": 0x28, "enter": 0x28, "delete": 0x2A, "backspace": 0x2A,
        "tab": 0x2B, "escape": 0x29, "space": 0x2C, "up": 0x52, "down": 0x51, "left": 0x50,
        "right": 0x4F, "home": 0x4A, "end": 0x4D, "pageup": 0x4B, "pagedown": 0x4E]
    let parts = name.lowercased().split(separator: "+").map(String.init)
    let modifierKeys: [String: UInt16] = ["cmd": 0xE3, "command": 0xE3, "ctrl": 0xE0, "control": 0xE0, "shift": 0xE1, "alt": 0xE2, "option": 0xE2]
    var modifiers: [UInt16] = []
    for part in parts.dropLast() {
        guard let key = modifierKeys[part] else { throw IcliError.failed("unknown modifier: \(part)") }
        modifiers.append(key)
    }
    let key = parts.last ?? ""
    let letter = key.utf8.count == 1 ? key.utf8.first : nil
    let usage = keys[key] ?? letter.flatMap { (97...122).contains($0) ? UInt16($0 - 97 + 4) : nil }
    guard let usage else { throw IcliError.failed("unknown key: \(name)") }
    defer { for modifier in modifiers.reversed() { _ = icli_hid_key(0x07, modifier, false) } }
    for modifier in modifiers {
        guard icli_hid_key(0x07, modifier, true) else { throw IcliError.failed("HID keyboard unavailable") }
    }
    guard icli_hid_key(0x07, usage, true) else { throw IcliError.failed("HID keyboard unavailable") }
    usleep(20_000)
    guard icli_hid_key(0x07, usage, false) else { throw IcliError.failed("HID key release failed") }
    return ["key": name, "dispatched": true]
}

public func pasteText(_ text: String) throws -> [String: Any] {
    guard !text.isEmpty, text.utf8.count <= 64 * 1024 else { throw IcliError.failed("text must contain 1–65536 bytes") }
    guard icli_hid_text(text) else { throw IcliError.failed("Unicode HID input unavailable") }
    return ["sent": text.count, "method": "unicode_hid"]
}

public func openURL(_ url: String) throws -> [String: Any] {
    guard icli_open_url(url) else { throw IcliError.failed("open url failed") }
    return ["url": url]
}

public func recognizeScreen(languages: [String], minConfidence: Float) throws -> [String: Any] {
    guard !languages.isEmpty, minConfidence.isFinite, (0...1).contains(minConfidence) else {
        throw IcliError.failed("provide languages and confidence between 0 and 1")
    }
    let path = JailbreakRoot.current.scratchDirectory() + "/icli-ocr-\(UUID().uuidString).jpg"
    guard icli_screenshot_jpeg(path, 0.9, 0, true) else { throw IcliError.failed("OCR screenshot failed") }
    defer { try? FileManager.default.removeItem(atPath: path) }
    return try recognizeImage(path: path, languages: languages, minConfidence: minConfidence)
}

private func recognizeImage(path: String, languages: [String], minConfidence: Float) throws -> [String: Any] {
    guard let image = UIImage(contentsOfFile: path), let cgImage = image.cgImage else { throw IcliError.failed("OCR image missing") }
    let pointSize = pointSizeMatching(image: cgImage)
    do {
        let blocks = try visionBlocks(in: downsampledCGImage(image, maxEdge: 1600) ?? cgImage, languages: languages, minConfidence: minConfidence, pointSize: pointSize)
        return ["blocks": blocks, "count": blocks.count, "engine": "vision"]
    } catch {
        throw IcliError.unavailable("System text recognition is unavailable on this device.")
    }
}

public func uiElements(maxElements: Int = 250, visibleOnly: Bool = true, clickableOnly: Bool = false, limit: Int? = nil) throws -> [String: Any] {
    guard (1...2000).contains(maxElements), limit == nil || (limit! > 0 && limit! <= 2000) else {
        throw IcliError.failed("element limits must be between 1 and 2000")
    }
    var result = try decodeAX(takeCString(icli_ax_elements_json(try frontmostPID(), Int32(maxElements))))
    var elements = result["elements"] as? [[String: Any]] ?? []
    if visibleOnly { elements = elements.filter { $0["visible"] as? Bool == true } }
    if clickableOnly { elements = elements.filter { $0["clickable"] as? Bool == true } }
    if let limit { elements = Array(elements.prefix(limit)) }
    result["elements"] = elements
    result["count"] = elements.count
    return result
}

private func decodeAX(_ raw: String?) throws -> [String: Any] {
    guard let raw, let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
        throw IcliError.failed("invalid AX response")
    }
    if let error = result["error"] as? String { throw IcliError.failed(error) }
    return result
}

public func describeScreen() throws -> [String: Any] {
    let frontmost = frontmostApp()
    let path = JailbreakRoot.current.scratchDirectory() + "/icli-describe-\(UUID().uuidString).jpg"
    guard icli_screenshot_jpeg(path, 0.9, 0, true), let image = UIImage(contentsOfFile: path), let original = image.cgImage else { throw IcliError.failed("screen capture failed") }
    defer { try? FileManager.default.removeItem(atPath: path) }
    let pointSize = pointSizeMatching(image: original)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let resized = UIGraphicsImageRenderer(size: pointSize, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: pointSize)) }
    guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { throw IcliError.failed("snapshot JPEG encoding failed") }
    var payload: [String: Any] = ["frontmost": frontmost, "screen": screenInfo(),
        "screenshot": ["data": jpeg.base64EncodedString(), "mime_type": "image/jpeg", "width": pointSize.width, "height": pointSize.height, "coordinate_scale": 1, "bytes": jpeg.count]]
    do { payload["elements"] = try uiElements() }
    catch { payload["elements"] = ["error": error.localizedDescription] }
    do { payload["ocr"] = try recognizeImage(path: path, languages: ["zh-Hans", "en-US"], minConfidence: 0.3) }
    catch let error as IcliError { payload["ocr"] = error.payload }
    catch { payload["ocr"] = ["error": "failed", "message": error.localizedDescription] }
    payload["context_changed"] = frontmostApp()["bundle_id"] as? String != frontmost["bundle_id"] as? String
    return payload
}

public func elementAt(x: Double, y: Double) throws -> [String: Any] {
    try validatePoint(x, y)
    return try decodeAX(takeCString(icli_ax_element_at_json(try frontmostPID(), x, y)))
}

public struct ElementSelector {
    public let text: String?
    public let identifier: String?
    public let role: String?
    public let match: String
    public let index: Int

    public init(text: String?, identifier: String? = nil, role: String? = nil, match: String = "contains", index: Int = 0) throws {
        guard (text?.isEmpty == false || identifier?.isEmpty == false), ["contains", "exact"].contains(match), index >= 0 else {
            throw IcliError.failed("provide text or identifier, match contains/exact, and a nonnegative index")
        }
        self.text = text; self.identifier = identifier; self.role = role; self.match = match; self.index = index
    }

    func matches(_ element: [String: Any]) -> Bool {
        if let role {
            if role == "control" { if element["clickable"] as? Bool != true { return false } }
            else if role != "element", element["role"] as? String != role { return false }
        }
        if let identifier {
            return element["identifier"] as? String == identifier || element["label"] as? String == identifier
        }
        guard let text else { return false }
        return ["label", "identifier", "value"].contains { key in
            let value = element[key] as? String ?? ""
            return match == "exact" ? value.compare(text, options: .caseInsensitive) == .orderedSame : value.localizedCaseInsensitiveContains(text)
        }
    }
}

private func selectedElements(_ selector: ElementSelector) throws -> [[String: Any]] {
    let result = try uiElements(maxElements: 2000)
    guard result["truncated"] as? Bool != true else { throw IcliError.failed("AX query was truncated; narrow the screen before selecting an element") }
    return (result["elements"] as? [[String: Any]] ?? []).filter(selector.matches)
}

public func tapElement(_ selector: ElementSelector) throws -> [String: Any] {
    let hits = try selectedElements(selector)
    guard hits.indices.contains(selector.index) else { throw IcliError.failed("element not found") }
    let hit = hits[selector.index]
    guard let x = hit["x"] as? Double, let y = hit["y"] as? Double else { throw IcliError.failed("element has no tap point") }
    _ = try tap(x: x, y: y)
    return ["tapped": true, "element": hit]
}

public func waitForElement(_ selector: ElementSelector, appear: Bool, timeout: TimeInterval, interval: TimeInterval = 0.3) throws -> [String: Any] {
    guard timeout.isFinite, (0...60).contains(timeout), interval.isFinite, (0.1...5).contains(interval) else {
        throw IcliError.failed("timeout must be 0–60 seconds and interval 0.1–5 seconds")
    }
    let start = ProcessInfo.processInfo.systemUptime
    repeat {
        let hits = try selectedElements(selector)
        let present = hits.indices.contains(selector.index)
        if present == appear {
            return ["found": present, "disappeared": !present, "waited_ms": Int((ProcessInfo.processInfo.systemUptime - start) * 1000), "element": present ? hits[selector.index] : [:]]
        }
        let remaining = timeout - (ProcessInfo.processInfo.systemUptime - start)
        if remaining <= 0 { break }
        Thread.sleep(forTimeInterval: min(interval, remaining))
    } while ProcessInfo.processInfo.systemUptime - start <= timeout
    throw IcliError.failed("element wait timed out")
}

private func validatePoint(_ x: Double, _ y: Double) throws {
    let metrics = icli_screen_metrics()
    guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < metrics.width, y < metrics.height else {
        throw IcliError.failed("coordinates must be finite points inside the screen")
    }
}

private func visionBlocks(in image: CGImage, languages: [String], minConfidence: Float, pointSize: CGSize) throws -> [[String: Any]] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = languages
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first, candidate.confidence >= minConfidence else { return nil }
        let box = observation.boundingBox
        return ["text": candidate.string, "confidence": candidate.confidence,
            "x": box.midX * pointSize.width, "y": (1 - box.midY) * pointSize.height,
            "width": box.width * pointSize.width, "height": box.height * pointSize.height]
    }
}

private func downsampledCGImage(_ image: UIImage, maxEdge: CGFloat) -> CGImage? {
    guard let src = image.cgImage else { return nil }
    let width = src.width
    let height = src.height
    let longEdge = max(width, height)
    if CGFloat(longEdge) <= maxEdge {
        return src
    }
    let scale = maxEdge / CGFloat(longEdge)
    let newWidth = max(Int(CGFloat(width) * scale), 1)
    let newHeight = max(Int(CGFloat(height) * scale), 1)
    UIGraphicsBeginImageContextWithOptions(CGSize(width: newWidth, height: newHeight), true, 1)
    UIImage(cgImage: src, scale: 1, orientation: .up).draw(in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
    let out = UIGraphicsGetImageFromCurrentImageContext()?.cgImage
    UIGraphicsEndImageContext()
    return out ?? src
}

private func pointSizeMatching(image: CGImage) -> CGSize {
    let metrics = icli_screen_metrics()
    let imageIsLandscape = image.width > image.height
    let screenIsLandscape = metrics.width > metrics.height
    if imageIsLandscape == screenIsLandscape {
        return CGSize(width: metrics.width, height: metrics.height)
    }
    return CGSize(width: metrics.height, height: metrics.width)
}

private func validateDuration(_ value: Double, name: String, maximum: Double = 60, allowZero: Bool = false) throws {
    guard value.isFinite, value <= maximum, allowZero ? value >= 0 : value > 0 else {
        throw IcliError.failed("\(name) must be \(allowZero ? "nonnegative" : "positive") and at most \(maximum) seconds")
    }
}
