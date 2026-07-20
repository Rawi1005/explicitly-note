import SwiftUI
import SwiftData

struct NoteEditorView: View {
    let note: Note
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NoteEditorContent(viewModel: NoteEditorViewModel(note: note, modelContext: modelContext))
            // Force fresh @State (and so a fresh view model) when the
            // iPad sidebar switches this detail view to a different note.
            .id(note.id)
    }
}

private struct NoteEditorContent: View {
    @State private var viewModel: NoteEditorViewModel

    init(viewModel: NoteEditorViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: $viewModel.title, axis: .vertical)
                .font(.largeTitle.bold())
                .textFieldStyle(.plain)
                .padding(.horizontal)
                .padding(.top, 8)

            saveStatusLine
                .padding(.horizontal)
                .padding(.top, 2)

            RichTextEditor(
                attributedText: $viewModel.attributedText,
                selectedRange: $viewModel.selectedRange,
                commands: viewModel.commands,
                onDefine: { viewModel.defineSelection() },
                onExplain: { viewModel.explainSelection() },
                onAddToVocabulary: { viewModel.addSelectionToVocabulary() }
            )
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar }
        .onChange(of: viewModel.title) { viewModel.scheduleAutosave() }
        .onChange(of: viewModel.attributedText) { viewModel.scheduleAutosave() }
        .onDisappear { viewModel.saveNow() }
        .sheet(item: $viewModel.definitionRequest) { request in
            DefinitionSheet(
                request: request,
                onInsertDefinition: { definition in
                    viewModel.insertDefinition(definition)
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $viewModel.aiExplanationRequest) { request in
            AIExplanationSheet(selectedText: request.selectedText, context: request.context)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Save status

    private var saveStatusLine: some View {
        HStack(spacing: 4) {
            switch viewModel.saveStatus {
            case .idle:
                EmptyView()
            case .saving:
                Text("Saving…")
            case .saved(let date):
                Image(systemName: "checkmark.circle")
                Text("Saved at \(date.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        // Reserve the line so the layout doesn't jump on first save.
        .frame(minHeight: 16, alignment: .leading)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                viewModel.defineSelection()
            } label: {
                Label("Look Up Selected Text", systemImage: "book")
            }
            .disabled(!viewModel.hasSelection)
        }
        ToolbarItemGroup(placement: .keyboard) {
            Button {
                viewModel.commands.toggleBold()
            } label: {
                Label("Bold", systemImage: "bold")
            }
            Button {
                viewModel.commands.toggleItalic()
            } label: {
                Label("Italic", systemImage: "italic")
            }
            Button {
                viewModel.commands.toggleUnderline()
            } label: {
                Label("Underline", systemImage: "underline")
            }
            Button {
                viewModel.commands.toggleHeading()
            } label: {
                Label("Heading", systemImage: "textformat.size")
            }
            Button {
                viewModel.commands.toggleBulletList()
            } label: {
                Label("Bullet List", systemImage: "list.bullet")
            }
            Spacer()
        }
    }
}

#if DEBUG
#Preview {
    let container = SampleNotes.previewContainer
    return NavigationStack {
        NoteEditorView(note: SampleNotes.firstNote(in: container))
    }
    .modelContainer(container)
}
#endif
