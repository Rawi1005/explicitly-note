import Foundation

/// Where a shown definition ultimately came from. Surfaced in the sheet so
/// the user always knows whether they're reading a trusted dictionary entry
/// or a generated AI explanation (requirement #5).
enum DefinitionSource: Equatable {
    case offlineDictionary
    case onlineDictionary   // offline entry enriched with online audio/examples
    case aiExplanation

    var label: String {
        switch self {
        case .offlineDictionary: "Offline dictionary"
        case .onlineDictionary: "Dictionary + online"
        case .aiExplanation: "AI explanation"
        }
    }
}

/// The decision the coordinator reaches for a tapped word. It is computed
/// entirely from the OFFLINE dictionary, so it never depends on the network.
/// AI is never invoked here — these outcomes only decide what the sheet
/// shows; the AI call happens later, only if the user asks for it.
enum LookupOutcome: Equatable {
    /// The selection itself was unusable (empty, punctuation-only, too long).
    /// Show the validation message; do NOT escalate to AI.
    case invalid(DictionaryError)

    /// Found in the offline dictionary → show the dictionary result (all
    /// senses), instantly, offline, and free. This is the common path.
    case found([DictionaryEntry])

    /// Not in the offline dictionary (likely a technical term, acronym, or
    /// jargon) → surface the AI path: "Not in dictionary — Explain with AI".
    case notInDictionary(word: String)
}

/// Decides, offline and automatically, how to handle a tapped word. This
/// replaces the two separate "Define" / "Explain with AI" buttons with a
/// single smart flow whose rule is deliberately simple:
///
///   • In the dictionary  → use the dictionary  (`.found`)
///   • Not in it          → use AI              (`.notInDictionary`)
///
/// Online enrichment (audio, extra examples) is NOT part of this decision:
/// it is layered on afterward by the view model, lazily and failure-
/// tolerantly, so a missing network never blocks a definition.
struct LookupCoordinator {
    let offline: OfflineDictionaryServiceProtocol

    func resolve(selection raw: String) async -> LookupOutcome {
        // Reuse the existing normalizer so validation errors match the rest
        // of the app (empty selection, >50 chars, punctuation-only, …).
        let normalized: String
        do {
            normalized = try WordNormalizer.normalize(raw)
        } catch let error as DictionaryError {
            return .invalid(error)
        } catch {
            return .invalid(.invalidSelection(reason: error.localizedDescription))
        }

        let entries = await offline.lookup(word: normalized)

        // A row with no usable definition counts as "not found": there is
        // nothing to show offline, so the AI path is the right fallback.
        if Self.hasUsableDefinition(in: entries) {
            return .found(entries)
        }
        return .notInDictionary(word: normalized)
    }

    /// True when at least one entry carries a non-empty definition.
    static func hasUsableDefinition(in entries: [DictionaryEntry]) -> Bool {
        entries.contains { entry in
            (entry.meanings ?? []).contains { meaning in
                (meaning.definitions ?? []).contains { !($0.definition ?? "").isEmpty }
            }
        }
    }
}
