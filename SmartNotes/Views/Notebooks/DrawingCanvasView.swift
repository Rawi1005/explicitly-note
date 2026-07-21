import PDFKit
import PencilKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - Tools

enum NotebookDrawingTool: String, CaseIterable, Identifiable {
    case hand
    case pen
    case pencil
    case highlighter
    case eraser
    case lasso
    case text

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hand: "Hand"
        case .pen: "Pen"
        case .pencil: "Pencil"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        case .text: "Text"
        }
    }

    var systemImage: String {
        switch self {
        case .hand: "hand.draw"
        case .pen: "pencil.tip"
        case .pencil: "pencil"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .text: "textformat"
        }
    }

    var acceptsInkOptions: Bool {
        switch self {
        case .pen, .pencil, .highlighter: true
        case .hand, .eraser, .lasso, .text: false
        }
    }

    /// Tools that draw ink on the PencilKit canvas.
    var isCanvasTool: Bool {
        switch self {
        case .pen, .pencil, .highlighter, .eraser, .lasso: true
        case .hand, .text: false
        }
    }
}

// MARK: - Controller

@MainActor
final class DrawingCanvasController: ObservableObject {
    private enum DefaultsKey {
        static let penWidth = "smartnotes.drawing.penWidth"
        static let pencilWidth = "smartnotes.drawing.pencilWidth"
        static let highlighterWidth = "smartnotes.drawing.highlighterWidth"
        static let inkColor = "smartnotes.drawing.inkColorHex"
        static let textFontSize = "smartnotes.drawing.textFontSize"
        static let fingerDrawing = "smartnotes.drawing.fingerDrawingEnabled"
        static let pencilDetected = "smartnotes.drawing.pencilDetected"
    }

