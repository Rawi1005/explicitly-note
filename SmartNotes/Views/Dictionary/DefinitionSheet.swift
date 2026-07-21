import SwiftData
import SwiftUI

/// Extra context and callbacks provided when the definition sheet is opened
/// from a notebook page (rather than a note), enabling Add to Slide underlines
/// and vocabulary provenance.
struct NotebookDefinitionContext {
    let notebookID: UUID
    let notebookTitle: String
    let pageID: UUID?
    let pageNumber: Int?
    /// True when the tapped word's on-page location is known (underlining possible).
    let canAnnotate: Bool
    /// Vocab save finished; the word also gets underlined on the page.
    /// `newlyAdded` is false for duplicates.
    let onVocabResult: (_ newlyAdded: Bool, _ colorHex: String, _ definition: String) -> Void
}

/// Bottom sheet showing dictionary definitions for a text selection,
/// with actions to insert the definition into the note, save the word
/// to vocabulary, or ask for an AI explanation.
struct DefinitionSheet: View {
    let request: DefinitionLookupRequest
    var onInsertDefinition: ((String) -> Void)? = nil
    var notebookContext: NotebookDefinitionContext? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = DictionaryLookupViewModel()
    @State private var showingAIExplanation = false
    @AppStorage("smartnotes.underline.colorHex") private var underlineColorHex = "#0A84FF"

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                loadingView
            case .failed(let error):
                errorView(error)
            case .dictionary(let entries, let source):
                loadedView(entries: entries, source: source)
            case .notInDictionary(let word):
                notInDictionaryView(word: word)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .accessibilityLabel("Close")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            viewModel.configure(modelContext: modelContext)
            await viewModel.lookup(raw: request.rawSelection)
        }
        .onDisappear {
            viewModel.audioPlayer.stop()
        }
        .sheet(isPresented: $showingAIExplanation) {
            AIExplanationSheet(
                selectedText: request.rawSelection,
                context: request.context,
                onInsert: onInsertDefinition
            )
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Looking up \u{201C}\(request.rawSelection.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error

    private func errorView(_ error: DictionaryError) -> some View {
        ContentUnavailableView {
            Label(errorTitle(for: error), systemImage: errorSymbol(for: error))
        } description: {
            Text(error.errorDescription ?? "Something went wrong.")
        } actions: {
            if isRetryable(error) {
                Button("Retry") {
                    Task { await viewModel.lookup(raw: request.rawSelection) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func errorTitle(for error: DictionaryError) -> String {
        switch error {
        case .wordNotFound: "No Definition Found"
        case .noConnection: "You're Offline"
        case .emptySelection, .invalidSelection: "Can't Look That Up"
        default: "Lookup Failed"
        }
    }

    private func errorSymbol(for error: DictionaryError) -> String {
        switch error {
        case .wordNotFound: "character.book.closed"
        case .noConnection: "wifi.slash"
        case .emptySelection, .invalidSelection, .invalidURL: "text.magnifyingglass"
        case .serverError, .invalidResponse, .decodingFailed: "exclamationmark.icloud"
        case .network: "network.slash"
        }
    }

    private func isRetryable(_ error: DictionaryError) -> Bool {
        switch error {
        case .noConnection, .network, .serverError, .invalidResponse, .decodingFailed: true
        case .emptySelection, .invalidSelection, .invalidURL, .wordNotFound: false
        }
    }

    // MARK: - Loaded

    private func loadedView(entries: [DictionaryEntry], source: DefinitionSource) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sourceLabel(source)
                if let first = entries.first {
                    header(for: first)
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    ForEach(Array((entry.meanings ?? []).enumerated()), id: \.offset) { _, meaning in
                        MeaningSectionView(meaning: meaning)
                    }
                }
                footer(for: entries, source: source)
            }
            .padding(.horizontal)
            .padding(.top, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            actionBar(entries: entries)
        }
    }

    /// Small "Offline dictionary" / "Dictionary + online" caption so the
    /// user always knows where the shown definition came from.
    private func sourceLabel(_ source: DefinitionSource) -> some View {
        Label(source.label, systemImage: source == .offlineDictionary ? "checkmark.icloud" : "icloud")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Not in dictionary

    private func notInDictionaryView(word: String) -> some View {
        ContentUnavailableView {
            Label("Not in the dictionary", systemImage: "sparkles")
        } description: {
            Text("\u{201C}\(word)\u{201D} isn't in the offline dictionary — it may be a technical term or acronym.")
        } actions: {
            Button {
                showingAIExplanation = true
            } label: {
                Label("Explain with AI", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func header(for entry: DictionaryEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.word)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                if let phonetic = entry.displayPhonetic {
                    Text(phonetic)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            speakerButton(for: entry)
        }
    }

    private func speakerButton(for entry: DictionaryEntry) -> some View {
        Group {
            if let url = entry.bestAudioURL {
                Button {
                    // AudioPlayerService guarantees only one stream at a time.
                    viewModel.audioPlayer.toggle(url: url)
                } label: {
                    Image(systemName: isPlayingAudio(url) ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(.title2)
                }
                .accessibilityLabel(isPlayingAudio(url) ? "Stop pronunciation" : "Play pronunciation")
            } else {
                Image(systemName: "speaker.slash")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("No pronunciation audio available")
            }
        }
    }

    private func isPlayingAudio(_ url: URL) -> Bool {
        viewModel.audioPlayer.isPlaying && viewModel.audioPlayer.currentURL == url
    }

    private func footer(for entries: [DictionaryEntry], source: DefinitionSource) -> some View {
        // De-duplicate source URLs across entries, keeping order. These only
        // appear once an online enrichment has run.
        let urls = entries.flatMap { $0.sourceUrls ?? [] }
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0).inserted }

        // Credit the real source: definitions always come from the bundled
        // offline dictionary; only audio/links are added from the API online.
        let credit = source == .offlineDictionary
            ? "Definitions from the bundled offline dictionary."
            : "Definitions from the bundled offline dictionary · pronunciation & links from DictionaryAPI.dev."

        return VStack(alignment: .leading, spacing: 4) {
            Text(credit)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(unique, id: \.self) { urlString in
                if let url = URL(string: urlString) {
                    Link(urlString, destination: url)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Action bar

    @ViewBuilder
    private func actionBar(entries: [DictionaryEntry]) -> some View {
        if let context = notebookContext {
            notebookActionBar(entries: entries, context: context)
        } else {
            noteActionBar(entries: entries)
        }
    }

    /// Notebook flow: clean text buttons. Add to Vocab both saves the word
    /// and underlines it on the page in the chosen color.
    private func notebookActionBar(
        entries: [DictionaryEntry],
        context: NotebookDefinitionContext
    ) -> some View {
        VStack(spacing: 12) {
            if context.canAnnotate {
                HStack(spacing: 10) {
                    Text("Underline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(underlineColorPresets, id: \.hex) { preset in
                        underlineSwatch(preset)
                    }
                    ColorPicker(
                        "Custom underline color",
                        selection: underlineColorBinding,
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    Spacer()
                }
            }

            HStack(spacing: 12) {
                Button("Add to Vocab") {
                    addToVocab(entries: entries, context: context)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                Button("Explain with AI") {
                    showingAIExplanation = true
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(.bar)
    }

    private func addToVocab(entries: [DictionaryEntry], context: NotebookDefinitionContext) {
        let definition = viewModel.shortDefinitionText(from: entries)
        let newlyAdded = !viewModel.isSaved
        if newlyAdded {
            viewModel.saveToVocabulary(
                entries: entries,
                sourceNoteTitle: context.notebookTitle,
                details: VocabularySaveDetails(
                    sourceNotebookID: context.notebookID,
                    sourcePageID: context.pageID,
                    pageNumber: context.pageNumber,
                    underlineColorHex: underlineColorHex
                )
            )
        }
        context.onVocabResult(newlyAdded, underlineColorHex, definition)
        dismiss()
    }

    private func underlineSwatch(_ preset: (name: String, hex: String)) -> some View {
        let isSelected = underlineColorHex.uppercased() == preset.hex.uppercased()
        return Button {
            underlineColorHex = preset.hex
        } label: {
            Circle()
                .fill(Color(uiColor: UIColor(hexString: preset.hex)))
                .frame(width: 22, height: 22)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(Color.primary.opacity(0.6), lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name) underline")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var underlineColorBinding: Binding<Color> {
        Binding(
            get: { Color(uiColor: UIColor(hexString: underlineColorHex)) },
            set: { underlineColorHex = UIColor($0).hexString }
        )
    }

    /// Original note flow, unchanged.
    private func noteActionBar(entries: [DictionaryEntry]) -> some View {
        VStack(spacing: 10) {
            // The signature feature: drop the definition straight into the note.
            if onInsertDefinition != nil, let text = viewModel.insertText(from: entries) {
                Button {
                    onInsertDefinition?(text)
                    dismiss()
                } label: {
                    Label("Insert into Note", systemImage: "text.insert")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.saveToVocabulary(entries: entries, sourceNoteTitle: request.sourceNoteTitle)
                } label: {
                    Label(
                        viewModel.isSaved ? "Saved" : "Add to Vocabulary",
                        systemImage: viewModel.isSaved ? "checkmark" : "character.book.closed"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSaved)

                Button {
                    showingAIExplanation = true
                } label: {
                    Label("Explain with AI", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.bar)
    }
}

#if DEBUG
#Preview("Definition sheet") {
    // The preview container pre-caches the "drink" response,
    // so the sheet renders without touching the network.
    Color(.systemBackground)
        .sheet(isPresented: .constant(true)) {
            DefinitionSheet(
                request: SampleDictionary.drinkRequest,
                onInsertDefinition: { _ in }
            )
        }
        .modelContainer(SampleDictionary.previewContainer())
}
#endif
