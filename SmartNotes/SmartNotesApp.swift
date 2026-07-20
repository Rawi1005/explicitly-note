import SwiftUI
import SwiftData

@main
struct SmartNotesApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(for: [
            Note.self,
            CachedDictionaryEntry.self,
            VocabularyItem.self
        ])
    }
}

struct RootTabView: View {
    var body: some View {
        TabView {
            NotesLibraryView()
                .tabItem { Label("Notes", systemImage: "note.text") }

            VocabularyListView()
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

#Preview {
    RootTabView()
        .modelContainer(for: [Note.self, CachedDictionaryEntry.self, VocabularyItem.self], inMemory: true)
}