    @Published var selectedTool: NotebookDrawingTool = .pen {
        didSet {
            if oldValue != selectedTool, oldValue.isCanvasTool, oldValue != .eraser {
                lastInkTool = oldValue
            }
            applyToolConfiguration()
        }
    }
    @Published var inkColor: UIColor {
        didSet {
            UserDefaults.standard.set(inkColor.hexString, forKey: DefaultsKey.inkColor)
            applyToolConfiguration()
        }
    }
    @Published var penWidth: Double {
        didSet {
            UserDefaults.standard.set(penWidth, forKey: DefaultsKey.penWidth)
            applyToolConfiguration()
        }
    }
    @Published var pencilWidth: Double {
        didSet {
            UserDefaults.standard.set(pencilWidth, forKey: DefaultsKey.pencilWidth)
            applyToolConfiguration()
        }
    }
    @Published var highlighterWidth: Double {
        didSet {
            UserDefaults.standard.set(highlighterWidth, forKey: DefaultsKey.highlighterWidth)
            applyToolConfiguration()
        }
    }
    @Published var textFontSize: Double {
        didSet { UserDefaults.standard.set(textFontSize, forKey: DefaultsKey.textFontSize) }
    }
    /// When false (auto-set once an Apple Pencil is detected), fingers pan and
    /// only the Pencil draws.
    @Published var fingerDrawingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(fingerDrawingEnabled, forKey: DefaultsKey.fingerDrawing)
            applyToolConfiguration()
        }
    }
    @Published private(set) var pencilDetected: Bool
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isRulerActive = false

    weak var host: MultiPageScrollView?
    private var lastInkTool: NotebookDrawingTool = .pen

    init() {
        let defaults = UserDefaults.standard
        penWidth = defaults.object(forKey: DefaultsKey.penWidth) as? Double ?? 4
        pencilWidth = defaults.object(forKey: DefaultsKey.pencilWidth) as? Double ?? 3
        highlighterWidth = defaults.object(forKey: DefaultsKey.highlighterWidth) as? Double ?? 18
        textFontSize = defaults.object(forKey: DefaultsKey.textFontSize) as? Double ?? 18
        inkColor = (defaults.string(forKey: DefaultsKey.inkColor)).map(UIColor.init(hexString:)) ?? .black
        pencilDetected = defaults.bool(forKey: DefaultsKey.pencilDetected)
        if defaults.object(forKey: DefaultsKey.fingerDrawing) == nil {
            // Before a Pencil is ever seen, fingers draw; afterwards they pan.
            fingerDrawingEnabled = !defaults.bool(forKey: DefaultsKey.pencilDetected)
        } else {
            fingerDrawingEnabled = defaults.bool(forKey: DefaultsKey.fingerDrawing)
        }
    }

    var activeWidth: Double {
        switch selectedTool {
        case .pen: penWidth
        case .pencil: pencilWidth
        case .highlighter: highlighterWidth
        case .hand, .eraser, .lasso, .text: penWidth
        }
    }

    func setActiveWidth(_ width: Double) {
        switch selectedTool {
        case .pen: penWidth = width
        case .pencil: pencilWidth = width
        case .highlighter: highlighterWidth = width
        case .hand, .eraser, .lasso, .text: break
        }
    }

    // MARK: Host wiring

    func attach(host: MultiPageScrollView) {
        self.host = host
        applyToolConfiguration()
        refreshHistoryState()
    }

    var currentPKTool: PKTool {
        // Resolve against light traits: the page is always white, and PencilKit
        // inverts dynamic ink colors in dark mode (black becomes white and vice
        // versa) unless the color and canvas are pinned to light appearance.
        let resolvedInk = inkColor.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light)
        )
        switch selectedTool {
        case .pen:
            return PKInkingTool(.pen, color: resolvedInk, width: penWidth)
        case .pencil:
            return PKInkingTool(.pencil, color: resolvedInk, width: pencilWidth)
        case .highlighter:
            return PKInkingTool(
                .marker,
                color: resolvedInk.withAlphaComponent(0.35),
                width: highlighterWidth
            )
        case .eraser:
            return PKEraserTool(.vector)
        case .lasso:
            return PKLassoTool()
        case .hand, .text:
            return PKInkingTool(.pen, color: resolvedInk, width: penWidth)
        }
    }

    func applyToolConfiguration() {
        guard let host else { return }
        let canvasActive = selectedTool.isCanvasTool
        let policy: PKCanvasViewDrawingPolicy = fingerDrawingEnabled ? .anyInput : .pencilOnly
        let tool = currentPKTool

        for pageView in host.pageViews {
            let canvas = pageView.canvasView
            canvas.isUserInteractionEnabled = canvasActive
            canvas.drawingPolicy = policy
            canvas.isRulerActive = isRulerActive
            if canvasActive {
                canvas.tool = tool
            }
            pageView.elementsView.isInteractionAllowed = !canvasActive
        }

        // One finger draws (when allowed); two fingers always pan.
        host.panGestureRecognizer.minimumNumberOfTouches =
            (canvasActive && fingerDrawingEnabled) ? 2 : 1
        host.singleTapRecognizer?.isEnabled = (selectedTool == .hand || selectedTool == .text)
    }

    // MARK: Pencil

    func notePencilDetected() {
        guard !pencilDetected else { return }
        pencilDetected = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.pencilDetected)
        // First Pencil touch: switch fingers to panning, GoodNotes-style.
        if fingerDrawingEnabled {
            fingerDrawingEnabled = false
        }
    }

    func handlePencilDoubleTap() {
        switch UIPencilInteraction.preferredTapAction {
        case .ignore:
            return
        case .switchPrevious:
            selectedTool = lastInkTool
        default:
            // Default and .switchEraser: toggle between eraser and last ink tool.
            selectedTool = selectedTool == .eraser ? lastInkTool : .eraser
        }
    }

    // MARK: History & page commands

    private var activeUndoManager: UndoManager? {
        host?.pageViews.first?.canvasView.undoManager
    }

    func undo() {
        activeUndoManager?.undo()
        refreshHistoryAfterCommand()
    }

    func redo() {
        activeUndoManager?.redo()
        refreshHistoryAfterCommand()
    }

    func toggleRuler() {
        isRulerActive.toggle()
        host?.pageViews.forEach { $0.canvasView.isRulerActive = isRulerActive }
    }

    func clearPage(withID pageID: UUID?) {
        guard let pageID,
              let pageView = host?.pageViews.first(where: { $0.pageID == pageID }) else { return }
        pageView.canvasView.drawing = PKDrawing()
        refreshHistoryAfterCommand()
    }

    func insertImage(fileName: String, image: UIImage, onPageID pageID: UUID?) {
        guard let host else { return }
        let target = host.pageViews.first { $0.pageID == pageID } ?? host.pageViews.first
        target?.elementsView.addImageElement(fileName: fileName, image: image)
        // Switch to hand so the photo can be moved right away.
        selectedTool = .hand
    }

    func refreshHistoryState() {
        let undo = activeUndoManager?.canUndo ?? false
        let redo = activeUndoManager?.canRedo ?? false
        if canUndo != undo {
            canUndo = undo
        }
        if canRedo != redo {
            canRedo = redo
        }
    }

    private func refreshHistoryAfterCommand() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshHistoryState()
        }
    }
}

