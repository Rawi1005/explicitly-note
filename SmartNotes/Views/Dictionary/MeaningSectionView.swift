import SwiftUI

/// One part-of-speech section: capsule header, up to three numbered
/// definitions with a per-section "Show more" expander, and any
/// meaning-level synonym/antonym chips.
struct MeaningSectionView: View {
    let meaning: Meaning

    @State private var isExpanded = false

    private static let collapsedLimit = 3

    private var definitions: [WordDefinition] {
        (meaning.definitions ?? []).filter { !($0.definition ?? "").isEmpty }
    }

    private var visibleDefinitions: [WordDefinition] {
        isExpanded ? definitions : Array(definitions.prefix(Self.collapsedLimit))
    }

    private var hiddenCount: Int {
        max(0, definitions.count - Self.collapsedLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let partOfSpeech = meaning.partOfSpeech, !partOfSpeech.isEmpty {
                Text(partOfSpeech)
                    .font(.subheadline.weight(.medium))
                    .italic()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            ForEach(Array(visibleDefinitions.enumerated()), id: \.offset) { index, definition in
                DefinitionRowView(number: index + 1, definition: definition)
            }

            if !isExpanded, hiddenCount > 0 {
                Button {
                    withAnimation { isExpanded = true }
                } label: {
                    Label("Show more (\(hiddenCount))", systemImage: "chevron.down")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }

            if let synonyms = meaning.synonyms, !synonyms.isEmpty {
                TermChipsView(title: "Synonyms", terms: synonyms, tint: .blue)
            }
            if let antonyms = meaning.antonyms, !antonyms.isEmpty {
                TermChipsView(title: "Antonyms", terms: antonyms, tint: .orange)
            }
        }
    }
}

#if DEBUG
#Preview("Meaning section", traits: .sizeThatFitsLayout) {
    MeaningSectionView(
        meaning: SampleDictionary.drinkEntries[0].meanings?[1]
            ?? Meaning(partOfSpeech: "verb", definitions: nil, synonyms: nil, antonyms: nil)
    )
    .padding()
}
#endif
