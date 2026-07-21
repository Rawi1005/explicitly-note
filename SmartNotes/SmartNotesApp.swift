import SwiftUI
import SwiftData

@main
struct SmartNotesApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
        .modelContainer(for: [
            Notebook.self,
            NotebookPage.self,
            NotebookFolder.self,
            Note.self,
            CachedDictionaryEntry.self,
            VocabularyItem.self
        ])
    }
}

#Preview {
    NotebookLibraryView()
        .modelContainer(for: [Notebook.self, NotebookPage.self], inMemory: true)
}
