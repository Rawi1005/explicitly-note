import Foundation
import UIKit

/// A non-ink object placed on a notebook page: a text box or an inserted photo.
/// Stored as JSON in `NotebookPage.elementsData`.
struct PageElement: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
    }

    var id: UUID
    var kind: Kind
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var text: String
    var fontSize: Double
    var colorHex: String
    var imageFileName: String?
    // Newer fields are optional so JSON saved by earlier versions still decodes.
    /// Rotation in radians around the element's center.
    var rotation: Double?
    /// "left" | "center" | "right"
    var alignment: String?
    var isBold: Bool?
    var isItalic: Bool?
    /// "system" | "serif" | "rounded" | "mono"
    var fontDesign: String?
    /// Normalized crop rectangle (0...1 in image space); nil = uncropped.
    var cropX: Double?
    var cropY: Double?
    var cropWidth: Double?
    var cropHeight: Double?

    var rotationAngle: Double {
        get { rotation ?? 0 }
        set { rotation = newValue }
    }

    var cropRect: CGRect? {
        get {
            guard let cropX, let cropY, let cropWidth, let cropHeight else { return nil }
            return CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
        }
        set {
            cropX = newValue.map { Double($0.origin.x) }
            cropY = newValue.map { Double($0.origin.y) }
            cropWidth = newValue.map { Double($0.width) }
            cropHeight = newValue.map { Double($0.height) }
        }
    }

    var textAlignment: NSTextAlignment {
        switch alignment {
        case "center": .center
        case "right": .right
        default: .left
        }
    }

    var font: UIFont {
        var descriptor = UIFont.systemFont(ofSize: fontSize).fontDescriptor
        switch fontDesign {
        case "serif": descriptor = descriptor.withDesign(.serif) ?? descriptor
        case "rounded": descriptor = descriptor.withDesign(.rounded) ?? descriptor
        case "mono": descriptor = descriptor.withDesign(.monospaced) ?? descriptor
        default: break
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if isBold == true { traits.insert(.traitBold) }
        if isItalic == true { traits.insert(.traitItalic) }
        if !traits.isEmpty, let withTraits = descriptor.withSymbolicTraits(traits) {
            descriptor = withTraits
        }
        return UIFont(descriptor: descriptor, size: fontSize)
    }

    /// A copy with a fresh identity, offset slightly — used by Duplicate.
    func duplicated() -> PageElement {
        var copy = self
        copy.id = UUID()
        copy.x += 24
        copy.y += 24
        return copy
    }

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.origin.x
            y = newValue.origin.y
            width = newValue.width
            height = newValue.height
        }
    }

    static func textElement(at origin: CGPoint, fontSize: Double) -> PageElement {
        PageElement(
            id: UUID(),
            kind: .text,
            x: origin.x,
            y: origin.y,
            width: 220,
            height: max(fontSize * 2.2, 44),
            text: "",
            fontSize: fontSize,
            colorHex: "#000000",
            imageFileName: nil
        )
    }

    static func imageElement(frame: CGRect, fileName: String) -> PageElement {
        PageElement(
            id: UUID(),
            kind: .image,
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height,
            text: "",
            fontSize: 18,
            colorHex: "#000000",
            imageFileName: fileName
        )
    }

    static func decoded(from data: Data?) -> [PageElement] {
        guard let data, !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([PageElement].self, from: data)) ?? []
    }

    static func encoded(_ elements: [PageElement]) -> Data? {
        guard !elements.isEmpty else { return nil }
        return try? JSONEncoder().encode(elements)
    }
}

extension UIColor {
    convenience init(hexString: String) {
        var value: UInt64 = 0
        let cleaned = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: CGFloat((value & 0xFF0000) >> 16) / 255,
            green: CGFloat((value & 0x00FF00) >> 8) / 255,
            blue: CGFloat(value & 0x0000FF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            Int(round(min(max(red, 0), 1) * 255)),
            Int(round(min(max(green, 0), 1) * 255)),
            Int(round(min(max(blue, 0), 1) * 255))
        )
    }
}
