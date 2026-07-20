import Foundation
import Observation
import SwiftData

/// Thin view model for the vocabulary list: search filtering and deletion.
/// The list itself comes from `@Query` in the view so it stays live.
@MainActor
@Observable
final class VocabularyViewModel {
    var searchText = ""

    /// Case-insensitive match on the word and the short definition.
    func filtered(_ items: [VocabularyItem]) -> [VocabularyItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.word.localizedCaseInsensitiveContains(query)
                || $0.shortDefinition.localizedCaseInsensitiveContains(query)
        }
    }

    func delete(at offsets: IndexSet, from items: [VocabularyItem], modelContext: ModelContext) {
        let service = VocabularyService(modelContext: modelContext)
        for index in offsets where items.indices.contains(index) {
            try? service.delete(items[index])
        }
    }
}
