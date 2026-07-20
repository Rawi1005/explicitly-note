#if DEBUG
import Foundation
import SwiftData
import UIKit

/// In-memory SwiftData container and realistic sample notes for
/// #Preview blocks. Compiled only in DEBUG builds.
@MainActor
enum SampleNotes {
    static let previewContainer: ModelContainer = {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            let container = try ModelContainer(
                for: Note.self, CachedDictionaryEntry.self, VocabularyItem.self,
                configurations: configuration
            )
            for note in makeNotes() {
                container.mainContext.insert(note)
            }
            try container.mainContext.save()
            return container
        } catch {
            fatalError("Failed to build preview container: \(error)")
        }
    }()

    /// First sample note in the container, for editor previews.
    static func firstNote(in container: ModelContainer) -> Note {
        var descriptor = FetchDescriptor<Note>(sortBy: [SortDescriptor(\.title)])
        descriptor.fetchLimit = 1
        if let note = try? container.mainContext.fetch(descriptor).first {
            return note
        }
        let fallback = Note(title: "Untitled Note")
        container.mainContext.insert(fallback)
        return fallback
    }

    static func makeNotes() -> [Note] {
        [
            note(
                title: "Physics Lecture",
                folder: "Science",
                paragraph: "Wave-particle duality describes how every quantum object behaves like both a particle and a wave. In the double-slit experiment, single electrons fired at a barrier build up an interference pattern over time, which only makes sense if each electron passes through both slits as a wave. Measuring which slit the electron uses collapses the wavefunction and destroys the pattern, a result formalized by the Copenhagen interpretation."
            ),
            note(
                title: "Organic Chemistry Vocabulary",
                folder: "Science",
                paragraph: "A nucleophile is an electron-rich species that donates an electron pair to form a covalent bond, while an electrophile accepts one. Substitution reactions at saturated carbons follow either the SN1 pathway, which proceeds through a carbocation intermediate, or the concerted SN2 pathway, whose rate depends on both reactants. Steric hindrance around the reactive carbon usually decides which mechanism dominates."
            ),
            note(
                title: "Japanese Study Notes",
                folder: "Languages",
                paragraph: "Japanese verbs conjugate by attaching endings to one of two stems, so learning the dictionary form and the -masu stem covers most patterns. Particles such as wa, ga, and o mark the topic, subject, and object instead of relying on word order. Keigo, the system of honorific speech, changes both vocabulary and verb forms depending on the social relationship between speakers."
            )
        ]
    }

    private static func note(title: String, folder: String, paragraph: String) -> Note {
        Note(
            title: title,
            contentData: rtfData(for: paragraph),
            plainTextPreview: String(paragraph.prefix(200)),
            folderName: folder
        )
    }

    private static func rtfData(for text: String) -> Data? {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label
        ])
        return try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }
}
#endif