// MARK: - Touch observer (Pencil detection + draw-and-hold)

/// Passive recognizer that watches raw touches to detect Apple Pencil input and
/// "draw and hold still" gestures. Never recognizes, never blocks other gestures.
final class TouchObservingGestureRecognizer: UIGestureRecognizer {
    var onPencilTouch: (() -> Void)?
    var onHoldAtStrokeEnd: (() -> Void)?

    private var trackingSingleTouch = false
    private var touchStartTime: TimeInterval = 0
    private var lastMoveTime: TimeInterval = 0
    private var lastLocation: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touches.contains(where: { $0.type == .pencil }) {
            onPencilTouch?()
        }
        guard let touch = touches.first, event.allTouches?.count == 1 else {
            trackingSingleTouch = false
            return
        }
        trackingSingleTouch = true
        touchStartTime = touch.timestamp
        lastMoveTime = touch.timestamp
        lastLocation = touch.location(in: view)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackingSingleTouch, let touch = touches.first else { return }
        let location = touch.location(in: view)
        if hypot(location.x - lastLocation.x, location.y - lastLocation.y) > 2.5 {
            lastMoveTime = touch.timestamp
            lastLocation = location
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finishTracking(touches)
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finishTracking(touches)
        state = .failed
    }

    private func finishTracking(_ touches: Set<UITouch>) {
        guard trackingSingleTouch, let touch = touches.first else { return }
        trackingSingleTouch = false
        let duration = touch.timestamp - touchStartTime
        let stillFor = touch.timestamp - lastMoveTime
        if duration > 0.65, stillFor > 0.4 {
            onHoldAtStrokeEnd?()
        }
    }
}

// MARK: - Page view

final class PageCanvasView: UIView {
    let pageID: UUID
    let pdfPage: PDFPage?
    let backgroundView = PDFPageBackgroundView()
    let searchHighlightView = SearchHighlightOverlayView()
    let elementsView = PageElementsView()
    let canvasView = PKCanvasView()

    init(pageID: UUID, size: CGSize, pdfPage: PDFPage?) {
        self.pageID = pageID
        self.pdfPage = pdfPage
        super.init(frame: CGRect(origin: .zero, size: size))
        backgroundColor = .white
        // The page is always a white sheet regardless of system theme, and this
        // also stops PencilKit from color-inverting ink in dark mode.
        overrideUserInterfaceStyle = .light
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

        backgroundView.pdfPage = pdfPage
        searchHighlightView.pageRef = pdfPage?.pageRef
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.isScrollEnabled = false
        canvasView.drawingPolicy = .anyInput

        addSubview(backgroundView)
        addSubview(searchHighlightView)
        addSubview(elementsView)
        addSubview(canvasView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundView.frame = bounds
        searchHighlightView.frame = bounds
        elementsView.frame = bounds
        canvasView.frame = bounds
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
    }
}

// MARK: - Search highlights

/// One search hit on a page, in PDF (media box) coordinates.
struct PageSearchHighlight: Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let isCurrent: Bool

