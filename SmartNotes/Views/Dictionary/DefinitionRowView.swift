import SwiftUI

/// One numbered definition: text, optional quoted example, and optional
/// synonym/antonym chips.
struct DefinitionRowView: View {
    let number: Int
    let definition: WordDefinition

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(definition.definition ?? "")
                    .font(.body)

                if let example = definition.example, !example.isEmpty {
                    Text("\u{201C}\(example)\u{201D}")
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(.quaternary)
                                .frame(width: 2)
                        }
                }

                if let synonyms = definition.synonyms, !synonyms.isEmpty {
                    TermChipsView(title: "Synonyms", terms: synonyms, tint: .blue)
                }
                if let antonyms = definition.antonyms, !antonyms.isEmpty {
                    TermChipsView(title: "Antonyms", terms: antonyms, tint: .orange)
                }
            }
        }
    }
}

// MARK: - Chips

/// A labeled group of wrapping capsule chips, shared by definition rows
/// and meaning sections.
struct TermChipsView: View {
    let title: String
    let terms: [String]
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            WrappingChipsLayout(spacing: 6) {
                ForEach(terms, id: \.self) { term in
                    Text(term)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.12), in: Capsule())
                        .foregroundStyle(tint)
                }
            }
        }
    }
}

/// Minimal left-to-right flow layout that wraps chips onto new rows.
struct WrappingChipsLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        let width = maxWidth.isFinite ? maxWidth : usedWidth
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#if DEBUG
#Preview("Definition row", traits: .sizeThatFitsLayout) {
    DefinitionRowView(
        number: 1,
        definition: SampleDictionary.drinkEntries[0].meanings?[0].definitions?[0]
            ?? WordDefinition(definition: "A beverage.", example: nil, synonyms: nil, antonyms: nil)
    )
    .padding()
}
#endif
