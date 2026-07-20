import Foundation

enum ExplanationLevel: String, CaseIterable, Codable, Identifiable {
    case simple
    case highSchool
    case university

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simple: "Simple"
        case .highSchool: "High school"
        case .university: "University"
        }
    }
}

enum StudySubject: String, CaseIterable, Codable, Identifiable {
    case general
    case mathematics
    case physics
    case chemistry
    case biology
    case history
    case economics

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }
}

struct AIExplanation: Hashable {
    let text: String
    let level: ExplanationLevel
    let subject: StudySubject
}

/// UserDefaults keys shared by Settings and the AI explanation sheet.
enum SettingsKeys {
    static let defaultExplanationLevel = "defaultExplanationLevel"
    static let defaultSubject = "defaultSubject"
}
