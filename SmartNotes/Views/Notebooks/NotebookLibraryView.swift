import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum LibraryRoute: Hashable {
    case folder(UUID)
    case notebook(UUID)
}

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

private let folderColorPresets: [(name: String, hex: String)] = [
    ("Blue", "#007AFF"), ("Purple", "#AF52DE"), ("Pink", "#FF2D55"),
    ("Red", "#FF3B30"), ("Orange", "#FF9500"), ("Yellow", "#FFCC00"),
    ("Green", "#34C759"), ("Teal", "#30B0C7"), ("Gray", "#8E8E93")
]

struct NotebookLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var notebooks: [Notebook]
    @ObservedObject private var navigator = AppNavigator.shared

    @State private var navigationPath: [LibraryRoute] = []
    @State private var pendingImportURLs: [URL] = []
    @State private var isReadyForImports = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            LibraryFolderScreen(folderID: nil, folderTitle: "Notebooks", path: $navigationPath)
                .navigationDestination(for: LibraryRoute.self) { route in
                    Group {
                        switch route {
                        case .folder(let folderID):
                            LibraryFolderScreen(
                                folderID: folderID,
                                folderTitle: nil,
                                path: $navigationPath
                            )
                        case .notebook(let notebookID):
                            if let notebook = notebooks.first(where: { $0.id == notebookID }) {
                                NotebookEditorView(notebook: notebook)
                            } else {
                                ContentUnavailableView(
                                    "Notebook Not Found",
                                    systemImage: "exclamationmark.triangle"
                                )
                            }
                        }
                    }
                    // The tab bar belongs to the main menu only; pushed
                    // screens use the full height for content.
                    .toolbar(.hidden, for: .tabBar)
                }
        }
        .onOpenURL { url in
            // On a cold launch this fires before the scene is active; queue the
            // URL and process it once the app is ready.
            pendingImportURLs.append(url)
            processPendingImports()
        }
        .onChange(of: navigator.pendingNotebookOpen) { _, request in
            // A vocabulary entry asked to open its source notebook.
            guard let request else { return }
            navigationPath = [.notebook(request.notebookID)]
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
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func processPendingImports() {
        guard isReadyForImports, scenePhase == .active, !pendingImportURLs.isEmpty else { return }
        let urls = pendingImportURLs
        pendingImportURLs = []
        Task { @MainActor in
            for url in urls {
                do {
                    let notebook = try NotebookDocumentService.importPDF(from: url, in: modelContext)
                    navigationPath.append(.notebook(notebook.id))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Folder screen (used for the root and for every folder level)

private struct LibraryFolderScreen: View {
    let folderID: UUID?
    let folderTitle: String?
    @Binding var path: [LibraryRoute]

    @Environment(\.modelContext) private var modelContext
    @Query private var allNotebooks: [Notebook]
    @Query private var allFolders: [NotebookFolder]

    @State private var searchText = ""
    @State private var sortOrder: NotebookSortOrder = .lastModified
    @State private var showingPDFImporter = false
    @State private var errorMessage: String?

    // Selection mode
    @State private var isSelecting = false
    @State private var selectedNotebookIDs: Set<UUID> = []
    @State private var selectedFolderIDs: Set<UUID> = []
    @State private var showingDeleteSelectionConfirm = false

    // Folder management
    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var folderPendingRename: NotebookFolder?
    @State private var renameText = ""
    @State private var folderPendingDeletion: NotebookFolder?
    @State private var notebookPendingDeletion: Notebook?

    @State private var sharePayload: LibrarySharePayload?

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 18, alignment: .top)
    ]

    private var currentFolder: NotebookFolder? {
        guard let folderID else { return nil }
        return allFolders.first { $0.id == folderID }
    }

    private var title: String {
        folderTitle ?? currentFolder?.name ?? "Folder"
    }

    private var displayedFolders: [NotebookFolder] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var folders = allFolders.filter { $0.parentFolderID == folderID }
        if !query.isEmpty {
            folders = folders.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        switch sortOrder {
        case .lastModified: return folders.sorted { $0.updatedAt > $1.updatedAt }
        case .dateCreated: return folders.sorted { $0.createdAt > $1.createdAt }
        case .title:
            return folders.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    private var displayedNotebooks: [Notebook] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var filtered = allNotebooks.filter { $0.folderID == folderID }
        if !query.isEmpty {
            filtered = filtered.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        switch sortOrder {
        case .lastModified: return filtered.sorted { $0.updatedAt > $1.updatedAt }
        case .dateCreated: return filtered.sorted { $0.createdAt > $1.createdAt }
        case .title:
            return filtered.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    private var selectionCount: Int {
        selectedNotebookIDs.count + selectedFolderIDs.count
    }

    var body: some View {
        withDeletionDialogs(withFolderDialogs(chromeDecorated))
    }

    private func withFolderDialogs(_ content: some View) -> some View {
        content
            .alert("New Folder", isPresented: $showingNewFolderAlert) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") { createFolder() }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            } message: {
                Text("You can change its color from the folder's menu.")
            }
            .alert("Rename Folder", isPresented: renameBinding) {
                TextField("Folder name", text: $renameText)
                Button("Rename") { renameFolderAction() }
                Button("Cancel", role: .cancel) { folderPendingRename = nil }
            }
            .alert("Delete this folder?", isPresented: folderDeletionBinding) {
                Button("Cancel", role: .cancel) { folderPendingDeletion = nil }
                Button("Delete", role: .destructive) { deleteFolderAction() }
            } message: {
                Text(folderDeletionMessage)
            }
    }

    private func withDeletionDialogs(_ content: some View) -> some View {
        content
            .alert("Delete this notebook?", isPresented: notebookDeletionBinding) {
                Button("Cancel", role: .cancel) { notebookPendingDeletion = nil }
                Button("Delete", role: .destructive) {
                    if let notebook = notebookPendingDeletion {
                        deleteNotebook(notebook)
                    }
                    notebookPendingDeletion = nil
                }
            } message: {
                Text("Its pages, drawings, and inserted photos will be permanently removed. This action cannot be undone.")
            }
            .alert(deleteSelectionTitle, isPresented: $showingDeleteSelectionConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive, action: deleteSelection)
            } message: {
                Text("Notebooks are removed permanently. Deleted folders release their contents into this level. This action cannot be undone.")
            }
            .alert("Something Went Wrong", isPresented: errorBinding) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(displayedFolders) { folder in
                    folderCard(folder)
                }
                ForEach(displayedNotebooks) { notebook in
                    notebookCard(notebook)
                }
            }
            .padding()
            .animation(.snappy(duration: 0.25), value: displayedNotebooks.map(\.id))
            .animation(.snappy(duration: 0.25), value: displayedFolders.map(\.id))
        }
    }

    private var chromeDecorated: some View {
        gridContent
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .searchable(text: $searchText, prompt: "Search")
            .toolbar { screenToolbar }
            .overlay { emptyState }
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
            .sheet(item: $sharePayload) { payload in
                LibraryShareSheet(items: payload.urls)
            }
    }

    private func renameFolderAction() {
        if let folder = folderPendingRename {
            folder.name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
            folder.updatedAt = .now
            try? modelContext.save()
        }
        folderPendingRename = nil
    }

    private func deleteFolderAction() {
        if let folder = folderPendingDeletion {
            do {
                try NotebookDocumentService.deleteFolder(folder, in: modelContext)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        folderPendingDeletion = nil
    }

    private var deleteSelectionTitle: String {
        "Delete \(selectionCount) selected item\(selectionCount == 1 ? "" : "s")?"
    }

    // MARK: Cards

    @ViewBuilder
    private func folderCard(_ folder: NotebookFolder) -> some View {
        let isSelected = selectedFolderIDs.contains(folder.id)
        Button {
            if isSelecting {
                toggleFolderSelection(folder.id)
            } else {
                path.append(.folder(folder.id))
            }
        } label: {
            FolderCardView(
                folder: folder,
                itemCount: itemCount(in: folder),
                isSelecting: isSelecting,
                isSelected: isSelected
            )
        }
        .buttonStyle(PressableCardButtonStyle())
        .onDrag {
            NSItemProvider(object: dragPayload(startingWithFolder: folder.id) as NSString)
        }
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            handleDrop(providers, into: folder)
        }
        .contextMenu {
            Button {
                isSelecting = true
                selectedFolderIDs.insert(folder.id)
            } label: {
                Label("Select", systemImage: "checkmark.circle")
            }
            Button {
                renameText = folder.name
                folderPendingRename = folder
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Menu {
                ForEach(folderColorPresets, id: \.hex) { preset in
                    Button(preset.name) {
                        folder.colorHex = preset.hex
                        folder.updatedAt = .now
                        try? modelContext.save()
                    }
                }
            } label: {
                Label("Color", systemImage: "paintpalette")
            }
            Button(role: .destructive) {
                folderPendingDeletion = folder
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func notebookCard(_ notebook: Notebook) -> some View {
        let isSelected = selectedNotebookIDs.contains(notebook.id)
        Button {
            if isSelecting {
                toggleNotebookSelection(notebook.id)
            } else {
                path.append(.notebook(notebook.id))
            }
        } label: {
            NotebookCardView(
                notebook: notebook,
                isSelecting: isSelecting,
                isSelected: isSelected
            )
        }
        .buttonStyle(PressableCardButtonStyle())
        .onDrag {
            NSItemProvider(object: dragPayload(startingWithNotebook: notebook.id) as NSString)
        }
        .contextMenu {
            Button {
                isSelecting = true
                selectedNotebookIDs.insert(notebook.id)
            } label: {
                Label("Select", systemImage: "checkmark.circle")
            }
            Menu {
                moveDestinations { targetID in
                    move(notebookIDs: [notebook.id], folderIDs: [], to: targetID)
                }
            } label: {
                Label("Move To", systemImage: "folder")
            }
            Button {
                duplicate(notebook)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Menu {
                ForEach(folderColorPresets, id: \.hex) { preset in
                    Button(preset.name) {
                        notebook.colorHex = preset.hex
                        try? modelContext.save()
                    }
                }
                Button("None") {
                    notebook.colorHex = nil
                    try? modelContext.save()
                }
            } label: {
                Label("Color Tag", systemImage: "paintpalette")
            }
            Button(role: .destructive) {
                notebookPendingDeletion = notebook
            } label: {
                Label("Delete Notebook", systemImage: "trash")
            }
        }
        .accessibilityHint(isSelecting ? "Toggles selection" : "Opens this notebook")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var screenToolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Text("\(selectionCount) selected")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    moveDestinations { targetID in
                        move(
                            notebookIDs: Array(selectedNotebookIDs),
                            folderIDs: Array(selectedFolderIDs),
                            to: targetID
                        )
                    }
                } label: {
                    Label("Move To", systemImage: "folder")
                }
                .disabled(selectionCount == 0)

                Menu {
                    Button {
                        duplicateSelection()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .disabled(selectedNotebookIDs.isEmpty)

                    Button {
                        shareSelection()
                    } label: {
                        Label("Share as PDF", systemImage: "square.and.arrow.up")
                    }
                    .disabled(selectedNotebookIDs.isEmpty)

                    Menu {
                        ForEach(folderColorPresets, id: \.hex) { preset in
                            Button(preset.name) { colorSelection(hex: preset.hex) }
                        }
                        Button("None") { colorSelection(hex: nil) }
                    } label: {
                        Label("Color Tag", systemImage: "paintpalette")
                    }
                    .disabled(selectionCount == 0)

                    Button(role: .destructive) {
                        showingDeleteSelectionConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selectionCount == 0)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }

                Button("Done") { exitSelectionMode() }
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Select") { isSelecting = true }

                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(NotebookSortOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }

                Button {
                    newFolderName = ""
                    showingNewFolderAlert = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }

                Button {
                    showingPDFImporter = true
                } label: {
                    Label("Import PDF", systemImage: "square.and.arrow.down")
                }

                Button(action: createBlankNotebook) {
                    Label("New Blank Notebook", systemImage: "plus")
                }
            }
        }
    }

    /// Menu entries listing valid move targets: the library root plus every
    /// folder that would not create a cycle.
    @ViewBuilder
    private func moveDestinations(action: @escaping (UUID?) -> Void) -> some View {
        Button {
            action(nil)
        } label: {
            Label("Library", systemImage: "books.vertical")
        }
        ForEach(
            allFolders.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        ) { folder in
            let invalid = selectedFolderIDs.contains(where: { selectedID in
                guard let selected = allFolders.first(where: { $0.id == selectedID }) else { return false }
                return NotebookDocumentService.folder(selected, contains: folder.id, allFolders: allFolders)
            })
            if !invalid {
                Button {
                    action(folder.id)
                } label: {
                    Label(folder.name, systemImage: "folder.fill")
                }
            }
        }
    }

    // MARK: Selection actions

    private func toggleNotebookSelection(_ id: UUID) {
        if selectedNotebookIDs.contains(id) {
            selectedNotebookIDs.remove(id)
        } else {
            selectedNotebookIDs.insert(id)
        }
    }

    private func toggleFolderSelection(_ id: UUID) {
        if selectedFolderIDs.contains(id) {
            selectedFolderIDs.remove(id)
        } else {
            selectedFolderIDs.insert(id)
        }
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedNotebookIDs = []
        selectedFolderIDs = []
    }

    private func duplicateSelection() {
        for notebook in allNotebooks where selectedNotebookIDs.contains(notebook.id) {
            duplicate(notebook)
        }
        exitSelectionMode()
    }

    private func colorSelection(hex: String?) {
        for notebook in allNotebooks where selectedNotebookIDs.contains(notebook.id) {
            notebook.colorHex = hex
        }
        if let hex {
            for folder in allFolders where selectedFolderIDs.contains(folder.id) {
                folder.colorHex = hex
            }
        }
        try? modelContext.save()
        exitSelectionMode()
    }

    private func shareSelection() {
        var urls: [URL] = []
        for notebook in allNotebooks where selectedNotebookIDs.contains(notebook.id) {
            let notebookID = notebook.id
            let descriptor = FetchDescriptor<NotebookPage>(
                predicate: #Predicate { $0.notebookID == notebookID }
            )
            guard let pages = try? modelContext.fetch(descriptor), !pages.isEmpty else { continue }
            if let url = try? NotebookDocumentService.exportAnnotatedPDF(
                notebook: notebook,
                pages: pages
            ) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else {
            errorMessage = "Nothing could be exported from the selection."
            return
        }
        sharePayload = LibrarySharePayload(urls: urls)
        exitSelectionMode()
    }

    private func deleteSelection() {
        for notebook in allNotebooks where selectedNotebookIDs.contains(notebook.id) {
            deleteNotebook(notebook)
        }
        for folder in allFolders where selectedFolderIDs.contains(folder.id) {
            try? NotebookDocumentService.deleteFolder(folder, in: modelContext)
        }
        exitSelectionMode()
    }

    // MARK: Drag & drop

    /// Payload lists every item that should travel with the drag: the grabbed
    /// card plus, when it is part of the current selection, all selected items.
    private func dragPayload(startingWithNotebook id: UUID) -> String {
        var notebookIDs: Set<UUID> = [id]
        var folderIDs: Set<UUID> = []
        if isSelecting, selectedNotebookIDs.contains(id) {
            notebookIDs.formUnion(selectedNotebookIDs)
            folderIDs.formUnion(selectedFolderIDs)
        }
        return encodePayload(notebookIDs: notebookIDs, folderIDs: folderIDs)
    }

    private func dragPayload(startingWithFolder id: UUID) -> String {
        var notebookIDs: Set<UUID> = []
        var folderIDs: Set<UUID> = [id]
        if isSelecting, selectedFolderIDs.contains(id) {
            notebookIDs.formUnion(selectedNotebookIDs)
            folderIDs.formUnion(selectedFolderIDs)
        }
        return encodePayload(notebookIDs: notebookIDs, folderIDs: folderIDs)
    }

    private func encodePayload(notebookIDs: Set<UUID>, folderIDs: Set<UUID>) -> String {
        let notebooks = notebookIDs.map { "notebook:\($0.uuidString)" }
        let folders = folderIDs.map { "folder:\($0.uuidString)" }
        return (notebooks + folders).joined(separator: ";")
    }

    private func handleDrop(_ providers: [NSItemProvider], into folder: NotebookFolder) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) })
        else { return false }
        let targetID = folder.id
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String else { return }
            Task { @MainActor in
                var notebookIDs: [UUID] = []
                var folderIDs: [UUID] = []
                for entry in payload.split(separator: ";") {
                    let parts = entry.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, let uuid = UUID(uuidString: String(parts[1])) else { continue }
                    if parts[0] == "notebook" {
                        notebookIDs.append(uuid)
                    } else if parts[0] == "folder" {
                        folderIDs.append(uuid)
                    }
                }
                move(notebookIDs: notebookIDs, folderIDs: folderIDs, to: targetID)
            }
        }
        return true
    }

    private func move(notebookIDs: [UUID], folderIDs: [UUID], to targetFolderID: UUID?) {
        for notebook in allNotebooks where notebookIDs.contains(notebook.id) {
            notebook.folderID = targetFolderID
        }
        for folder in allFolders where folderIDs.contains(folder.id) {
            // Never drop a folder into itself or one of its descendants.
            if let targetFolderID,
               NotebookDocumentService.folder(folder, contains: targetFolderID, allFolders: allFolders) {
                continue
            }
            folder.parentFolderID = targetFolderID
            folder.updatedAt = .now
        }
        try? modelContext.save()
        exitSelectionMode()
    }

    // MARK: Item actions

    private func itemCount(in folder: NotebookFolder) -> Int {
        let notebooks = allNotebooks.filter { $0.folderID == folder.id }.count
        let subfolders = allFolders.filter { $0.parentFolderID == folder.id }.count
        return notebooks + subfolders
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        do {
            _ = try NotebookDocumentService.createFolder(
                named: name.isEmpty ? "New Folder" : name,
                colorHex: folderColorPresets[0].hex,
                parentFolderID: folderID,
                in: modelContext
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createBlankNotebook() {
        do {
            let notebook = try NotebookDocumentService.createBlankNotebook(in: modelContext)
            notebook.folderID = folderID
            try? modelContext.save()
            path.append(.notebook(notebook.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importPDF(at url: URL) {
        do {
            let notebook = try NotebookDocumentService.importPDF(from: url, in: modelContext)
            notebook.folderID = folderID
            try? modelContext.save()
            path.append(.notebook(notebook.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func duplicate(_ notebook: Notebook) {
        do {
            try NotebookDocumentService.duplicateNotebook(notebook, in: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteNotebook(_ notebook: Notebook) {
        path.removeAll { $0 == .notebook(notebook.id) }
        do {
            try NotebookDocumentService.deleteNotebook(notebook, in: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Empty state & bindings

    @ViewBuilder
    private var emptyState: some View {
        if displayedNotebooks.isEmpty && displayedFolders.isEmpty {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label(
                        folderID == nil ? "No Notebooks" : "Empty Folder",
                        systemImage: folderID == nil ? "books.vertical" : "folder"
                    )
                } description: {
                    Text(
                        folderID == nil
                            ? "Create a blank notebook or import a PDF to start writing and drawing."
                            : "Drag notebooks here, or create new ones with the toolbar."
                    )
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

    private var folderDeletionMessage: String {
        guard let folder = folderPendingDeletion else { return "" }
        let count = itemCount(in: folder)
        if count > 0 {
            return "This folder contains \(count) item\(count == 1 ? "" : "s"). They will move out of the folder, not be deleted."
        }
        return "The folder is empty and will be removed."
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { folderPendingRename != nil },
            set: { if !$0 { folderPendingRename = nil } }
        )
    }

    private var folderDeletionBinding: Binding<Bool> {
        Binding(
            get: { folderPendingDeletion != nil },
            set: { if !$0 { folderPendingDeletion = nil } }
        )
    }

    private var notebookDeletionBinding: Binding<Bool> {
        Binding(
            get: { notebookPendingDeletion != nil },
            set: { if !$0 { notebookPendingDeletion = nil } }
        )
    }
}

// MARK: - Cards

private struct FolderCardView: View {
    let folder: NotebookFolder
    let itemCount: Int
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: UIColor(hexString: folder.colorHex)).opacity(0.16))
                Image(systemName: "folder.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color(uiColor: UIColor(hexString: folder.colorHex)))
            }
            .aspectRatio(0.76, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    SelectionBadge(isSelected: isSelected)
                }
            }

            Text(folder.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct NotebookCardView: View {
    let notebook: Notebook
    var isSelecting = false
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotebookCoverView(pdfData: notebook.pdfData)
                .aspectRatio(0.76, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        SelectionBadge(isSelected: isSelected)
                    }
                }

            HStack(spacing: 6) {
                if let colorHex = notebook.colorHex {
                    Circle()
                        .fill(Color(uiColor: UIColor(hexString: colorHex)))
                        .frame(width: 10, height: 10)
                }
                Text(notebook.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

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

private struct SelectionBadge: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .symbolRenderingMode(.palette)
            .foregroundStyle(
                isSelected ? Color.white : Color.secondary,
                isSelected ? Color.accentColor : Color(.systemBackground).opacity(0.75)
            )
            .padding(6)
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

private struct LibrarySharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct LibraryShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#if DEBUG
#Preview {
    NotebookLibraryView()
        .modelContainer(
            for: [Notebook.self, NotebookPage.self, NotebookFolder.self],
            inMemory: true
        )
}
#endif
