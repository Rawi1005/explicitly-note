import SwiftUI

struct Note: Identifiable, Hashable {
    let id = UUID()
    var title: String
}

struct ContentView: View {
    @State private var notes = [
        Note(title: "Welcome to ExplicitlyNote"),
        Note(title: "Tap + to add a note")
    ]
    @State private var selectedNote: Note?

    var body: some View {
        NavigationSplitView {
            List(notes, selection: $selectedNote) { note in
                Text(note.title)
                    .tag(note)
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: addNote) {
                        Label("Add Note", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let selectedNote {
                Text(selectedNote.title)
                    .font(.title)
                    .padding()
            } else {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "note.text",
                    description: Text("Select a note from the list, or create a new one.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func addNote() {
        let note = Note(title: "New Note")
        notes.append(note)
        selectedNote = note
    }
}

#Preview {
    ContentView()
}
