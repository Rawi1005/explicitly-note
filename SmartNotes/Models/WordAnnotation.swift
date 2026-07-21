import Foundation
import UIKit

/// A saved word underlined on a notebook page, with its definition attached.
/// Rects are stored in PDF (media box) space so the underline stays glued to
/// the word across zooming, rotation, and app relaunches.
/// Stored as JSON in `NotebookPage.annotationsData`.
struct WordAnnotation: Codable, Identifiable, Hashable {
    var id: UUID
    var word: String
    var definition: String
    var colorHex: String
    /// Underlined line rects in PDF space, each encoded as [x, y, width, height].
    var rects: [[Double]]
    var createdAt: Date

    var cgRects: [CGRect] {
        rects.compactMap { values in
            guard values.count == 4 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
    }

    static func make(
        word: String,
        definition: String,
        colorHex: String,
        pdfRects: [CGRect]
    ) -> WordAnnotation {
        WordAnnotation(
            id: UUID(),
            word: word,
            definition: definition,
            colorHex: colorHex,
            rects: pdfRects.map {
                [Double($0.origin.x), Double($0.origin.y), Double($0.width), Double($0.height)]
            },
            createdAt: .now
        )
    }

    static func decoded(from data: Data?) -> [WordAnnotation] {
        guard let data, !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([WordAnnotation].self, from: data)) ?? []
    }

    static func encoded(_ annotations: [WordAnnotation]) -> Data? {
        guard !annotations.isEmpty else { return nil }
        return try? JSONEncoder().encode(annotations)
    }
}

/// Quick underline colors offered in the definition sheet and annotation popup.
let underlineColorPresets: [(name: String, hex: String)] = [
    ("Blue", "#0A84FF"),
    ("Red", "#FF3B30"),
    ("Orange", "#FF9500"),
    ("Green", "#34C759"),
    ("Purple", "#AF52DE")
]
