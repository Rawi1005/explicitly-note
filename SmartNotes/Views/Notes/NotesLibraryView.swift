import SwiftUI
import SwiftData

struct NotesLibraryView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NotesLibraryContent(viewModel: NotesLibraryViewModel(modelContext: modelContext))
    }
}

/// Split out so the view model can be built from the environment's model
/// context; `@State(initialValue:)` keeps the first instance alive across
/// re-renders of the outer view.
private struct NotesLibraryContent: View {
    @State private var viewModel: NotesLibraryViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @State private var selectedNote: Note?
    @State private var path: [Note] = []
    @State private var notePendingDeletion: Note?

    init(viewModel: NotesLibraryViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    private var displayedNotes: [Note] {
        viewModel.displayNotes(from: notes)
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                libraryChrome(sidebarList)
            } detail: {
                if let selectedNote {
                    NoteEditorView(note: selectedNote)
                } else {
                    ContentUnavailableView(
                        "Select a Note",
                        systemImage: "note.text",
                        description: Text("Choose a note from the list or create a new one.")
                    )
                }
            }
        } else {
            NavigationStack(path: $path) {
                libraryChrome(stackList)
                    .navigationDestination(for: Note.self) { note in
                        NoteEditorView(note: note)
                    }
            }
        }
    }

    // MARK: - Lists

    private var sidebarList: some View {
        List(selection: $selectedNote) {
            ForEach(displayedNotes) { note in
                NoteCardView(note: note)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: selectedNote == note ? 2 : 0)
                    )
                    .tag(note)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions { deleteButton(for: note) }
                    .contextMenu { deleteButton(for: note) }
            }
        }
    }

    private var stackList: some View {
        List {
            ForEach(displayedNotes) { note in
                // Hidden NavigationLink keeps the tap target and
                // accessibility while hiding the chevron on the card.
                ZStack {
                    NavigationLink(value: note) { EmptyView() }
                        .opacity(0)
                    NoteCardView(note: note)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions { deleteButton(for: note) }
                .contextMenu { deleteButton(for: note) }
            }
        }
    }

    private func libraryChrome(_ list: some View) -> some View {
        list
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .searchable(text: $viewModel.searchText, prompt: "Search notes")
            .toolbar { libraryToolbar }
            .overlay { emptyState }
            .navigationTitle("Notes")
            .confirmationDialog(
                "Delete this note?",
                isPresented: noteDeletionBinding,
                titleVisibility: .visible
            ) {
                Button("Delete Note", role: .destructive) {
                    if let notePendingDeletion {
                        delete(notePendingDeletion)
                    }
                    notePendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    notePendingDeletion = nil
                }
            } message: {
                Text("The note and its content will be removed. This action cannot be undone.")
            }
    }

    private var noteDeletionBinding: Binding<Bool> {
        Binding(
            get: { notePendingDeletion != nil },
            set: { if !$0 { notePendingDeletion = nil } }
        )
    }

    // MARK: - Toolbar and actions

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort by", selection: $viewModel.sortOrder) {
                    ForEach(NoteSortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                createNote()
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
        }
    }

    private func deleteButton(for note: Note) -> some View {
        Button(role: .destructive) {
            notePendingDeletion = note
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func createNote() {
        let note = viewModel.createNote()
        if horizontalSizeClass == .regular {
            selectedNote = note
        } else {
            path.append(note)
        }
    }

    private func delete(_ note: Note) {
        if selectedNote == note {
            selectedNote = nil
        }
        path.removeAll { $0 == note }
        viewModel.delete(note)
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        if displayedNotes.isEmpty {
            if viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label("No Notes", systemImage: "note.text")
                } description: {
                    Text("Create your first note to get started.")
                } actions: {
                    Button("New Note") { createNote() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView.search(text: viewModel.searchText)
            }
        }
    }
}

#if DEBUG
#Preview {
    NotesLibraryView()
        .modelContainer(SampleNotes.previewContainer)
}
#endif
