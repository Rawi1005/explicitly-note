import SwiftData
import SwiftUI

/// Bottom sheet showing dictionary definitions for a text selection,
/// with actions to insert the definition into the note, save the word
/// to vocabulary, or ask for an AI explanation.
struct DefinitionSheet: View {
    let request: DefinitionLookupRequest
    var onInsertDefinition: ((String) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = DictionaryLookupViewModel()
    @State private var showingAIExplanation = false

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                loadingView
            case .failed(let error):
                errorView(error)
            case .loaded(let entries, _, let isStale):
                loadedView(entries: entries, isStale: isStale)
            }
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
            AIExplanationSheet(selectedText: request.rawSelection, context: request.context)
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

    private func loadedView(entries: [DictionaryEntry], isStale: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isStale {
                    staleBanner
                }
                if let first = entries.first {
                    header(for: first)
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    ForEach(Array((entry.meanings ?? []).enumerated()), id: \.offset) { _, meaning in
                        MeaningSectionView(meaning: meaning)
                    }
                }
                footer(for: entries)
            }
            .padding(.horizontal)
            .padding(.top, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            actionBar(entries: entries)
        }
    }

    private var staleBanner: some View {
        Label {
            Text("Offline — showing a cached result from \(cachedDateText)")
        } icon: {
            Image(systemName: "wifi.slash")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private var cachedDateText: String {
        guard let date = viewModel.staleResultDate else { return "earlier" }
        return date.formatted(date: .abbreviated, time: .omitted)
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

    private func footer(for entries: [DictionaryEntry]) -> some View {
        // De-duplicate source URLs across entries, keeping order.
        let urls = entries.flatMap { $0.sourceUrls ?? [] }
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0).inserted }

        return VStack(alignment: .leading, spacing: 4) {
            Text("Source: DictionaryAPI.dev")
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

    private func actionBar(entries: [DictionaryEntry]) -> some View {
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
