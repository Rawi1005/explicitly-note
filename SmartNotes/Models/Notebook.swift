import Foundation
import SwiftData

@Model
final class Notebook {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var pageCount: Int
    /// Folder containing this notebook; nil = library root.
    var folderID: UUID?
    /// Optional accent color tag shown on the card.
    var colorHex: String?
    @Attribute(.externalStorage) var pdfData: Data?

    init(
        id: UUID = UUID(),
        title: String = "Untitled Notebook",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        pageCount: Int = 0,
        folderID: UUID? = nil,
        colorHex: String? = nil,
        pdfData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pageCount = pageCount
        self.folderID = folderID
        self.colorHex = colorHex
        self.pdfData = pdfData
    }
}

@Model
final class NotebookFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String
    /// Parent folder; nil = library root. Enables nesting.
    var parentFolderID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "New Folder",
        colorHex: String = "#007AFF",
        parentFolderID: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.parentFolderID = parentFolderID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum NotebookPageKind: String, Codable {
    case blank
    case pdf
}

@Model
final class NotebookPage {
    @Attribute(.unique) var id: UUID
    var notebookID: UUID
    var orderIndex: Int
    var kindRawValue: String
    var pdfPageIndex: Int?
    var width: Double
    var height: Double
    @Attribute(.externalStorage) var drawingData: Data?
    @Attribute(.externalStorage) var elementsData: Data?
    /// JSON-encoded [WordAnnotation]: underlined dictionary words.
    @Attribute(.externalStorage) var annotationsData: Data?

    var kind: NotebookPageKind {
        get { NotebookPageKind(rawValue: kindRawValue) ?? .blank }
        set { kindRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        notebookID: UUID,
        orderIndex: Int,
        kind: NotebookPageKind,
        pdfPageIndex: Int? = nil,
        width: Double = 612,
        height: Double = 792,
        drawingData: Data? = nil,
        elementsData: Data? = nil
    ) {
        self.id = id
        self.notebookID = notebookID
        self.orderIndex = orderIndex
        self.kindRawValue = kind.rawValue
        self.pdfPageIndex = pdfPageIndex
        self.width = width
        self.height = height
        self.drawingData = drawingData
        self.elementsData = elementsData
    }
}
