import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum NotebookSortOrder: String, CaseIterable, Identifiable {
    case lastModified
    case dateCreated
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastModified: "Last modified"
        case .dateCreated: "Date created"
        case .title: "Title"
        }
    }
}

struct NotebookLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Notebook.updatedAt, order: .reverse) private var notebooks: [Notebook]

    @State private var navigationPath: [UUID] = []
    @State private var searchText = ""
    @State private var sortOrder: NotebookSortOrder = .lastModified
    @State private var showingPDFImporter = false
    @State private var errorMessage: String?
    @State private var notebookPendingDeletion: Notebook?
    @State private var pendingImportURLs: [URL] = []
    @State private var isReadyForImports = false

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 18, alignment: .top)
    ]

    private var displayedNotebooks: [Notebook] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? notebooks
            : notebooks.filter { $0.title.localizedCaseInsensitiveContains(query) }

        switch sortOrder {
        case .lastModified:
            return filtered.sorted { $0.updatedAt > $1.updatedAt }
        case .dateCreated:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .title:
            return filtered.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(displayedNotebooks) { notebook in
                        Button {
                            navigationPath.append(notebook.id)
                        } label: {
                            NotebookCardView(notebook: notebook)
                        }
                        .buttonStyle(PressableCardButtonStyle())
                        .contextMenu {
                            Button(role: .destructive) {
                                notebookPendingDeletion = notebook
                            } label: {
                                Label("Delete Notebook", systemImage: "trash")
                            }
                        }
                        .accessibilityHint("Opens this notebook")
                    }
                }
                .padding()
                .animation(.snappy(duration: 0.25), value: displayedNotebooks.map(\.id))
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Notebooks")
            .searchable(text: $searchText, prompt: "Search notebooks")
            .toolbar { libraryToolbar }
            .overlay { emptyState }
            .navigationDestination(for: UUID.self) { notebookID in
                if let notebook = notebooks.first(where: { $0.id == notebookID }) {
                    NotebookEditorView(notebook: notebook)
                } else {
                    ContentUnavailableView("Notebook Not Found", systemImage: "exclamationmark.triangle")
                }
            }
        }
        .fileImporter(
            isPresented: $showingPDFImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importPDF(at: url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .onOpenURL { url in
            // On a cold launch this fires before the scene is active and before
            // the NavigationStack is installed, so importing immediately either
            // fails to read the file or drops the navigation. Queue the URL and
            // process it once the app is ready.
            pendingImportURLs.append(url)
            processPendingImports()
        }
        .task {
            isReadyForImports = true
            processPendingImports()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                processPendingImports()
            }
        }
        .alert("Something Went Wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .confirmationDialog(
            "Delete this notebook?",
            isPresented: deletionBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Notebook", role: .destructive) {
                if let notebookPendingDeletion {
                    delete(notebookPendingDeletion)
                }
                notebookPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                notebookPendingDeletion = nil
            }
        } message: {
            Text("Its pages, drawings, and inserted photos will be permanently removed. This action cannot be undone.")
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort notebooks", selection: $sortOrder) {
                    ForEach(NotebookSortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingPDFImporter = true
            } label: {
                Label("Import PDF", systemImage: "square.and.arrow.down")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button(action: createBlankNotebook) {
                Label("New Blank Notebook", systemImage: "plus")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if displayedNotebooks.isEmpty {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label("No Notebooks", systemImage: "books.vertical")
                } description: {
                    Text("Create a blank notebook or import a PDF to start writing and drawing.")
                } actions: {
                    HStack {
                        Button("New Blank") { createBlankNotebook() }
                            .buttonStyle(.borderedProminent)
                        Button("Import PDF") { showingPDFImporter = true }
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { notebookPendingDeletion != nil },
            set: { if !$0 { notebookPendingDeletion = nil } }
        )
    }

    private func createBlankNotebook() {
        do {
            let notebook = try NotebookDocumentService.createBlankNotebook(in: modelContext)
            navigationPath.append(notebook.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func processPendingImports() {
        guard isReadyForImports, scenePhase == .active, !pendingImportURLs.isEmpty else { return }
        let urls = pendingImportURLs
        pendingImportURLs = []
        // Hop one runloop turn so the NavigationStack is fully installed before
        // navigating to the imported notebook.
        Task { @MainActor in
            for url in urls {
                importPDF(at: url)
            }
        }
    }

    private func importPDF(at url: URL) {
        do {
            let notebook = try NotebookDocumentService.importPDF(from: url, in: modelContext)
            navigationPath.append(notebook.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ notebook: Notebook) {
        navigationPath.removeAll { $0 == notebook.id }
        do {
            try NotebookDocumentService.deleteNotebook(notebook, in: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct NotebookCardView: View {
    let notebook: Notebook

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotebookCoverView(pdfData: notebook.pdfData)
                .aspectRatio(0.76, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.black.opacity(0.08))
                }
                .shadow(color: .black.opacity(0.12), radius: 7, y: 3)

            Text(notebook.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack {
                Text("\(notebook.pageCount) \(notebook.pageCount == 1 ? "page" : "pages")")
                Spacer()
                Text(notebook.updatedAt, format: .dateTime.month(.abbreviated).day())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct NotebookCoverView: View {
    let pdfData: Data?
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: pdfData == nil ? "doc" : "doc.richtext")
                        .font(.system(size: 34, weight: .light))
                    Text(pdfData == nil ? "Blank notebook" : "PDF notebook")
                        .font(.caption)
                }
                .foregroundStyle(.tertiary)
            }
        }
        .task(id: pdfData?.count) {
            guard let pdfData,
                  let document = PDFDocument(data: pdfData),
                  let page = document.page(at: 0) else {
                thumbnail = nil
                return
            }
            thumbnail = page.thumbnail(of: CGSize(width: 360, height: 480), for: .mediaBox)
        }
    }
}

#if DEBUG
#Preview {
    NotebookLibraryView()
        .modelContainer(for: [Notebook.self, NotebookPage.self], inMemory: true)
}
#endif
