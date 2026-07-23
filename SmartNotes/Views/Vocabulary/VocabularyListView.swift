import SwiftData
import SwiftUI

/// Preset study lists offered when filing a word, alongside any custom
/// lists the user has already created.
let vocabularyListPresets = ["SAT", "School", "Biology", "Japanese", "Difficult words"]

private enum VocabularySortOrder: String, CaseIterable, Identifiable {
    case dateAdded
    case alphabetical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateAdded: "Date added"
        case .alphabetical: "Word A–Z"
        }
    }
}

/// The Vocabulary tab: every word saved with Add to Vocab, searchable,
/// sortable, filterable, and groupable into custom study lists.
struct VocabularyListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VocabularyItem.createdAt, order: .reverse) private var items: [VocabularyItem]
    @State private var viewModel = VocabularyViewModel()
    @State private var sortOrder: VocabularySortOrder = .dateAdded
    /// nil = all lists; "" = unfiled only; otherwise a specific list name.
    @State private var listFilter: String?
    @State private var itemPendingList: VocabularyItem?
    @State private var newListName = ""
    @State private var itemPendingDeletion: VocabularyItem?

    private var existingLists: [String] {
        var seen = Set<String>()
        return items.compactMap(\.listName).filter { seen.insert($0).inserted }.sorted()
    }

    private var filteredItems: [VocabularyItem] {
        var result = viewModel.filtered(items)
        if let listFilter {
            result = listFilter.isEmpty
                ? result.filter { $0.listName == nil }
                : result.filter { $0.listName == listFilter }
        }
        switch sortOrder {
        case .dateAdded:
            return result.sorted { $0.createdAt > $1.createdAt }
        case .alphabetical:
            return result.sorted {
                $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState
                } else if filteredItems.isEmpty {
                    filteredEmptyState
                } else {
                    list
                }
            }
            .navigationTitle("Vocabulary")
            .searchable(text: $viewModel.searchText, prompt: "Search words and definitions")
            .toolbar { listToolbar }
            .alert("New List", isPresented: newListBinding) {
                TextField("List name", text: $newListName)
                Button("Create") {
                    let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let item = itemPendingList, !name.isEmpty {
                        item.listName = name
                        try? modelContext.save()
                    }
                    itemPendingList = nil
                    newListName = ""
                }
                Button("Cancel", role: .cancel) {
                    itemPendingList = nil
                    newListName = ""
                }
            }
            .alert("Delete this word?", isPresented: deletionBinding) {
                Button("Cancel", role: .cancel) { itemPendingDeletion = nil }
                Button("Delete", role: .destructive) {
                    if let item = itemPendingDeletion {
                        withAnimation(.snappy(duration: 0.22)) {
                            modelContext.delete(item)
                            try? modelContext.save()
                        }
                    }
                    itemPendingDeletion = nil
                }
            } message: {
                Text("The word and its saved definition will be removed. This action cannot be undone.")
            }
        }
    }

    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("List", selection: $listFilter) {
                    Text("All Lists").tag(String?.none)
                    Text("Unfiled").tag(String?.some(""))
                    ForEach(existingLists, id: \.self) { list in
                        Text(list).tag(String?.some(list))
                    }
                }
            } label: {
                Label(
                    "Filter",
                    systemImage: listFilter == nil
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }

            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(VocabularySortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Saved Words", systemImage: "character.book.closed")
        } description: {
            Text("Tap a word in a PDF notebook or select text in a note, then choose \u{201C}Add to Vocab\u{201D} to build your word list.")
        }
    }

    @ViewBuilder
    private var filteredEmptyState: some View {
        if !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: viewModel.searchText)
        } else {
            ContentUnavailableView(
                listFilter?.isEmpty == true ? "No Unfiled Words" : "No Words in This List",
                systemImage: "tray",
                description: Text("Choose another list or move a saved word here.")
            )
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
                .swipeActions {
                    Button(role: .destructive) {
                        itemPendingDeletion = item
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    listAssignmentMenu(for: item)
                    Button(role: .destructive) {
                        itemPendingDeletion = item
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func listAssignmentMenu(for item: VocabularyItem) -> some View {
        Menu {
            let options = (vocabularyListPresets + existingLists).reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            ForEach(options, id: \.self) { list in
                Button {
                    item.listName = list
                    try? modelContext.save()
                } label: {
                    if item.listName == list {
                        Label(list, systemImage: "checkmark")
                    } else {
                        Text(list)
                    }
                }
            }
            Divider()
            Button("New List…") {
                newListName = ""
                itemPendingList = item
            }
            if item.listName != nil {
                Button("Remove from List") {
                    item.listName = nil
                    try? modelContext.save()
                }
            }
        } label: {
            Label("Move to List", systemImage: "folder")
        }
    }

    private var newListBinding: Binding<Bool> {
        Binding(
            get: { itemPendingList != nil },
            set: { if !$0 { itemPendingList = nil } }
        )
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { itemPendingDeletion != nil },
            set: { if !$0 { itemPendingDeletion = nil } }
        )
    }
}

private struct VocabularyRowView: View {
    let item: VocabularyItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let colorHex = item.underlineColorHex {
                    Circle()
                        .fill(Color(uiColor: UIColor(hexString: colorHex)))
                        .frame(width: 9, height: 9)
                }
                Text(item.word)
                    .font(.headline)
                if let phonetic = item.phonetic, !phonetic.isEmpty {
                    Text(phonetic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let partOfSpeech = item.partOfSpeech, !partOfSpeech.isEmpty {
                    Text(partOfSpeech)
                        .font(.caption)
                        .italic()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                if let list = item.listName {
                    Text(list)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.accentColor)
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
                    if let pageNumber = item.pageNumber {
                        Text("\(sourceNoteTitle), p. \(pageNumber)")
                            .lineLimit(1)
                    } else {
                        Text("from \(sourceNoteTitle)")
                            .lineLimit(1)
                    }
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
