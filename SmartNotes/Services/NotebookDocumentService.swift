import Foundation
import PDFKit
import PencilKit
import SwiftData
import UIKit

enum NotebookDocumentError: LocalizedError {
    case unreadablePDF
    case emptyPDF
    case lockedPDF
    case noPages

    var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            "This file could not be read as a PDF."
        case .emptyPDF:
            "The PDF does not contain any pages."
        case .lockedPDF:
            "Password-protected PDFs must be unlocked before importing."
        case .noPages:
            "This notebook does not contain any pages to export."
        }
    }
}

@MainActor
enum NotebookDocumentService {
    static let blankPageSize = CGSize(width: 612, height: 792)

    @discardableResult
    static func createBlankNotebook(in modelContext: ModelContext) throws -> Notebook {
        let notebook = Notebook(pageCount: 1)
        let page = NotebookPage(
            notebookID: notebook.id,
            orderIndex: 0,
            kind: .blank,
            width: blankPageSize.width,
            height: blankPageSize.height
        )
        modelContext.insert(notebook)
        modelContext.insert(page)
        try modelContext.save()
        return notebook
    }

    @discardableResult
    static func importPDF(from url: URL, in modelContext: ModelContext) throws -> Notebook {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw NotebookDocumentError.unreadablePDF
        }

        guard let document = PDFDocument(data: data) else {
            throw NotebookDocumentError.unreadablePDF
        }
        guard !document.isLocked else {
            throw NotebookDocumentError.lockedPDF
        }
        guard document.pageCount > 0 else {
            throw NotebookDocumentError.emptyPDF
        }

        let fallbackTitle = "Imported PDF"
        let filename = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let notebook = Notebook(
            title: filename.isEmpty ? fallbackTitle : filename,
            pageCount: document.pageCount,
            pdfData: data
        )
        modelContext.insert(notebook)

        for index in 0..<document.pageCount {
            guard let pdfPage = document.page(at: index) else { continue }
            let bounds = pdfPage.bounds(for: .mediaBox)
            let width = max(bounds.width, 1)
            let height = max(bounds.height, 1)
            modelContext.insert(
                NotebookPage(
                    notebookID: notebook.id,
                    orderIndex: index,
                    kind: .pdf,
                    pdfPageIndex: index,
                    width: width,
                    height: height
                )
            )
        }