    init(pdfRect: CGRect, isCurrent: Bool) {
        x = pdfRect.origin.x
        y = pdfRect.origin.y
        width = pdfRect.width
        height = pdfRect.height
        self.isCurrent = isCurrent
    }

    var pdfRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Paints search-match highlights over the PDF text (under the ink layer).
final class SearchHighlightOverlayView: UIView {
    var pageRef: CGPDFPage?
    private var highlights: [PageSearchHighlight] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setHighlights(_ highlights: [PageSearchHighlight]) {
        guard self.highlights != highlights else { return }
        self.highlights = highlights
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !highlights.isEmpty, let pageRef,
              let context = UIGraphicsGetCurrentContext() else { return }
        let transform = pageRef.getDrawingTransform(
            .mediaBox,
            rect: bounds,
            rotate: 0,
            preserveAspectRatio: true
        )

        for highlight in highlights {
            // Map PDF-space corners into flipped view space.
            let pdfRect = highlight.pdfRect
            let cornerA = pdfRect.origin.applying(transform)
            let cornerB = CGPoint(x: pdfRect.maxX, y: pdfRect.maxY).applying(transform)
            let viewRect = CGRect(
                x: min(cornerA.x, cornerB.x),
                y: bounds.height - max(cornerA.y, cornerB.y),
                width: abs(cornerB.x - cornerA.x),
                height: abs(cornerB.y - cornerA.y)
            ).insetBy(dx: -1.5, dy: -1.5)

            let color = highlight.isCurrent
                ? UIColor.systemOrange.withAlphaComponent(0.5)
                : UIColor.systemYellow.withAlphaComponent(0.35)
            context.setFillColor(color.cgColor)
            let path = UIBezierPath(roundedRect: viewRect, cornerRadius: 3)
            context.addPath(path.cgPath)
            context.fillPath()
        }
    }
}

// MARK: - Multi-page scroll view

/// Vertically stacked notebook pages inside a single zoomable scroll view, so
/// the user scrolls continuously from page to page like GoodNotes.
final class MultiPageScrollView: UIScrollView {
    let pagesContainer = UIView()
    private(set) var pageViews: [PageCanvasView] = []
    var singleTapRecognizer: UITapGestureRecognizer?
    var topOverlayInset: CGFloat = 0

