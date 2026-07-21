import PDFKit
import PencilKit
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct NotebookEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var notebook: Notebook
    @Query private var pages: [NotebookPage]

    @Namespace private var toolSelectionNamespace
    @StateObject private var drawingController = DrawingCanvasController()
    @State private var pdfDocument: PDFDocument?
    @State private var selectedPageID: UUID?
    @State private var showsPageRail = false
    @State private var inkPaletteExpanded = true
    @State private var pagePendingDeletion: NotebookPage?
    @State private var showingClearConfirmation = false
    @State private var sharedDocument: SharedDocument?
    @State private var showingExportOptions = false
    @State private var errorMessage: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var definitionRequest: DefinitionLookupRequest?
    @State private var showingPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?

    // Search
    @State private var showingSearch = false
    @State private var searchText = ""
    @State private var searchMatches: [PDFSelection] = []
    @State private var currentMatchIndex = 0
    @State private var searchHighlights: [UUID: [PageSearchHighlight]] = [:]
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFieldFocused: Bool

    init(notebook: Notebook) {
        self.notebook = notebook
        let notebookID = notebook.id
        _pages = Query(
            filter: #Predicate<NotebookPage> { $0.notebookID == notebookID },
            sort: [SortDescriptor(\NotebookPage.orderIndex)]
        )
        _pdfDocument = State(initialValue: notebook.pdfData.flatMap(PDFDocument.init(data:)))
    }

    private var orderedPages: [NotebookPage] {
        pages.sorted { $0.orderIndex < $1.orderIndex }
    }

    private var selectedPage: NotebookPage? {
        if let selectedPageID,
           let selected = orderedPages.first(where: { $0.id == selectedPageID }) {
            return selected
        }
        return orderedPages.first
    }

    var body: some View {
        ZStack(alignment: .top) {
            canvasArea
            floatingPalettes
        }
        .overlay(alignment: .leading) {
            if showsPageRail {
                pageRail
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .background(Color(.secondarySystemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { navigationToolbar }
        .onAppear {
            if selectedPageID == nil {
                selectedPageID = orderedPages.first?.id
            }
        }
        .onChange(of: orderedPages.map(\.id)) { _, pageIDs in
            if let selectedPageID, !pageIDs.contains(selectedPageID) {
                self.selectedPageID = pageIDs.first
            } else if selectedPageID == nil {
                selectedPageID = pageIDs.first
            }
        }
        .onChange(of: notebook.title) { _, _ in
            notebook.updatedAt = .now
            scheduleSave()
        }
        .onChange(of: photoItem) { _, item in
            insertPhoto(item)
        }
        .onChange(of: searchText) { _, _ in
            scheduleSearch()
        }
        .onDisappear {
            saveTask?.cancel()
            searchTask?.cancel()
            try? modelContext.save()
        }
        .sheet(item: $definitionRequest) { request in
            DefinitionSheet(request: request)
        }
        .sheet(isPresented: $showingExportOptions) {
            ExportOptionsSheet(
                pages: orderedPages,
                currentPageID: selectedPage?.id,
                pdfPageProvider: { pdfPage(for: $0) },
                onExport: performExport
            )
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .images)
        .confirmationDialog(
            "Delete this page?",
            isPresented: pageDeletionBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Page", role: .destructive) {
                if let pagePendingDeletion {
                    delete(pagePendingDeletion)
                }
                pagePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pagePendingDeletion = nil
            }
        } message: {
            Text("The page and everything on it will be removed. This action cannot be undone.")
        }
        .confirmationDialog(
            "Clear all drawing from this page?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Drawing", role: .destructive, action: clearCurrentPage)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All ink on this page will be erased. This action cannot be undone.")
        }
        .sheet(item: $sharedDocument) { item in
            ShareSheet(items: item.urls)
        }
        .alert("Something Went Wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvasArea: some View {
        if orderedPages.isEmpty {
            ContentUnavailableView {
                Label("No Pages", systemImage: "doc")
            } description: {
                Text("Add a blank page to continue.")
            } actions: {
                Button("Add Blank Page", action: addBlankPage)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NotebookCanvasView(
                notebookID: notebook.id,
                pages: orderedPages.map { page in
                    NotebookCanvasView.PageSpec(
                        id: page.id,
                        size: CGSize(width: page.width, height: page.height),
                        pdfPageIndex: page.kind == .pdf ? page.pdfPageIndex : nil,
                        drawingData: page.drawingData,
                        elementsData: page.elementsData
                    )
                },
                pdfDocument: pdfDocument,
                selectedPageID: $selectedPageID,
                controller: drawingController,
                topOverlayInset: 104,
                searchHighlights: searchHighlights,
                onDrawingChanged: saveDrawing,
                onElementsChanged: saveElements,
                onWordLookup: { word, context in
                    definitionRequest = DefinitionLookupRequest(
                        rawSelection: word,
                        context: context,
                        sourceNoteTitle: notebook.title
                    )
                }
            )
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }

    // MARK: - Floating palettes

    private var floatingPalettes: some View {
        VStack(spacing: 10) {
            if showingSearch {
                searchBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ViewThatFits(in: .horizontal) {
                paletteContent
                ScrollView(.horizontal, showsIndicators: false) {
                    paletteContent
                        .padding(.horizontal, 4)
                }
            }

            if drawingController.selectedTool.acceptsInkOptions && inkPaletteExpanded {
                inkPalette
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if !toolHelpText.isEmpty {
                Text(toolHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .liquidGlass(in: Capsule())
                    .transition(.opacity)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.25), value: drawingController.selectedTool)
        .animation(.snappy(duration: 0.25), value: inkPaletteExpanded)
        .animation(.snappy(duration: 0.25), value: showingSearch)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search in document", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($searchFieldFocused)
                .onSubmit(goToNextMatch)
                .frame(maxWidth: 240)

            if !searchMatches.isEmpty {
                Text("\(currentMatchIndex + 1) of \(searchMatches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Button(action: goToPreviousMatch) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(searchMatches.count < 2)
            .accessibilityLabel("Previous Match")

            Button(action: goToNextMatch) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(searchMatches.count < 2)
            .accessibilityLabel("Next Match")

            Divider()
                .frame(height: 20)

            Button(action: closeSearch) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Search")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .liquidGlass(in: Capsule())
    }

    private var paletteContent: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(NotebookDrawingTool.allCases) { tool in
                    toolButton(tool)
                }
            }
            .padding(4)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 2) {
                historyButton(
                    "arrow.uturn.backward",
                    label: "Undo",
                    enabled: drawingController.canUndo,
                    action: drawingController.undo
                )
                historyButton(
                    "arrow.uturn.forward",
                    label: "Redo",
                    enabled: drawingController.canRedo,
                    action: drawingController.redo
                )

                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        drawingController.toggleRuler()
                    }
                } label: {
                    Image(systemName: "ruler")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 38, height: 34)
                        .foregroundStyle(drawingController.isRulerActive ? Color.accentColor : .primary)
                        .background {
                            if drawingController.isRulerActive {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.16))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ruler")

                Button {
                    showingPhotoPicker = true
                } label: {
                    Image(systemName: "photo")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 38, height: 34)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Insert Photo")
            }
            .padding(4)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func toolButton(_ tool: NotebookDrawingTool) -> some View {
        let isSelected = drawingController.selectedTool == tool
        return Button {
            withAnimation(.snappy(duration: 0.25)) {
                if isSelected, tool.acceptsInkOptions {
                    // Tapping the active ink tool again collapses/expands
                    // its color and width options.
                    inkPaletteExpanded.toggle()
                } else {
                    drawingController.selectedTool = tool
                    if tool.acceptsInkOptions {
                        inkPaletteExpanded = true
                    }
                }
            }
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 38, height: 34)
                .foregroundStyle(isSelected ? .white : .primary)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.gradient)
                            .matchedGeometryEffect(id: "tool-selection", in: toolSelectionNamespace)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func historyButton(
        _ systemImage: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 38, height: 34)
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.45))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var inkPalette: some View {
        HStack(spacing: 12) {
            ForEach(presetColors, id: \.accessibilityName) { preset in
                presetColorButton(preset)
            }

            ColorPicker("Custom ink color", selection: inkColorBinding, supportsOpacity: false)
                .labelsHidden()

            Divider()
                .frame(height: 24)

            Image(systemName: "line.diagonal")
                .foregroundStyle(.secondary)
            Slider(
                value: activeWidthBinding,
                in: drawingController.selectedTool == .highlighter ? 6...40 : 1...18
            )
            .frame(width: 150)
            Text("\(Int(drawingController.activeWidth.rounded())) pt")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func presetColorButton(_ preset: (accessibilityName: String, color: UIColor)) -> some View {
        let isSelected = drawingController.inkColor.hexString == preset.color.hexString
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                drawingController.inkColor = preset.color
            }
        } label: {
            Circle()
                .fill(Color(uiColor: preset.color))
                .frame(width: 24, height: 24)
                .scaleEffect(isSelected ? 1.12 : 1)
                .overlay {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.18),
                            lineWidth: isSelected ? 3 : 1
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.accessibilityName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var toolHelpText: String {
        switch drawingController.selectedTool {
        case .hand:
            pdfDocument == nil
                ? "Drag to scroll and pinch to zoom."
                : "Tap a word to look it up; drag to scroll."
        case .eraser: "Draw over strokes to erase them."
        case .lasso: "Circle strokes to select and move them."
        case .text: "Tap anywhere on the page to add a text box."
        case .pen, .pencil, .highlighter: ""
        }
    }

    private var inkColorBinding: Binding<Color> {
        Binding(
            get: { Color(uiColor: drawingController.inkColor) },
            set: { drawingController.inkColor = UIColor($0) }
        )
    }

    private var activeWidthBinding: Binding<Double> {
        Binding(
            get: { drawingController.activeWidth },
            set: drawingController.setActiveWidth
        )
    }

    private var presetColors: [(accessibilityName: String, color: UIColor)] {
        [
            ("Black", .black),
            ("Blue", .systemBlue),
            ("Red", .systemRed),
            ("Green", .systemGreen),
            ("Yellow", .systemYellow)
        ]
    }

    // MARK: - Search

    private func toggleSearch() {
        if showingSearch {
            closeSearch()
        } else {
            withAnimation(.snappy(duration: 0.25)) {
                showingSearch = true
            }
            searchFieldFocused = true
        }
    }

    private func closeSearch() {
        searchTask?.cancel()
        withAnimation(.snappy(duration: 0.25)) {
            showingSearch = false
        }
        searchText = ""
        searchMatches = []
        currentMatchIndex = 0
        searchHighlights = [:]
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchMatches = []
            currentMatchIndex = 0
            searchHighlights = [:]
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            performSearch(query)
        }
    }

    private func performSearch(_ query: String) {
        guard let pdfDocument else { return }
        searchMatches = pdfDocument.findString(
            query,
            withOptions: [.caseInsensitive, .diacriticInsensitive]
        )
        currentMatchIndex = 0
        rebuildSearchHighlights()
        goToCurrentMatch()
    }

    private func goToNextMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count
        rebuildSearchHighlights()
        goToCurrentMatch()
    }

    private func goToPreviousMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
        rebuildSearchHighlights()
        goToCurrentMatch()
    }

    private func rebuildSearchHighlights() {
        guard let pdfDocument, !searchMatches.isEmpty else {
            searchHighlights = [:]
            return
        }
        var pageIDByPDFIndex: [Int: UUID] = [:]
        for page in orderedPages where page.kind == .pdf {
            if let index = page.pdfPageIndex {
                pageIDByPDFIndex[index] = page.id
            }
        }

        var highlights: [UUID: [PageSearchHighlight]] = [:]
        for (matchIndex, selection) in searchMatches.enumerated() {
            for pdfPage in selection.pages {
                let index = pdfDocument.index(for: pdfPage)
                guard let pageID = pageIDByPDFIndex[index] else { continue }
                highlights[pageID, default: []].append(
                    PageSearchHighlight(
                        pdfRect: selection.bounds(for: pdfPage),
                        isCurrent: matchIndex == currentMatchIndex
                    )
                )
            }
        }
        searchHighlights = highlights
    }

    private func goToCurrentMatch() {
        guard searchMatches.indices.contains(currentMatchIndex),
              let pdfDocument else { return }
        let selection = searchMatches[currentMatchIndex]
        guard let firstPage = selection.pages.first else { return }
        let index = pdfDocument.index(for: firstPage)
        if let page = orderedPages.first(where: { $0.kind == .pdf && $0.pdfPageIndex == index }) {
            withAnimation(.snappy(duration: 0.25)) {
                selectedPageID = page.id
            }
        }
    }

    // MARK: - Navigation toolbar

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                withAnimation(.snappy(duration: 0.3)) {
                    showsPageRail.toggle()
                }
            } label: {
                Label(showsPageRail ? "Hide Pages" : "Show Pages", systemImage: "sidebar.left")
            }

            if pdfDocument != nil {
                Button(action: toggleSearch) {
                    Label("Search Document", systemImage: "magnifyingglass")
                }
            }
        }

        ToolbarItem(placement: .principal) {
            TextField("Notebook title", text: $notebook.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .frame(minWidth: 120, idealWidth: 240, maxWidth: 320)
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: addBlankPage) {
                Label("Add Blank Page", systemImage: "doc.badge.plus")
            }

            Button {
                showingExportOptions = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }

            Menu {
                Toggle(isOn: $drawingController.fingerDrawingEnabled) {
                    Label("Draw with Finger", systemImage: "hand.point.up")
                }

                Button {
                    showingPhotoPicker = true
                } label: {
                    Label("Insert Photo", systemImage: "photo.badge.plus")
                }

                Divider()

                Button {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear Page Drawing", systemImage: "eraser.line.dashed")
                }
                .disabled(selectedPage?.drawingData == nil)

                Button(role: .destructive) {
                    pagePendingDeletion = selectedPage
                } label: {
                    Label("Delete Page", systemImage: "trash")
                }
                .disabled(orderedPages.count <= 1 || selectedPage == nil)
            } label: {
                Label("Page Actions", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Page rail

    private var pageRail: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pages")
                    .font(.headline)
                Spacer()
                Text("\(orderedPages.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(orderedPages) { page in
                            Button {
                                withAnimation(.snappy(duration: 0.22)) {
                                    selectedPageID = page.id
                                }
                            } label: {
                                VStack(spacing: 5) {
                                    NotebookPageThumbnailView(
                                        page: page,
                                        pdfPage: pdfPage(for: page)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(
                                                selectedPage?.id == page.id
                                                    ? Color.accentColor
                                                    : Color.black.opacity(0.12),
                                                lineWidth: selectedPage?.id == page.id ? 3 : 1
                                            )
                                    }
                                    Text("\(page.orderIndex + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .id(page.id)
                            .contextMenu {
                                Button(role: .destructive) {
                                    pagePendingDeletion = page
                                } label: {
                                    Label("Delete Page", systemImage: "trash")
                                }
                                .disabled(orderedPages.count <= 1)
                            }
                        }
                    }
                    .padding(12)
                    .animation(.snappy(duration: 0.25), value: orderedPages.map(\.id))
                }
                .onChange(of: selectedPageID) { _, pageID in
                    if let pageID {
                        withAnimation { proxy.scrollTo(pageID, anchor: .center) }
                    }
                }
            }

            Divider()
            Button(action: addBlankPage) {
                Label("Add Page", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(12)
        }
        .frame(width: 172)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 10, x: 4)
    }

    private func pdfPage(for page: NotebookPage) -> PDFPage? {
        guard page.kind == .pdf, let index = page.pdfPageIndex else { return nil }
        return pdfDocument?.page(at: index)
    }

    // MARK: - Actions

    private func addBlankPage() {
        do {
            let page = try NotebookDocumentService.addBlankPage(
                to: notebook,
                after: selectedPage?.orderIndex,
                existingPages: orderedPages,
                in: modelContext
            )
            withAnimation(.snappy(duration: 0.25)) {
                selectedPageID = page.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ page: NotebookPage) {
        guard orderedPages.count > 1,
              let oldIndex = orderedPages.firstIndex(where: { $0.id == page.id }) else { return }
        let candidate = oldIndex + 1 < orderedPages.count
            ? orderedPages[oldIndex + 1]
            : orderedPages[max(oldIndex - 1, 0)]
        do {
            try NotebookDocumentService.deletePage(
                page,
                from: notebook,
                existingPages: orderedPages,
                in: modelContext
            )
            selectedPageID = candidate.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearCurrentPage() {
        guard let selectedPage else { return }
        selectedPage.drawingData = PKDrawing().dataRepresentation()
        notebook.updatedAt = .now
        drawingController.clearPage(withID: selectedPage.id)
        try? modelContext.save()
    }

    private func saveDrawing(_ pageID: UUID, _ data: Data) {
        guard let page = pages.first(where: { $0.id == pageID }) else { return }
        page.drawingData = data
        notebook.updatedAt = .now
        scheduleSave()
    }

    private func saveElements(_ pageID: UUID, _ data: Data?) {
        guard let page = pages.first(where: { $0.id == pageID }) else { return }
        page.elementsData = data
        notebook.updatedAt = .now
        scheduleSave()
    }

    private func insertPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task { @MainActor in
            defer { photoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = "That photo could not be loaded."
                return
            }
            do {
                let fileName = try NotebookDocumentService.saveElementImage(
                    image,
                    notebookID: notebook.id
                )
                drawingController.insertImage(
                    fileName: fileName,
                    image: image,
                    onPageID: selectedPage?.id
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            try? modelContext.save()
        }
    }

    private func performExport(format: NotebookExportFormat, exportPages: [NotebookPage]) {
        saveTask?.cancel()
        try? modelContext.save()
        do {
            switch format {
            case .pdf:
                let url = try NotebookDocumentService.exportAnnotatedPDF(
                    notebook: notebook,
                    pages: exportPages
                )
                sharedDocument = SharedDocument(urls: [url])
            case .image:
                let urls = try NotebookDocumentService.exportPageImages(
                    notebook: notebook,
                    pages: exportPages
                )
                sharedDocument = SharedDocument(urls: urls)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var pageDeletionBinding: Binding<Bool> {
        Binding(
            get: { pagePendingDeletion != nil },
            set: { if !$0 { pagePendingDeletion = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

// MARK: - Export options

enum NotebookExportFormat: String, CaseIterable, Identifiable {
    case pdf
    case image

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pdf: "PDF"
        case .image: "Images"
        }
    }
}

private enum ExportScope: String, CaseIterable, Identifiable {
    case all
    case current
    case selected

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All Pages"
        case .current: "Current Page"
        case .selected: "Selected"
        }
    }
}

private struct ExportOptionsSheet: View {
    let pages: [NotebookPage]
    let currentPageID: UUID?
    let pdfPageProvider: (NotebookPage) -> PDFPage?
    let onExport: (NotebookExportFormat, [NotebookPage]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var format: NotebookExportFormat = .pdf
    @State private var scope: ExportScope = .all
    @State private var selectedPageIDs: Set<UUID> = []

    private var exportPages: [NotebookPage] {
        switch scope {
        case .all:
            return pages
        case .current:
            if let currentPageID,
               let current = pages.first(where: { $0.id == currentPageID }) {
                return [current]
            }
            return Array(pages.prefix(1))
        case .selected:
            return pages.filter { selectedPageIDs.contains($0.id) }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Export format", selection: $format) {
                        ForEach(NotebookExportFormat.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Pages") {
                    Picker("Pages to export", selection: $scope) {
                        ForEach(ExportScope.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    if scope == .selected {
                        pageSelectionGrid
                    }
                }

                Section {
                    Text(summaryText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        let selection = exportPages
                        dismiss()
                        onExport(format, selection)
                    }
                    .disabled(exportPages.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var summaryText: String {
        let count = exportPages.count
        let pageWord = count == 1 ? "page" : "pages"
        switch format {
        case .pdf:
            return count == 0
                ? "Select at least one page to export."
                : "Exports \(count) \(pageWord) as a single PDF file."
        case .image:
            return count == 0
                ? "Select at least one page to export."
                : "Exports \(count) \(pageWord) as separate PNG images."
        }
    }

    private var pageSelectionGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 92, maximum: 130), spacing: 14, alignment: .top)],
            spacing: 16
        ) {
            ForEach(pages) { page in
                let isSelected = selectedPageIDs.contains(page.id)
                Button {
                    if isSelected {
                        selectedPageIDs.remove(page.id)
                    } else {
                        selectedPageIDs.insert(page.id)
                    }
                } label: {
                    VStack(spacing: 5) {
                        NotebookPageThumbnailView(page: page, pdfPage: pdfPageProvider(page))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(
                                        isSelected ? Color.accentColor : Color.black.opacity(0.12),
                                        lineWidth: isSelected ? 3 : 1
                                    )
                            }
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(
                                        isSelected ? Color.white : Color.secondary,
                                        isSelected ? Color.accentColor : Color(.systemBackground).opacity(0.7)
                                    )
                                    .padding(5)
                            }
                        Text("Page \(page.orderIndex + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(page.orderIndex + 1)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Shared views

private struct NotebookPageThumbnailView: View {
    let page: NotebookPage
    let pdfPage: PDFPage?
    @State private var backgroundImage: UIImage?
    @State private var drawingImage: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let backgroundImage {
                Image(uiImage: backgroundImage)
                    .resizable()
                    .scaledToFit()
            }
            if let drawingImage {
                Image(uiImage: drawingImage)
                    .resizable()
                    .scaledToFit()
            }
        }
        .aspectRatio(page.width / max(page.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .task(id: page.id) {
            backgroundImage = pdfPage?.thumbnail(
                of: CGSize(width: 180, height: 240),
                for: .mediaBox
            )
        }
        .task(id: page.drawingData) {
            guard let data = page.drawingData,
                  let drawing = try? PKDrawing(data: data),
                  !drawing.strokes.isEmpty else {
                drawingImage = nil
                return
            }
            // Render with light traits so dark mode doesn't invert stroke colors.
            var image: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = drawing.image(
                    from: CGRect(x: 0, y: 0, width: page.width, height: page.height),
                    scale: 0.35
                )
            }
            drawingImage = image
        }
    }
}

private struct SharedDocument: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
