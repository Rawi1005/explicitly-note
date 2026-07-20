import SwiftUI

/// Rounded card used for a note in the library list.
struct NoteCardView: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.title)
                .font(.headline)
                .lineLimit(1)

            if !note.plainTextPreview.isEmpty {
                Text(note.plainTextPreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                Text(note.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if let folderName = note.folderName, !folderName.isEmpty {
                    Text(folderName)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

#if DEBUG
#Preview(traits: .sizeThatFitsLayout) {
    NoteCardView(
        note: Note(
            title: "Physics Lecture",
            plainTextPreview: "Wave-particle duality describes how every quantum object behaves like both a particle and a wave. In the double-slit experiment, single electrons build up an interference pattern.",
            folderName: "Science"
        )
    )
    .padding()
    .background(Color(.systemGroupedBackground))
    .modelContainer(SampleNotes.previewContainer)
}
#endif