    let pageSpacing: CGFloat = 24
    private(set) var naturalContentSize: CGSize = .zero
    private var lastFitBoundsSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        maximumZoomScale = 6
        bouncesZoom = true
        alwaysBounceVertical = true
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        addSubview(pagesContainer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func rebuildPages(
        _ specs: [NotebookCanvasView.PageSpec],
        pdfDocument: PDFDocument?,
        notebookID: UUID,
        coordinator: NotebookCanvasView.Coordinator
    ) {
        pageViews.forEach { $0.removeFromSuperview() }
        pageViews = []

        let maxWidth = specs.map(\.size.width).max() ?? NotebookDocumentService.blankPageSize.width
        var offsetY: CGFloat = 0
        for spec in specs {
            let pdfPage = spec.pdfPageIndex.flatMap { pdfDocument?.page(at: $0) }
            let pageView = PageCanvasView(pageID: spec.id, size: spec.size, pdfPage: pdfPage)
            pageView.frame = CGRect(
                x: (maxWidth - spec.size.width) / 2,
                y: offsetY,
                width: spec.size.width,
                height: spec.size.height
            )
            pageView.canvasView.delegate = coordinator
            pageView.canvasView.drawing =
                spec.drawingData.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
            pageView.elementsView.imageProvider = { fileName in
                NotebookDocumentService.elementImage(named: fileName, notebookID: notebookID)
            }
            pageView.elementsView.load(elements: PageElement.decoded(from: spec.elementsData))
            let pageID = spec.id
            pageView.elementsView.onElementsChanged = { [weak coordinator] elements in
                coordinator?.elementsChanged(elements, pageID: pageID)
            }
            pagesContainer.addSubview(pageView)
            pageViews.append(pageView)
            offsetY += spec.size.height + pageSpacing
        }

        naturalContentSize = CGSize(width: maxWidth, height: max(offsetY - pageSpacing, 1))
        setZoomScale(1, animated: false)
        pagesContainer.frame = CGRect(origin: .zero, size: naturalContentSize)
        contentSize = naturalContentSize
        lastFitBoundsSize = .zero
        setNeedsLayout()
    }

    func canvas(for pageID: UUID) -> PKCanvasView? {
        pageViews.first { $0.pageID == pageID }?.canvasView
    }

    /// The page currently dominating the viewport.
    var currentPageID: UUID? {
        let probe = CGPoint(x: bounds.midX, y: bounds.midY)
        let point = convert(probe, to: pagesContainer)
        if let hit = pageViews.first(where: { $0.frame.minY - pageSpacing / 2 <= point.y
            && point.y < $0.frame.maxY + pageSpacing / 2 }) {
            return hit.pageID
        }
        return point.y <= 0 ? pageViews.first?.pageID : pageViews.last?.pageID
    }

    func scroll(toPageID pageID: UUID, animated: Bool) {
        guard let pageView = pageViews.first(where: { $0.pageID == pageID }) else { return }
        let frameInSelf = pagesContainer.convert(pageView.frame, to: self)
        let minOffset = -contentInset.top
        let maxOffset = max(contentSize.height + contentInset.bottom - bounds.height, minOffset)
        let target = min(max(frameInSelf.minY - contentInset.top - 8, minOffset), maxOffset)
        setContentOffset(CGPoint(x: contentOffset.x, y: target), animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard naturalContentSize.width > 0, bounds.width > 0, bounds.height > 0 else { return }

        if lastFitBoundsSize != bounds.size {
            lastFitBoundsSize = bounds.size
            let fitScale = (bounds.width - 48) / naturalContentSize.width
            let clamped = max(min(fitScale, maximumZoomScale), 0.05)
            minimumZoomScale = max(clamped * 0.5, 0.05)
            setZoomScale(clamped, animated: false)
            centerContent()
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        } else {
            centerContent()
        }
    }

    func centerContent() {
        let horizontal = max((bounds.width - contentSize.width) / 2, 12)
        let vertical = max((bounds.height - contentSize.height) / 2, 12)
        contentInset = UIEdgeInsets(
            top: max(vertical, topOverlayInset + 12),
            left: horizontal,
            bottom: vertical,
            right: horizontal
        )
    }
}

// MARK: - SwiftUI wrapper

struct NotebookCanvasView: UIViewRepresentable {
    struct PageSpec {
        let id: UUID
        let size: CGSize
        let pdfPageIndex: Int?
        let drawingData: Data?
        let elementsData: Data?
    }

    struct PageSignature: Equatable {
        let id: UUID
        let width: CGFloat
        let height: CGFloat
        let pdfPageIndex: Int?
    }

    let notebookID: UUID
    let pages: [PageSpec]
    let pdfDocument: PDFDocument?
    @Binding var selectedPageID: UUID?
    let controller: DrawingCanvasController
    let topOverlayInset: CGFloat
    let searchHighlights: [UUID: [PageSearchHighlight]]
    let onDrawingChanged: (UUID, Data) -> Void
    let onElementsChanged: (UUID, Data?) -> Void
    let onWordLookup: (_ word: String, _ context: String) -> Void

    func makeUIView(context: Context) -> MultiPageScrollView {
        let scrollView = MultiPageScrollView()
        scrollView.delegate = context.coordinator
        context.coordinator.host = scrollView

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        scrollView.singleTapRecognizer = singleTap
        scrollView.addGestureRecognizer(singleTap)

        let twoFingerTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerTap)
        )
        twoFingerTap.numberOfTouchesRequired = 2
        scrollView.addGestureRecognizer(twoFingerTap)

        let threeFingerTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleThreeFingerTap)
        )
        threeFingerTap.numberOfTouchesRequired = 3
        scrollView.addGestureRecognizer(threeFingerTap)

