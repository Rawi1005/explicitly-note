import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SettingsKeys.defaultExplanationLevel) private var defaultLevelRaw = ExplanationLevel.simple.rawValue
    @AppStorage(SettingsKeys.defaultSubject) private var defaultSubjectRaw = StudySubject.general.rawValue

    @State private var cacheCount = 0
    @State private var showingClearConfirmation = false
    @State private var clearFailed = false

    // @AppStorage stores raw strings; these bindings bridge to the enums.
    private var levelBinding: Binding<ExplanationLevel> {
        Binding(
            get: { ExplanationLevel(rawValue: defaultLevelRaw) ?? .simple },
            set: { defaultLevelRaw = $0.rawValue }
        )
    }

    private var subjectBinding: Binding<StudySubject> {
        Binding(
            get: { StudySubject(rawValue: defaultSubjectRaw) ?? .general },
            set: { defaultSubjectRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                dictionarySection
                aiDefaultsSection
                aboutSection
            }
            .navigationTitle("Settings")
            .onAppear(perform: refreshCacheCount)
        }
    }

    // MARK: - Dictionary

    private var dictionarySection: some View {
        Section {
            LabeledContent {
                Text("\(cacheCount)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.22), value: cacheCount)
            } label: {
                Text("Cached words")
            }
            Button("Clear Dictionary Cache", role: .destructive) {
                showingClearConfirmation = true
            }
            .disabled(cacheCount == 0)
        } header: {
            Text("Dictionary")
        } footer: {
            Text("Looked-up definitions are cached for 7 days so they stay available offline.")
        }
        .alert("Clear all \(cacheCount) cached definitions?", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive, action: clearCache)
        } message: {
            Text("Words will need an internet connection the next time you look them up.")
        }
        .alert("Couldn't Clear Cache", isPresented: $clearFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Something went wrong while clearing the cache. Please try again.")
        }
    }

    private func refreshCacheCount() {
        cacheCount = DictionaryCacheService(modelContext: modelContext).entryCount()
    }

    private func clearCache() {
        do {
            try DictionaryCacheService(modelContext: modelContext).clearAll()
        } catch {
            clearFailed = true
        }
        refreshCacheCount()
    }

    // MARK: - AI defaults

    private var aiDefaultsSection: some View {
        Section {
            Picker("Explanation level", selection: levelBinding) {
                ForEach(ExplanationLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            Picker("Subject", selection: subjectBinding) {
                ForEach(StudySubject.allCases) { subject in
                    Text(subject.displayName).tag(subject)
                }
            }
        } header: {
            Text("AI Defaults")
        } footer: {
            Text("Used as the starting choices in the Explain with AI sheet.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Definitions are provided by the free DictionaryAPI.dev service.")
                    .font(.subheadline)
                if let url = URL(string: "https://dictionaryapi.dev") {
                    Link("dictionaryapi.dev", destination: url)
                        .font(.subheadline)
                }
            }
            .padding(.vertical, 2)
            LabeledContent("Version", value: appVersion)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView()
        .modelContainer(SampleDictionary.previewContainer())
}
#endif
