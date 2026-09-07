import Foundation
import UIKit

public func clipboardText() throws -> [String: Any] {
    guard let pasteboard = UIPasteboard(name: .general, create: false) else {
        throw IcliError.unavailable("The system clipboard is unavailable to this process.")
    }
    guard let text = pasteboard.string else {
        if pasteboard.numberOfItems == 0 { return ["text": "", "method": "uipasteboard"] }
        throw IcliError.unavailable("Clipboard text is unavailable to this process.")
    }
    return ["text": text, "method": "uipasteboard"]
}

public func setClipboard(_ text: String) throws -> [String: Any] {
    guard let pasteboard = UIPasteboard(name: .general, create: false) else {
        throw IcliError.unavailable("The system clipboard is unavailable to this process.")
    }
    pasteboard.string = text
    guard pasteboard.string == text else {
        throw IcliError.unavailable("The device did not apply the clipboard change.")
    }
    return ["text": text, "method": "uipasteboard"]
}
