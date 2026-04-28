import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct WindowAXMetadata: Sendable, Codable, Hashable {
    public let role: String?
    public let subrole: String?
    public let document: String?
    public let documentURL: String?
    public let documentPath: String?
    public let isMain: Bool?
    public let isFocused: Bool?
    public let isModal: Bool?
    public let parentWindowID: Int?

    public init(
        role: String?,
        subrole: String?,
        document: String?,
        documentURL: String?,
        documentPath: String?,
        isMain: Bool?,
        isFocused: Bool?,
        isModal: Bool?,
        parentWindowID: Int?
    ) {
        self.role = role
        self.subrole = subrole
        self.document = document
        self.documentURL = documentURL
        self.documentPath = documentPath
        self.isMain = isMain
        self.isFocused = isFocused
        self.isModal = isModal
        self.parentWindowID = parentWindowID
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case subrole
        case document
        case documentURL = "document_url"
        case documentPath = "document_path"
        case isMain = "is_main"
        case isFocused = "is_focused"
        case isModal = "is_modal"
        case parentWindowID = "parent_window_id"
    }
}

public enum WindowAXMetadataReader {
    public static func metadata(forPid pid: Int32) -> [Int: WindowAXMetadata] {
        guard AXIsProcessTrusted() else { return [:] }
        let app = AXUIElementCreateApplication(pid)
        guard let axWindows = elementsAttribute("AXWindows", of: app) else {
            return [:]
        }

        var out: [Int: WindowAXMetadata] = [:]
        for window in axWindows {
            var cgWindowId = CGWindowID(0)
            guard _AXUIElementGetWindow(window, &cgWindowId) == .success,
                  cgWindowId != 0
            else { continue }

            let document = stringAttribute("AXDocument", of: window)
            out[Int(cgWindowId)] = WindowAXMetadata(
                role: stringAttribute("AXRole", of: window),
                subrole: stringAttribute("AXSubrole", of: window),
                document: document,
                documentURL: documentURL(from: document),
                documentPath: documentPath(from: document),
                isMain: boolAttribute("AXMain", of: window),
                isFocused: boolAttribute("AXFocused", of: window),
                isModal: boolAttribute("AXModal", of: window),
                parentWindowID: parentWindowID(of: window)
            )
        }
        return out
    }

    private static func parentWindowID(of element: AXUIElement) -> Int? {
        guard let parent = elementAttribute("AXParent", of: element) else {
            return nil
        }
        var cgWindowId = CGWindowID(0)
        guard _AXUIElementGetWindow(parent, &cgWindowId) == .success,
              cgWindowId != 0
        else { return nil }
        return Int(cgWindowId)
    }

    private static func stringAttribute(
        _ name: String,
        of element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value)
            == .success,
              let value
        else { return nil }
        if let string = value as? String, !string.isEmpty { return string }
        if CFGetTypeID(value) == CFURLGetTypeID() {
            let url = value as! CFURL
            return (url as URL).absoluteString
        }
        return nil
    }

    private static func boolAttribute(
        _ name: String,
        of element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value)
            == .success,
              let value
        else { return nil }
        if let bool = value as? Bool { return bool }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        return nil
    }

    private static func elementsAttribute(
        _ name: String,
        of element: AXUIElement
    ) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value)
            == .success,
              let value
        else { return nil }
        return value as? [AXUIElement]
    }

    private static func elementAttribute(
        _ name: String,
        of element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value)
            == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func documentURL(from document: String?) -> String? {
        guard let document, !document.isEmpty else { return nil }
        if document.hasPrefix("file://") { return document }
        if document.hasPrefix("http://") || document.hasPrefix("https://") {
            return document
        }
        if document.hasPrefix("/") {
            return URL(fileURLWithPath: document).absoluteString
        }
        return nil
    }

    private static func documentPath(from document: String?) -> String? {
        guard let document, !document.isEmpty else { return nil }
        if document.hasPrefix("file://"), let url = URL(string: document) {
            return url.path
        }
        if document.hasPrefix("/") { return document }
        return nil
    }
}