        let touchObserver = TouchObservingGestureRecognizer()
        touchObserver.cancelsTouchesInView = false
        touchObserver.delaysTouchesBegan = false
        touchObserver.delaysTouchesEnded = false
        touchObserver.delegate = context.coordinator
        touchObserver.onPencilTouch = { [weak controller] in
            controller?.notePencilDetected()
        }
        touchObserver.onHoldAtStrokeEnd = { [weak coordinator = context.coordinator] in
            coordinator?.pendingHoldTimestamp = Date()
        }
        scrollView.addGestureRecognizer(touchObserver)

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        scrollView.addInteraction(pencilInteraction)

        controller.attach(host: scrollView)
        return scrollView
    }

    func updateUIView(_ scrollView: MultiPageScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        scrollView.topOverlayInset = topOverlayInset

        let signature = pages.map {
            PageSignature(id: $0.id, width: $0.size.width, height: $0.size.height, pdfPageIndex: $0.pdfPageIndex)
        }
        if signature != coordinator.builtSignature {
            coordinator.builtSignature = signature
            coordinator.isLoadingPages = true
            scrollView.rebuildPages(
                pages,
                pdfDocument: pdfDocument,
                notebookID: notebookID,
                coordinator: coordinator
            )
            coordinator.isLoadingPages = false
            coordinator.appliedHighlights = nil
            controller.attach(host: scrollView)
            let controller = controller
            DispatchQueue.main.async {
                controller.refreshHistoryState()
            }
        }

        if coordinator.appliedHighlights != searchHighlights {
            coordinator.appliedHighlights = searchHighlights
            for pageView in scrollView.pageViews {
                pageView.searchHighlightView.setHighlights(
                    searchHighlights[pageView.pageID] ?? []
                )
            }
        }

        // Scroll when the selection was changed from outside (the page rail).
        if let target = selectedPageID,
           target != coordinator.lastReportedPageID,
           target != coordinator.lastScrolledPageID {
            coordinator.lastScrolledPageID = target
            coordinator.isProgrammaticScroll = true
            DispatchQueue.main.async { [weak scrollView, weak coordinator] in
                scrollView?.scroll(toPageID: target, animated: true)
                // If no animation actually starts (already in place), unlock.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    coordinator?.isProgrammaticScroll = false
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate,
                             UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        var parent: NotebookCanvasView
        weak var host: MultiPageScrollView?
        var builtSignature: [PageSignature] = []
        var appliedHighlights: [UUID: [PageSearchHighlight]]?
        var isLoadingPages = false
        var isProgrammaticScroll = false
        var lastReportedPageID: UUID?
        var lastScrolledPageID: UUID?
        var pendingHoldTimestamp: Date?
        private var isReplacingStroke = false

        init(parent: NotebookCanvasView) {
            self.parent = parent
        }

        // MARK: Drawing

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isLoadingPages, !isReplacingStroke else { return }
            guard let host,
                  let pageView = host.pageViews.first(where: { $0.canvasView === canvasView })
            else { return }

            snapShapeIfHeld(on: canvasView)
            parent.onDrawingChanged(pageView.pageID, canvasView.drawing.dataRepresentation())
            parent.controller.refreshHistoryState()
        }

        private func snapShapeIfHeld(on canvasView: PKCanvasView) {
            guard let holdTime = pendingHoldTimestamp,
                  Date().timeIntervalSince(holdTime) < 0.4 else { return }
            pendingHoldTimestamp = nil
            guard parent.controller.selectedTool.acceptsInkOptions,
                  let lastStroke = canvasView.drawing.strokes.last,
                  let snapped = ShapeSnapper.snappedStroke(from: lastStroke) else { return }

            isReplacingStroke = true
            var drawing = canvasView.drawing
            drawing.strokes[drawing.strokes.count - 1] = snapped
            canvasView.drawing = drawing
            isReplacingStroke = false
        }

        func elementsChanged(_ elements: [PageElement], pageID: UUID) {
            parent.onElementsChanged(pageID, PageElement.encoded(elements))
        }

        // MARK: Zoom & scroll

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? MultiPageScrollView)?.pagesContainer
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? MultiPageScrollView)?.centerContent()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let host = scrollView as? MultiPageScrollView,
                  !isProgrammaticScroll,
                  let currentID = host.currentPageID,
                  currentID != lastReportedPageID else { return }
            lastReportedPageID = currentID
            // A manual scroll invalidates the last programmatic target, so
            // tapping that page in the rail again scrolls back to it.
            lastScrolledPageID = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.selectedPageID = currentID
            }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard let host = scrollView as? MultiPageScrollView else { return }
            isProgrammaticScroll = false
            lastReportedPageID = host.currentPageID
        }

        // MARK: Taps

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let host else { return }

            // Ignore taps that landed on an element (its own gestures handle those).
            let hitView = host.hitTest(gesture.location(in: host), with: nil)
            if let hitView, hitView !== host, hitView !== host.pagesContainer,
               !(hitView is PageCanvasView), !(hitView is PDFPageBackgroundView) {
                return
            }

            let point = gesture.location(in: host.pagesContainer)
            guard let pageView = host.pageViews.first(where: { $0.frame.contains(point) }) else {
                host.pageViews.forEach { $0.elementsView.deselect() }
                return
            }
            host.pageViews.forEach { $0.elementsView.deselect() }
            let local = host.pagesContainer.convert(point, to: pageView)

            switch parent.controller.selectedTool {
            case .text:
                pageView.elementsView.addTextElement(
                    at: local,
                    fontSize: parent.controller.textFontSize
                )
            case .hand:
                lookupWord(at: local, in: pageView)
            default:
                break
            }
        }

        @objc func handleTwoFingerTap() {
            parent.controller.undo()
        }

        @objc func handleThreeFingerTap() {
            parent.controller.redo()
        }

        private func lookupWord(at point: CGPoint, in pageView: PageCanvasView) {
            guard let pdfPage = pageView.pdfPage, let pageRef = pdfPage.pageRef else { return }
            let bounds = pageView.bounds
            let flipped = CGPoint(x: point.x, y: bounds.height - point.y)
            let transform = pageRef.getDrawingTransform(
                .mediaBox,
                rect: bounds,
                rotate: 0,
                preserveAspectRatio: true
            )
            let pdfPoint = flipped.applying(transform.inverted())

            guard let selection = pdfPage.selectionForWord(at: pdfPoint),
                  let raw = selection.string else { return }
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.rangeOfCharacter(from: .letters) != nil else { return }
            let context = pdfPage.selectionForLine(at: pdfPoint)?.string ?? ""
            parent.onWordLookup(word, context)
        }

        // MARK: Gesture cooperation

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // The passive touch observer must never block anything.
            gestureRecognizer is TouchObservingGestureRecognizer
                || otherGestureRecognizer is TouchObservingGestureRecognizer
        }

        // MARK: Apple Pencil double tap

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            parent.controller.handlePencilDoubleTap()
        }
    }
}

// MARK: - PDF page background (vector, tiled)

/// The PDF stays vector: pages render through CoreGraphics into a tiled layer,
/// re-rasterizing at each zoom level so text stays sharp — never a fixed PNG.
private let pdfPageRenderLock = NSLock()

final class PDFPageBackgroundView: UIView {
    var pdfPage: PDFPage? {
        didSet { setNeedsDisplay() }
    }

    override class var layerClass: AnyClass {
        CATiledLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        if let tiledLayer = layer as? CATiledLayer {
            tiledLayer.levelsOfDetail = 4
            tiledLayer.levelsOfDetailBias = 3
            let screenScale = UIScreen.main.scale
            tiledLayer.tileSize = CGSize(width: 768 * screenScale, height: 768 * screenScale)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let pageRef = pdfPage?.pageRef,
              let context = UIGraphicsGetCurrentContext() else { return }
        pdfPageRenderLock.lock()
        defer { pdfPageRenderLock.unlock() }

        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let transform = pageRef.getDrawingTransform(
            .mediaBox,
            rect: bounds,
            rotate: 0,
            preserveAspectRatio: true
        )
        context.concatenate(transform)
        context.interpolationQuality = .high
        context.drawPDFPage(pageRef)
        context.restoreGState()
    }
}
