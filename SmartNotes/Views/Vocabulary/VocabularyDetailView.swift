import SwiftData
import SwiftUI

/// Full details for one saved vocabulary word: definition, pronunciation,
/// example, translation, provenance (with a jump to the source notebook
/// page), study list assignment, and inline editing.
struct VocabularyDetailView: View {
    @Bindable var item: VocabularyItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allItems: [VocabularyItem]
    @State private var lookupRequest: DefinitionLookupRequest?
    @State private var showingEditSheet = false
    @State private var newListName = ""
    @State private var showingNewListAlert = false

    private var existingLists: [String] {
        var seen = Set<String>()
        return allItems.compactMap(\.listName).filter { seen.insert($0).inserted }.sorted()
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        if let colorHex = item.underlineColorHex {
                            Circle()
                                .fill(Color(uiColor: UIColor(hexString: colorHex)))
                                .frame(width: 12, height: 12)
                        }
                        Text(item.word)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    }
                    HStack(spacing: 8) {
                        if let phonetic = item.phonetic, !phonetic.isEmpty {
                            Text(phonetic)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if let partOfSpeech = item.partOfSpeech, !partOfSpeech.isEmpty {
                            Text(partOfSpeech)
                                .font(.subheadline)
                                .italic()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if !item.shortDefinition.isEmpty {
                Section("Definition") {
                    Text(item.shortDefinition)
                }
            }

            if let example = item.exampleSentence, !example.isEmpty {
                Section("Example") {
                    Text(example)
                        .italic()
                }
            }

            if let translation = item.translation, !translation.isEmpty {
                Section("Translation") {
                    Text(translation)
                }
            }

            Section("Study List") {
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
                        showingNewListAlert = true
                    }
                    if item.listName != nil {
                        Button("Remove from List") {
                            item.listName = nil
                            try? modelContext.save()
                        }
                    }
                } label: {
                    LabeledContent("List") {
                        Text(item.listName ?? "None")
                    }
                }
            }

            Section("Details") {
                LabeledContent("Saved") {
                    Text(item.createdAt, format: .dateTime.day().month().year())
                }
                if let sourceNoteTitle = item.sourceNoteTitle, !sourceNoteTitle.isEmpty {
                    LabeledContent("Source", value: sourceNoteTitle)
                }
                if let pageNumber = item.pageNumber {
                    LabeledContent("Page", value: "\(pageNumber)")
                }
            }

            Section {
                if let notebookID = item.sourceNotebookID {
                    Button {
                        AppNavigator.shared.openNotebook(notebookID, pageID: item.sourcePageID)
                        dismiss()
                    } label: {
                        Label("Open in Notebook", systemImage: "book.pages")
                    }
                }

                Button {
                    lookupRequest = DefinitionLookupRequest(
                        rawSelection: item.word,
                        context: "",
                        sourceNoteTitle: item.sourceNoteTitle
                    )
                } label: {
                    Label("Look up again", systemImage: "magnifyingglass")
                }
            }
        }
        .navigationTitle(item.word)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showingEditSheet = true }
            }
        }
        .sheet(item: $lookupRequest) { request in
            DefinitionSheet(request: request)
        }
        .sheet(isPresented: $showingEditSheet) {
            VocabularyEditSheet(item: item)
        }
        .alert("New List", isPresented: $showingNewListAlert) {
            TextField("List name", text: $newListName)
            Button("Create") {
                let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    item.listName = name
                    try? modelContext.save()
                }
                newListName = ""
            }
            Button("Cancel", role: .cancel) { newListName = "" }
        }
    }
}

/// Form for editing the stored fields of a vocabulary word.
private struct VocabularyEditSheet: View {
    @Bindable var item: VocabularyItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var definition = ""
    @State private var phonetic = ""
    @State private var example = ""
    @State private var translation = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Definition") {
                    TextEditor(text: $definition)
                        .frame(minHeight: 80)
                }
                Section("Pronunciation") {
                    TextField("e.g. /ˈwɜːd/", text: $phonetic)
                }
                Section("Example Sentence") {
                    TextField("Example", text: $example, axis: .vertical)
                }
                Section("Translation") {
                    TextField("Translation", text: $translation, axis: .vertical)
                }
            }
            .navigationTitle("Edit \(item.word)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        item.shortDefinition = definition.trimmingCharacters(in: .whitespacesAndNewlines)
                        item.phonetic = phonetic.isEmpty ? nil : phonetic
                        item.exampleSentence = example.isEmpty ? nil : example
                        item.translation = translation.isEmpty ? nil : translation
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
            .onAppear {
                definition = item.shortDefinition
                phonetic = item.phonetic ?? ""
                example = item.exampleSentence ?? ""
                translation = item.translation ?? ""
            }
        }
    }
}

#if DEBUG
#Preview("Vocabulary detail") {
    NavigationStack {
        VocabularyDetailView(item: SampleDictionary.sampleVocabulary[0])
    }
    .modelContainer(SampleDictionary.previewContainer())
}
#endif
