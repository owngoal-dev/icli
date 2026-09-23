import IcliSystem
import Foundation
import UIKit

private func generalPasteboard() throws -> UIPasteboard {
    guard let pasteboard = UIPasteboard(name: .general, create: false) else {
        throw IcliError.unavailable("The system clipboard is unavailable to this process.")
    }
    return pasteboard
}

public func clipboardText() throws -> [String: Any] {
    let pasteboard = try generalPasteboard()
    guard let text = pasteboard.string else {
        if pasteboard.numberOfItems == 0 { return ["text": "", "method": "uipasteboard"] }
        throw IcliError.unavailable("Clipboard text is unavailable to this process.")
    }
    return ["text": text, "method": "uipasteboard"]
}

/// The clipboard's text (empty when it has none) with its change count,
/// pasteboard types, item count and, when it holds an image, the image's
/// size in pixels and its scale. Reading the image decodes it, so it is
/// only done when the pasteboard reports one.
public func clipboardInfo() throws -> [String: Any] {
    let pasteboard = try generalPasteboard()
    let text = pasteboard.hasStrings ? pasteboard.string : nil
    guard text != nil || !pasteboard.hasStrings else {
        throw IcliError.unavailable("Clipboard text is unavailable to this process.")
    }
    let hasImage = pasteboard.hasImages
    var result: [String: Any] = [
        "text": text ?? "",
        "method": "uipasteboard",
        "change_count": pasteboard.changeCount,
        "types": pasteboard.types,
        "items": pasteboard.numberOfItems,
        "has_text": text != nil,
        "has_image": hasImage,
    ]
    if hasImage, let image = pasteboard.image {
        result["image"] = imageMetadata(image)
    }
    return result
}

/// The clipboard image encoded as PNG, or nil when the clipboard holds none.
public func clipboardImagePNG() throws -> Data? {
    let pasteboard = try generalPasteboard()
    guard pasteboard.hasImages, let image = pasteboard.image else { return nil }
    guard let png = image.pngData() else { throw IcliError.failed("The clipboard image could not be encoded as PNG.") }
    return png
}

/// clipboardInfo(), and with an output path, the image written there as PNG.
public func clipboardInfo(imageOutput: String?) throws -> [String: Any] {
    var result = try clipboardInfo()
    guard let imageOutput else { return result }
    guard let png = try clipboardImagePNG() else { throw IcliError.failed("The clipboard holds no image to write.") }
    try png.write(to: URL(fileURLWithPath: imageOutput), options: .atomic)
    result["image_path"] = imageOutput
    result["image_bytes"] = png.count
    return result
}

public func setClipboard(_ text: String) throws -> [String: Any] {
    let pasteboard = try generalPasteboard()
    let before = pasteboard.changeCount
    pasteboard.string = text
    guard pasteboard.string == text, pasteboard.changeCount != before else {
        throw IcliError.unavailable("The device did not apply the clipboard change.")
    }
    return try clipboardInfo()
}

/// Replaces the clipboard with an image decoded from PNG, JPEG or HEIC bytes
/// and reads it back to confirm its pixel size.
public func setClipboardImage(_ data: Data) throws -> [String: Any] {
    guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
        throw IcliError.failed("The image data is not a PNG, JPEG or HEIC image this device can decode.")
    }
    let pasteboard = try generalPasteboard()
    let before = pasteboard.changeCount
    pasteboard.image = image
    let wanted = pixelSize(image)
    guard pasteboard.changeCount != before, pasteboard.hasImages, let stored = pasteboard.image, pixelSize(stored) == wanted else {
        throw IcliError.unavailable("The device did not apply the clipboard image.")
    }
    return try clipboardInfo()
}

private func pixelSize(_ image: UIImage) -> CGSize {
    CGSize(width: (image.size.width * image.scale).rounded(), height: (image.size.height * image.scale).rounded())
}

private func imageMetadata(_ image: UIImage) -> [String: Any] {
    let pixels = pixelSize(image)
    return ["width": Int(pixels.width), "height": Int(pixels.height), "scale": Double(image.scale)]
}