        try modelContext.save()
        return notebook
    }

    static func addBlankPage(
        to notebook: Notebook,
        after orderIndex: Int?,
        existingPages: [NotebookPage],
        in modelContext: ModelContext
    ) throws -> NotebookPage {
        let sortedPages = existingPages.sorted { $0.orderIndex < $1.orderIndex }
        let insertionIndex = min(max((orderIndex ?? (sortedPages.count - 1)) + 1, 0), sortedPages.count)

        for page in sortedPages where page.orderIndex >= insertionIndex {
            page.orderIndex += 1
        }

        let page = NotebookPage(
            notebookID: notebook.id,
            orderIndex: insertionIndex,
            kind: .blank,
            width: blankPageSize.width,
            height: blankPageSize.height
        )
        modelContext.insert(page)
        notebook.pageCount = sortedPages.count + 1
        notebook.updatedAt = .now
        try modelContext.save()
        return page
    }

    static func deletePage(
        _ page: NotebookPage,
        from notebook: Notebook,
        existingPages: [NotebookPage],
        in modelContext: ModelContext
    ) throws {
        let remaining = existingPages
            .filter { $0.id != page.id }
            .sorted { $0.orderIndex < $1.orderIndex }

        modelContext.delete(page)
        for (index, remainingPage) in remaining.enumerated() {
            remainingPage.orderIndex = index
        }
        notebook.pageCount = remaining.count
        notebook.updatedAt = .now
        try modelContext.save()
    }

    static func deleteNotebook(_ notebook: Notebook, in modelContext: ModelContext) throws {
        let notebookID = notebook.id
        let descriptor = FetchDescriptor<NotebookPage>(
            predicate: #Predicate { $0.notebookID == notebookID }
        )
        for page in try modelContext.fetch(descriptor) {
            modelContext.delete(page)
        }
        modelContext.delete(notebook)
        try modelContext.save()
        try? FileManager.default.removeItem(at: imagesFolder(for: notebookID))
    }

    // MARK: - Element images

    static func imagesFolder(for notebookID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("NotebookImages", isDirectory: true)
            .appendingPathComponent(notebookID.uuidString, isDirectory: true)
    }

    /// Stores an inserted photo in the notebook's images folder and returns its filename.
    static func saveElementImage(_ image: UIImage, notebookID: UUID) throws -> String {
        let folder = imagesFolder(for: notebookID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Cap the stored size so pages with several photos stay light.
        let maxDimension: CGFloat = 1600
        let scale = min(1, maxDimension / max(image.size.width, image.size.height, 1))
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        guard let data = scaled.jpegData(compressionQuality: 0.85) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let fileName = UUID().uuidString + ".jpg"
        try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
        return fileName
    }

    static func elementImage(named fileName: String, notebookID: UUID) -> UIImage? {
        UIImage(contentsOfFile: imagesFolder(for: notebookID).appendingPathComponent(fileName).path)
    }

    static func exportAnnotatedPDF(notebook: Notebook, pages: [NotebookPage]) throws -> URL {
        let sortedPages = pages.sorted { $0.orderIndex < $1.orderIndex }
        guard !sortedPages.isEmpty else {
            throw NotebookDocumentError.noPages
        }

        let sourceDocument = notebook.pdfData.flatMap(PDFDocument.init(data:))
        let filename = sanitizedFilename(notebook.title)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
            .appendingPathExtension("pdf")
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: notebook.title,
            kCGPDFContextCreator as String: "SmartNotes"
        ]
        let firstPage = sortedPages[0]
        let defaultBounds = CGRect(
            origin: .zero,
            size: CGSize(width: max(firstPage.width, 1), height: max(firstPage.height, 1))
        )
        let renderer = UIGraphicsPDFRenderer(bounds: defaultBounds, format: format)

        try renderer.writePDF(to: outputURL) { context in
            for page in sortedPages {
                let pageBounds = CGRect(
                    origin: .zero,
                    size: CGSize(width: max(page.width, 1), height: max(page.height, 1))
                )
                context.beginPage(withBounds: pageBounds, pageInfo: [:])
                UIColor.white.setFill()
                context.cgContext.fill(pageBounds)

                if page.kind == .pdf,
                   let pdfIndex = page.pdfPageIndex,
                   let sourcePage = sourceDocument?.page(at: pdfIndex) {
                    drawPDFPage(sourcePage, in: pageBounds, context: context.cgContext)
                }

                drawElements(
                    PageElement.decoded(from: page.elementsData),
                    notebookID: notebook.id
                )

                drawInk(from: page, in: pageBounds)
            }
        }
        return outputURL
    }

    /// Renders each requested page (PDF background + elements + ink) as a PNG
    /// and returns the file URLs, ready for sharing.
    static func exportPageImages(notebook: Notebook, pages: [NotebookPage]) throws -> [URL] {
        let sortedPages = pages.sorted { $0.orderIndex < $1.orderIndex }
        guard !sortedPages.isEmpty else {
            throw NotebookDocumentError.noPages
        }

        let sourceDocument = notebook.pdfData.flatMap(PDFDocument.init(data:))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookImageExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let baseName = sanitizedFilename(notebook.title)

        var urls: [URL] = []
        for page in sortedPages {
            let pageBounds = CGRect(
                origin: .zero,
                size: CGSize(width: max(page.width, 1), height: max(page.height, 1))
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(bounds: pageBounds, format: format)
            let image = renderer.image { context in
                UIColor.white.setFill()
                context.cgContext.fill(pageBounds)

                if page.kind == .pdf,
                   let pdfIndex = page.pdfPageIndex,
                   let sourcePage = sourceDocument?.page(at: pdfIndex) {
                    drawPDFPage(sourcePage, in: pageBounds, context: context.cgContext)
                }

                drawElements(
                    PageElement.decoded(from: page.elementsData),
                    notebookID: notebook.id
                )

                drawInk(from: page, in: pageBounds)
            }

            guard let data = image.pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }
            let url = folder.appendingPathComponent(
                "\(baseName) - Page \(page.orderIndex + 1).png"
            )
            try data.write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }

    /// Draws a page's PencilKit ink with light-mode traits so dynamic stroke
    /// colors are not inverted when the app is exporting from dark mode.
    private static func drawInk(from page: NotebookPage, in pageBounds: CGRect) {
        guard let data = page.drawingData,
              let drawing = try? PKDrawing(data: data),
              !drawing.strokes.isEmpty else { return }
        var inkImage: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            inkImage = drawing.image(from: pageBounds, scale: 2)
        }
        inkImage?.draw(in: pageBounds)
    }

    static func drawElements(_ elements: [PageElement], notebookID: UUID) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        for element in elements {
            context.saveGState()
            // Rotate around the element's center.
            let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: element.rotationAngle)
            let localFrame = CGRect(
                x: -element.frame.width / 2,
                y: -element.frame.height / 2,
                width: element.frame.width,
                height: element.frame.height
            )

            switch element.kind {
            case .text:
                guard !element.text.isEmpty else {
                    context.restoreGState()
                    continue
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = element.textAlignment
                let attributed = NSAttributedString(
                    string: element.text,
                    attributes: [
                        .font: element.font,
                        .foregroundColor: UIColor(hexString: element.colorHex),
                        .paragraphStyle: paragraph
                    ]
                )
                attributed.draw(in: localFrame)
            case .image:
                guard let fileName = element.imageFileName,
                      var image = elementImage(named: fileName, notebookID: notebookID) else {
                    context.restoreGState()
                    continue
                }
                if let crop = element.cropRect, let cgImage = image.cgImage {
                    let pixelCrop = CGRect(
                        x: crop.origin.x * CGFloat(cgImage.width),
                        y: crop.origin.y * CGFloat(cgImage.height),
                        width: crop.width * CGFloat(cgImage.width),
                        height: crop.height * CGFloat(cgImage.height)
                    )
                    if let croppedCG = cgImage.cropping(to: pixelCrop) {
                        image = UIImage(cgImage: croppedCG, scale: image.scale, orientation: image.imageOrientation)
                    }
                }
                image.draw(in: localFrame)
            }
            context.restoreGState()
        }
    }

    // MARK: - Duplication

    @discardableResult
    static func duplicateNotebook(_ notebook: Notebook, in modelContext: ModelContext) throws -> Notebook {
        let copy = Notebook(
            title: notebook.title + " Copy",
            pageCount: notebook.pageCount,
            folderID: notebook.folderID,
            colorHex: notebook.colorHex,
            pdfData: notebook.pdfData
        )
        modelContext.insert(copy)

        let notebookID = notebook.id
        let descriptor = FetchDescriptor<NotebookPage>(
            predicate: #Predicate { $0.notebookID == notebookID }
        )
        for page in try modelContext.fetch(descriptor) {
            modelContext.insert(
                NotebookPage(
                    notebookID: copy.id,
                    orderIndex: page.orderIndex,
                    kind: page.kind,
                    pdfPageIndex: page.pdfPageIndex,
                    width: page.width,
                    height: page.height,
                    drawingData: page.drawingData,
                    elementsData: page.elementsData
                )
            )
        }

        // Element images are addressed by (notebookID, fileName), so copy the folder.
        let sourceFolder = imagesFolder(for: notebook.id)
        if FileManager.default.fileExists(atPath: sourceFolder.path) {
            let targetFolder = imagesFolder(for: copy.id)
            try? FileManager.default.createDirectory(
                at: targetFolder.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.copyItem(at: sourceFolder, to: targetFolder)
        }

        try modelContext.save()
        return copy
    }

    // MARK: - Folders

    @discardableResult
    static func createFolder(
        named name: String,
        colorHex: String,
        parentFolderID: UUID?,
        in modelContext: ModelContext
    ) throws -> NotebookFolder {
        let folder = NotebookFolder(name: name, colorHex: colorHex, parentFolderID: parentFolderID)
        modelContext.insert(folder)
        try modelContext.save()
        return folder
    }

    /// Deletes a folder. Its notebooks and subfolders move up to the folder's
    /// parent rather than being destroyed.
    static func deleteFolder(_ folder: NotebookFolder, in modelContext: ModelContext) throws {
        let folderID = folder.id
        let parentID = folder.parentFolderID

        let notebooks = try modelContext.fetch(
            FetchDescriptor<Notebook>(predicate: #Predicate { $0.folderID == folderID })
        )
        for notebook in notebooks {
            notebook.folderID = parentID
        }
        let subfolders = try modelContext.fetch(
            FetchDescriptor<NotebookFolder>(predicate: #Predicate { $0.parentFolderID == folderID })
        )
        for subfolder in subfolders {
            subfolder.parentFolderID = parentID
        }

        modelContext.delete(folder)
        try modelContext.save()
    }

    /// True if `candidate` is `folder` itself or one of its descendants —
    /// used to prevent dropping a folder into its own subtree.
    static func folder(
        _ folder: NotebookFolder,
        contains candidateID: UUID,
        allFolders: [NotebookFolder]
    ) -> Bool {
        if folder.id == candidateID { return true }
        var frontier = [folder.id]
        while let current = frontier.popLast() {
            for child in allFolders where child.parentFolderID == current {
                if child.id == candidateID { return true }
                frontier.append(child.id)
            }
        }
        return false
    }

    static func drawPDFPage(_ page: PDFPage, in bounds: CGRect, context: CGContext) {
        let sourceBounds = page.bounds(for: .mediaBox)
        guard sourceBounds.width > 0, sourceBounds.height > 0 else { return }

        let scale = min(bounds.width / sourceBounds.width, bounds.height / sourceBounds.height)
        let renderedSize = CGSize(width: sourceBounds.width * scale, height: sourceBounds.height * scale)
        let offset = CGPoint(
            x: (bounds.width - renderedSize.width) / 2,
            y: (bounds.height - renderedSize.height) / 2
        )

        context.saveGState()
        context.translateBy(x: offset.x, y: bounds.height - offset.y)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -sourceBounds.minX, y: -sourceBounds.minY)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
    }

    private static func sanitizedFilename(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Notebook" : cleaned
    }
}
