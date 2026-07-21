import SwiftUI

/// App-wide navigation coordinator: switches tabs and routes "open this
/// notebook at this page" requests (e.g. from a vocabulary entry).
@MainActor
final class AppNavigator: ObservableObject {
    static let shared = AppNavigator()

    enum Tab: Hashable {
        case notebooks
        case notes
        case vocabulary
        case settings
    }

    struct NotebookOpenRequest: Equatable {
        let notebookID: UUID
        let pageID: UUID?
    }

    @Published var selectedTab: Tab = .notebooks
    @Published var pendingNotebookOpen: NotebookOpenRequest?

    private init() {}

    func openNotebook(_ notebookID: UUID, pageID: UUID?) {
        selectedTab = .notebooks
        pendingNotebookOpen = NotebookOpenRequest(notebookID: notebookID, pageID: pageID)
    }

    /// The editor calls this on appear to pick up a requested jump page.
    func consumePendingPage(for notebookID: UUID) -> UUID? {
        guard let pending = pendingNotebookOpen, pending.notebookID == notebookID else {
            return nil
        }
        pendingNotebookOpen = nil
        return pending.pageID
    }
}

/// Root navigation: Notebooks (PDF + handwriting), Notes, Vocabulary, Settings.
struct MainTabView: View {
    @ObservedObject private var navigator = AppNavigator.shared

    var body: some View {
        TabView(selection: $navigator.selectedTab) {
            NotebookLibraryView()
                .tabItem {
                    Label("Notebooks", systemImage: "book.pages")
                }
                .tag(AppNavigator.Tab.notebooks)

            NotesLibraryView()
                .tabItem {
                    Label("Notes", systemImage: "note.text")
                }
                .tag(AppNavigator.Tab.notes)

            VocabularyListView()
                .tabItem {
                    Label("Vocabulary", systemImage: "character.book.closed")
                }
                .tag(AppNavigator.Tab.vocabulary)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppNavigator.Tab.settings)
        }
    }
}
