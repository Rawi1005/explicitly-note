import Foundation

/// Placeholder implementation used until a real AI provider is wired in.
/// Swap this for a real `AIExplanationService` implementation (e.g. one
/// backed by the Claude API) at the injection point in `AIExplanationSheet`.
struct MockAIExplanationService: AIExplanationService {
    func explain(
        selectedText: String,
        context: String,
        level: ExplanationLevel,
        subject: StudySubject
    ) async throws -> AIExplanation {
        // Simulate a short network round-trip so loading states are visible.
        try await Task.sleep(for: .milliseconds(600))
        return AIExplanation(
            text: """
            AI integration will be added later. The app will send only the selected text \
            (“\(selectedText)”) and nearby context — never the whole note — at the \
            \(level.displayName.lowercased()) level for the subject \(subject.displayName).
            """,
            level: level,
            subject: subject
        )
    }
}
