import SwiftData
import SwiftUI

/// The Vocabulary tab: every word the user saved from the definition
/// sheet, newest first, searchable by word or definition.
struct VocabularyListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VocabularyItem.createdAt, order: .reverse) private var items: [VocabularyItem]
    @State private var viewModel = VocabularyViewModel()

    private var filteredItems: [VocabularyItem] {
        viewModel.filtered(items)
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState
                } else if filteredItems.isEmpty {
                    ContentUnavailableView.search(text: viewModel.searchText)
                } else {
                    list
                }
            }
            .navigationTitle("Vocabulary")
            .searchable(text: $viewModel.searchText, prompt: "Search words and definitions")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Saved Words", systemImage: "character.book.closed")
        } description: {
            Text("Select a word in a note, tap Define, then choose \u{201C}Add to Vocabulary\u{201D} to build your word list.")
        }
    }

    private var list: some View {
        List {
            ForEach(filteredItems) { item in
                NavigationLink {
                    VocabularyDetailView(item: item)
                } label: {
                    VocabularyRowView(item: item)
                }
            }
            .onDelete { offsets in
                viewModel.delete(at: offsets, from: filteredItems, modelContext: modelContext)
            }
        }
        .listStyle(.plain)
    }
}

private struct VocabularyRowView: View {
    let item: VocabularyItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(item.word)
                    .font(.headline)
                if let partOfSpeech = item.partOfSpeech, !partOfSpeech.isEmpty {
                    Text(partOfSpeech)
                        .font(.caption)
                        .italic()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }

            if !item.shortDefinition.isEmpty {
                Text(item.shortDefinition)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 4) {
                Text(item.createdAt, format: .relative(presentation: .named))
                if let sourceNoteTitle = item.sourceNoteTitle, !sourceNoteTitle.isEmpty {
                    Text("·")
                    Text("from \(sourceNoteTitle)")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview("Vocabulary list") {
    VocabularyListView()
        .modelContainer(SampleDictionary.previewContainer())
}
#endif
