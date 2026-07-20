import SwiftUI

/// Sheet that explains the selected text at a chosen level and subject.
/// Backed by `MockAIExplanationService` until a real provider is wired in.
struct AIExplanationSheet: View {
    let selectedText: String
    let context: String

    @Environment(\.dismiss) private var dismiss
    @State private var level: ExplanationLevel
    @State private var subject: StudySubject
    @State private var isLoading = false
    @State private var explanation: AIExplanation?
    @State private var errorMessage: String?

    private let service: AIExplanationService = MockAIExplanationService()

    init(selectedText: String, context: String) {
        self.selectedText = selectedText
        self.context = context
        // Seed the pickers from the user's saved defaults (Settings).
        let defaults = UserDefaults.standard
        let levelRaw = defaults.string(forKey: SettingsKeys.defaultExplanationLevel) ?? ""
        let subjectRaw = defaults.string(forKey: SettingsKeys.defaultSubject) ?? ""
        _level = State(initialValue: ExplanationLevel(rawValue: levelRaw) ?? .simple)
        _subject = State(initialValue: StudySubject(rawValue: subjectRaw) ?? .general)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedText)
                            .font(.title3.weight(.semibold))
                        if !context.isEmpty {
                            Text("\u{201C}\(context)\u{201D}")
                                .font(.subheadline)
                                .italic()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } footer: {
                    // Privacy by design: mirror the dictionary lookup's
                    // send-only-the-selection principle in the UI copy.
                    Label(
                        "Only this text and its surrounding sentences are sent — never your whole note.",
                        systemImage: "lock.shield"
                    )
                }

                Section("Explain it for") {
                    Picker("Level", selection: $level) {
                        ForEach(ExplanationLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Subject", selection: $subject) {
                        ForEach(StudySubject.allCases) { subject in
                            Text(subject.displayName).tag(subject)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    Button {
                        Task { await explain() }
                    } label: {
                        if isLoading {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Thinking…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Explain", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isLoading)
                } footer: {
                    Text("AI integration is coming later — this preview uses a placeholder response.")
                }

                if let explanation {
                    Section("Explanation") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(explanation.text)
                                .font(.body)
                            Text("\(explanation.level.displayName) · \(explanation.subject.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Explain with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func explain() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            explanation = try await service.explain(
                selectedText: selectedText,
                context: context,
                level: level,
                subject: subject
            )
        } catch {
            errorMessage = "The explanation couldn't be generated. Please try again."
        }
    }
}

#if DEBUG
#Preview("AI explanation sheet") {
    Color(.systemBackground)
        .sheet(isPresented: .constant(true)) {
            AIExplanationSheet(
                selectedText: "photosynthesis",
                context: "Plants use photosynthesis to convert sunlight into chemical energy. This happens in the chloroplasts."
            )
        }
}
#endif
