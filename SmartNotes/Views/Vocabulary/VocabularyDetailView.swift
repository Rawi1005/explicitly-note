import SwiftData
import SwiftUI

/// Full details for one saved vocabulary word, with a shortcut to look
/// the word up again in the definition sheet.
struct VocabularyDetailView: View {
    let item: VocabularyItem

    @State private var lookupRequest: DefinitionLookupRequest?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.word)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    if let partOfSpeech = item.partOfSpeech, !partOfSpeech.isEmpty {
                        Text(partOfSpeech)
                            .font(.subheadline)
                            .italic()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .padding(.vertical, 4)
            }

            if !item.shortDefinition.isEmpty {
                Section("Definition") {
                    Text(item.shortDefinition)
                }
            }

            Section("Details") {
                LabeledContent("Saved") {
                    Text(item.createdAt, format: .dateTime.day().month().year())
                }
                if let sourceNoteTitle = item.sourceNoteTitle, !sourceNoteTitle.isEmpty {
                    LabeledContent("From note", value: sourceNoteTitle)
                }
            }

            Section {
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
        .sheet(item: $lookupRequest) { request in
            DefinitionSheet(request: request)
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
