import Foundation
import SwiftData

/// A typed note. Rich text is persisted as RTF data so formatting
/// (bold, italic, underline, headings, bullets) survives relaunches;
/// `plainTextPreview` is kept in sync by the editor for fast library
/// rendering and search without unarchiving the RTF.
@Model
final class Note {
    @Attribute(.unique) var id: UUID
    var title: String
    var contentData: Data?
    var plainTextPreview: String
    var folderName: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "Untitled Note",
        contentData: Data? = nil,
        plainTextPreview: String = "",
        folderName: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.contentData = contentData
        self.plainTextPreview = plainTextPreview
        self.folderName = folderName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
