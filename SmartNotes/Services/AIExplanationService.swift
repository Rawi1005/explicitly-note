import Foundation

/// Contract for the future AI explanation feature.
///
/// Privacy: implementations must send ONLY the selected text, the one
/// or two sentences around it, the subject, and the explanation level.
/// The full note is never sent to any external service — the same
/// principle the dictionary lookup follows by sending only the
/// selected word.
protocol AIExplanationService {
    func explain(
        selectedText: String,
        context: String,
        level: ExplanationLevel,
        subject: StudySubject
    ) async throws -> AIExplanation
}
