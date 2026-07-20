import Foundation
import SwiftData
import Observation

enum NoteSortOrder: String, CaseIterable, Identifiable {
    case lastModified
    case dateCreated
    case title

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lastModified: "Last modified"
        case .dateCreated: "Date created"
        case .title: "Title"
        }
    }
}

/// Holds the library's search and sort state plus create/delete logic.
/// The live note array itself comes from the view's `@Query` so SwiftData
/// keeps it up to date; the view model only filters and orders it.
@MainActor
@Observable
final class NotesLibraryViewModel {
    var searchText = ""
    var sortOrder: NoteSortOrder = .lastModified

    @ObservationIgnored private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Applies the current search filter and sort order to the fetched notes.
    func displayNotes(from notes: [Note]) -> [Note] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [Note]
        if query.isEmpty {
            filtered = notes
        } else {
            filtered = notes.filter { note in
                note.title.localizedCaseInsensitiveContains(query)
                    || note.plainTextPreview.localizedCaseInsensitiveContains(query)
            }
        }

        switch sortOrder {
        case .lastModified:
            return filtered.sorted { $0.updatedAt > $1.updatedAt }
        case .dateCreated:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .title:
            return filtered.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    @discardableResult
    func createNote() -> Note {
        let note = Note()
        modelContext.insert(note)
        try? modelContext.save()
        return note
    }

    func delete(_ note: Note) {
        modelContext.delete(note)
        try? modelContext.save()
    }
}
