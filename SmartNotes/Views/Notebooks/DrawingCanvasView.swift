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

    /// Tools that draw ink on the PencilKit canvas. The lasso is custom (it
    /// selects ink AND elements together), so it is not a canvas tool.
    var isCanvasTool: Bool {
        switch self {
        case .pen, .pencil, .highlighter, .eraser: true
        case .hand, .text, .lasso: false
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
            pageView.elementsView.isInteractionAllowed =
                (selectedTool == .hand || selectedTool == .text)
        }

        // One finger draws (when allowed); two fingers always pan.
        // The lasso claims single-finger drags for itself.
        host.panGestureRecognizer.minimumNumberOfTouches =
            ((canvasActive && fingerDrawingEnabled) || selectedTool == .lasso) ? 2 : 1
        host.singleTapRecognizer?.isEnabled = (selectedTool == .hand || selectedTool == .text)
        host.textSelectionRecognizer?.isEnabled = selectedTool == .hand
        host.lassoRecognizer?.isEnabled = selectedTool == .lasso
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

/// Passive recognizer that watches raw touches to detect Apple Pencil input
/// and "draw and hold still" gestures. Never recognizes, never blocks other
/// gestures. The hold fires WHILE the touch is still down, so the drawn
/// stroke can morph into a clean shape before the finger lifts.
final class TouchObservingGestureRecognizer: UIGestureRecognizer {
    var onPencilTouch: (() -> Void)?
    /// Fired mid-touch once the pointer has been still for the hold interval.
    /// Points are in the recognizer view's coordinate space.
    var onLiveHoldShape: ((_ points: [CGPoint]) -> Void)?
    /// Whether draw-and-hold snapping should currently be armed.
    var shapeSnapEligibility: ((_ isPencilTouch: Bool) -> Bool)?

    private var trackingSingleTouch = false
    private var isPencilTouch = false
    private var trackedPoints: [CGPoint] = []
    private var lastLocation: CGPoint = .zero
    private var holdTimer: Timer?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touches.contains(where: { $0.type == .pencil }) {
            onPencilTouch?()
        }
        guard let touch = touches.first, event.allTouches?.count == 1 else {
            stopTracking()
            return
        }
        trackingSingleTouch = true
        isPencilTouch = touch.type == .pencil
        lastLocation = touch.location(in: view)
        trackedPoints = [lastLocation]
        scheduleHoldTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackingSingleTouch, let touch = touches.first else { return }
        let location = touch.location(in: view)
        let distance = hypot(location.x - lastLocation.x, location.y - lastLocation.y)
        guard distance > 1.5 else { return }
        lastLocation = location
        if trackedPoints.count < 4000 {
            trackedPoints.append(location)
        }
        if distance > 2.5 {
            // Still moving: push the hold deadline back.
            scheduleHoldTimer()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        stopTracking()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        stopTracking()
        state = .failed
    }

    private func stopTracking() {
        trackingSingleTouch = false
        trackedPoints = []
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func scheduleHoldTimer() {
        holdTimer?.invalidate()
        guard trackingSingleTouch, shapeSnapEligibility?(isPencilTouch) == true else { return }
        holdTimer = Timer.scheduledTimer(
            timeInterval: 0.55,
            target: self,
            selector: #selector(holdTimerFired),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func holdTimerFired() {
        guard trackingSingleTouch, trackedPoints.count >= 8 else { return }
        let points = trackedPoints
        // One snap per touch: stop watching until the next touch begins.
        trackingSingleTouch = false
        holdTimer?.invalidate()
        holdTimer = nil
        onLiveHoldShape?(points)
    }
}

// MARK: - Page view

final class PageCanvasView: UIView {
    let pageID: UUID
    let pdfPage: PDFPage?
    let backgroundView = PDFPageBackgroundView()
    let searchHighlightView = SearchHighlightOverlayView()
    let annotationView = AnnotationUnderlineView()
    let elementsView = PageElementsView()
    let canvasView = PKCanvasView()
    let textSelectionView = TextSelectionOverlayView()
    let lassoOverlayView = LassoOverlayView()

    init(pageID: UUID, size: CGSize, pdfPage: PDFPage?) {
        self.pageID = pageID
        self.pdfPage = pdfPage
        super.init(frame: CGRect(origin: .zero, size: size))
        backgroundColor = .white
        // The page is always a white sheet regardless of system theme, and this
        // also stops PencilKit from color-inverting ink in dark mode.
        overrideUserInterfaceStyle = .light
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.10
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)

        backgroundView.pdfPage = pdfPage
        searchHighlightView.pageRef = pdfPage?.pageRef
        annotationView.pageRef = pdfPage?.pageRef
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.isScrollEnabled = false
        canvasView.drawingPolicy = .anyInput

        addSubview(backgroundView)
        addSubview(searchHighlightView)
        addSubview(annotationView)
        addSubview(elementsView)
        addSubview(canvasView)
        addSubview(textSelectionView)
        addSubview(lassoOverlayView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundView.frame = bounds
        searchHighlightView.frame = bounds
        annotationView.frame = bounds
        elementsView.frame = bounds
        canvasView.frame = bounds
        textSelectionView.frame = bounds
        lassoOverlayView.frame = bounds
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
    }

    // MARK: Coordinate mapping (view space <-> PDF page space)

    private var pageTransform: CGAffineTransform? {
        guard let pageRef = pdfPage?.pageRef else { return nil }
        return pageRef.getDrawingTransform(
            .mediaBox,
            rect: bounds,
            rotate: 0,
            preserveAspectRatio: true
        )
    }

    func pdfPagePoint(forViewPoint point: CGPoint) -> CGPoint? {
        guard let transform = pageTransform else { return nil }
        let flipped = CGPoint(x: point.x, y: bounds.height - point.y)
        return flipped.applying(transform.inverted())
    }

    func viewRect(forPDFRect pdfRect: CGRect) -> CGRect {
        guard let transform = pageTransform else { return .zero }
        let cornerA = pdfRect.origin.applying(transform)
        let cornerB = CGPoint(x: pdfRect.maxX, y: pdfRect.maxY).applying(transform)
        return CGRect(
            x: min(cornerA.x, cornerB.x),
            y: bounds.height - max(cornerA.y, cornerB.y),
            width: abs(cornerB.x - cornerA.x),
            height: abs(cornerB.y - cornerA.y)
        )
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
    var textSelectionRecognizer: UILongPressGestureRecognizer?
    var lassoRecognizer: UIPanGestureRecognizer?
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
            pageView.textSelectionView.onHandleMoved = { [weak coordinator, weak pageView] isStart, location in
                guard let pageView else { return }
                coordinator?.selectionHandleMoved(isStart: isStart, location: location, on: pageView)
            }
            pageView.textSelectionView.onHandleDragEnded = { [weak coordinator] in
                coordinator?.presentSelectionMenu()
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

/// Custom actions offered in the text-selection edit menu that need the
/// SwiftUI layer (sheets) to complete. Define is routed through the word
/// lookup callback instead, so it can carry the word's on-page location.
enum PDFTextSelectionAction {
    case askAI
    case translate
}

/// Where a looked-up word sits on the page, so its underline can be anchored.
struct WordAnnotationTarget {
    let pageID: UUID
    /// Line rects of the word/selection in PDF (media box) space.
    let pdfRects: [CGRect]
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
    let annotations: [UUID: [WordAnnotation]]
    let onDrawingChanged: (UUID, Data) -> Void
    let onElementsChanged: (UUID, Data?) -> Void
    let onWordLookup: (_ word: String, _ context: String, _ target: WordAnnotationTarget?) -> Void
    let onTextAction: (_ action: PDFTextSelectionAction, _ text: String, _ context: String) -> Void
    let onAnnotationTapped: (_ pageID: UUID, _ annotation: WordAnnotation) -> Void

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
        touchObserver.shapeSnapEligibility = { [weak controller] isPencilTouch in
            guard let controller else { return false }
            return controller.selectedTool.acceptsInkOptions
                && (isPencilTouch || controller.fingerDrawingEnabled)
        }
        touchObserver.onLiveHoldShape = { [weak coordinator = context.coordinator] points in
            coordinator?.snapLiveShape(scrollViewPoints: points)
        }
        scrollView.addGestureRecognizer(touchObserver)

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        scrollView.addInteraction(pencilInteraction)

        // Press-and-drag text selection (hand tool only, real PDF text layer).
        let textSelection = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTextSelectionGesture(_:))
        )
        textSelection.minimumPressDuration = 0.3
        scrollView.textSelectionRecognizer = textSelection
        scrollView.addGestureRecognizer(textSelection)

        let editMenu = UIEditMenuInteraction(delegate: context.coordinator)
        scrollView.addInteraction(editMenu)
        context.coordinator.editMenuInteraction = editMenu

        // Custom lasso: circles ink strokes AND placed elements together.
        let lasso = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLassoGesture(_:))
        )
        lasso.minimumNumberOfTouches = 1
        lasso.maximumNumberOfTouches = 1
        scrollView.lassoRecognizer = lasso
        scrollView.addGestureRecognizer(lasso)

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
            coordinator.appliedAnnotations = nil
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

        if coordinator.appliedAnnotations != annotations {
            coordinator.appliedAnnotations = annotations
            for pageView in scrollView.pageViews {
                pageView.annotationView.setAnnotations(annotations[pageView.pageID] ?? [])
            }
        }

        // Leaving the hand tool always drops any active text selection.
        if controller.selectedTool != .hand, coordinator.activeSelection != nil {
            DispatchQueue.main.async { [weak coordinator] in
                coordinator?.clearTextSelection()
            }
        }

        // Leaving the lasso tool drops any active group selection.
        if controller.selectedTool != .lasso, coordinator.lassoGroupActive {
            DispatchQueue.main.async { [weak coordinator] in
                coordinator?.clearLassoSelection()
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
                             UIGestureRecognizerDelegate, UIPencilInteractionDelegate,
                             UIEditMenuInteractionDelegate {
        var parent: NotebookCanvasView
        weak var host: MultiPageScrollView?
        weak var editMenuInteraction: UIEditMenuInteraction?
        var builtSignature: [PageSignature] = []
        var appliedHighlights: [UUID: [PageSearchHighlight]]?
        var appliedAnnotations: [UUID: [WordAnnotation]]?
        var isLoadingPages = false
        var isProgrammaticScroll = false
        var lastReportedPageID: UUID?
        var lastScrolledPageID: UUID?
        private var isReplacingStroke = false

        // Text selection state
        private(set) var activeSelection: PDFSelection?
        private weak var selectionPageView: PageCanvasView?
        private var selectionStartPDFPoint: CGPoint?
        private var selectionEndPDFPoint: CGPoint?
        private var dragAnchorPDFPoint: CGPoint?

        // Lasso group state
        private enum LassoMode {
            case idle
            case drawing
            case moving
            case scaling(anchor: CGPoint, startPoint: CGPoint)
        }
        private(set) var lassoGroupActive = false
        private var lassoMode: LassoMode = .idle
        private weak var lassoPageView: PageCanvasView?
        private var lassoPathPoints: [CGPoint] = []
        private var lassoStrokeIndices: [Int] = []
        private var lassoElementIDs: [UUID] = []
        private var lassoGroupBox: CGRect = .null
        private var lassoLastPoint: CGPoint = .zero
        private var lassoPendingStrokeTranslation: CGPoint = .zero
        private var lassoPendingStrokeScale: CGFloat = 1
        private var lassoScaleStartBox: CGRect = .null

        init(parent: NotebookCanvasView) {
            self.parent = parent
        }

        // MARK: Drawing

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isLoadingPages, !isReplacingStroke else { return }
            guard let host,
                  let pageView = host.pageViews.first(where: { $0.canvasView === canvasView })
            else { return }

            parent.onDrawingChanged(pageView.pageID, canvasView.drawing.dataRepresentation())
            parent.controller.refreshHistoryState()
        }

        /// Draw-and-hold: fires while the touch is still down. Cancels the
        /// in-flight freehand stroke and commits the fitted shape in its
        /// place, so the shape is visible before the finger lifts.
        func snapLiveShape(scrollViewPoints: [CGPoint]) {
            guard let host,
                  parent.controller.selectedTool.acceptsInkOptions,
                  let firstPoint = scrollViewPoints.first else { return }

            let containerPoint = host.convert(firstPoint, to: host.pagesContainer)
            guard let pageView = host.pageViews.first(where: { $0.frame.contains(containerPoint) })
            else { return }
            let pagePoints = scrollViewPoints.map { host.convert($0, to: pageView) }

            guard let inkTool = parent.controller.currentPKTool as? PKInkingTool else { return }
            let ink = PKInk(inkTool.inkType, color: inkTool.color)
            guard let snapped = ShapeSnapper.snappedStroke(
                fromPoints: pagePoints,
                ink: ink,
                width: inkTool.width
            ) else { return }

            // Toggling the drawing recognizer cancels the uncommitted stroke.
            let drawingRecognizer = pageView.canvasView.drawingGestureRecognizer
            drawingRecognizer.isEnabled = false
            drawingRecognizer.isEnabled = true

            isReplacingStroke = true
            var drawing = pageView.canvasView.drawing
            drawing.strokes.append(snapped)
            pageView.canvasView.drawing = drawing
            isReplacingStroke = false

            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            parent.onDrawingChanged(pageView.pageID, drawing.dataRepresentation())
            parent.controller.refreshHistoryState()
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
            guard let host = scrollView as? MultiPageScrollView else { return }
            if activeSelection != nil, scrollView.isDragging || scrollView.isDecelerating {
                editMenuInteraction?.dismissMenu()
            }
            guard !isProgrammaticScroll,
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

            // A tap while text is selected just clears the selection.
            if activeSelection != nil {
                clearTextSelection()
                return
            }

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
                // Underlined saved words open their saved definition popup.
                if let annotation = pageView.annotationView.annotation(at: local) {
                    parent.onAnnotationTapped(pageView.pageID, annotation)
                } else {
                    lookupWord(at: local, in: pageView)
                }
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
            guard let pdfPage = pageView.pdfPage,
                  let pdfPoint = pageView.pdfPagePoint(forViewPoint: point) else { return }

            guard let selection = pdfPage.selectionForWord(at: pdfPoint),
                  let raw = selection.string else { return }
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.rangeOfCharacter(from: .letters) != nil else { return }
            let context = pdfPage.selectionForLine(at: pdfPoint)?.string ?? ""
            let rects = selection.selectionsByLine()
                .map { $0.bounds(for: pdfPage) }
                .filter { $0.width > 0.1 }
            parent.onWordLookup(
                word,
                context,
                WordAnnotationTarget(pageID: pageView.pageID, pdfRects: rects)
            )
        }

        // MARK: Text selection

        @objc func handleTextSelectionGesture(_ gesture: UILongPressGestureRecognizer) {
            guard let host else { return }
            let containerPoint = gesture.location(in: host.pagesContainer)

            switch gesture.state {
            case .began:
                guard let pageView = host.pageViews.first(where: { $0.frame.contains(containerPoint) }),
                      pageView.pdfPage != nil else { return }
                let local = host.pagesContainer.convert(containerPoint, to: pageView)
                guard let pdfPoint = pageView.pdfPagePoint(forViewPoint: local) else { return }
                dragAnchorPDFPoint = pdfPoint
                if let wordSelection = pageView.pdfPage?.selectionForWord(at: pdfPoint),
                   !(wordSelection.string ?? "").isEmpty {
                    UISelectionFeedbackGenerator().selectionChanged()
                    setSelection(wordSelection, on: pageView)
                }
            case .changed:
                guard let pageView = selectionPageView ?? host.pageViews.first(where: { $0.frame.contains(containerPoint) }),
                      let anchor = dragAnchorPDFPoint,
                      let page = pageView.pdfPage else { return }
                let local = host.pagesContainer.convert(containerPoint, to: pageView)
                guard let pdfPoint = pageView.pdfPagePoint(forViewPoint: local) else { return }
                if let selection = page.selection(from: anchor, to: pdfPoint),
                   !(selection.string ?? "").isEmpty {
                    setSelection(selection, on: pageView)
                }
            case .ended:
                dragAnchorPDFPoint = nil
                presentSelectionMenu()
            case .cancelled, .failed:
                dragAnchorPDFPoint = nil
            default:
                break
            }
        }

        private func setSelection(_ selection: PDFSelection, on pageView: PageCanvasView) {
            guard let page = pageView.pdfPage else { return }
            activeSelection = selection
            selectionPageView = pageView

            let pdfRects = selection.selectionsByLine()
                .map { $0.bounds(for: page) }
                .filter { $0.width > 0.1 && $0.height > 0.1 }
            pageView.textSelectionView.show(rects: pdfRects.map { pageView.viewRect(forPDFRect: $0) })
            if let host {
                for other in host.pageViews where other !== pageView {
                    other.textSelectionView.clear()
                }
            }

            if let firstRect = pdfRects.first, let lastRect = pdfRects.last {
                selectionStartPDFPoint = CGPoint(x: firstRect.minX + 1, y: firstRect.midY)
                selectionEndPDFPoint = CGPoint(x: lastRect.maxX - 1, y: lastRect.midY)
            }
        }

        func selectionHandleMoved(isStart: Bool, location: CGPoint, on pageView: PageCanvasView) {
            guard let page = pageView.pdfPage,
                  let pdfPoint = pageView.pdfPagePoint(forViewPoint: location),
                  let anchor = isStart ? selectionEndPDFPoint : selectionStartPDFPoint else { return }
            editMenuInteraction?.dismissMenu()
            let from = isStart ? pdfPoint : anchor
            let to = isStart ? anchor : pdfPoint
            if let selection = page.selection(from: from, to: to),
               !(selection.string ?? "").isEmpty {
                setSelection(selection, on: pageView)
            }
        }

        func presentSelectionMenu() {
            guard let host,
                  let pageView = selectionPageView,
                  pageView.textSelectionView.hasSelection,
                  activeSelection != nil else { return }
            let boundingRect = pageView.textSelectionView.selectionBoundingRect
            guard !boundingRect.isNull else { return }
            let rectInHost = pageView.convert(boundingRect, to: host)
            let configuration = UIEditMenuConfiguration(
                identifier: nil,
                sourcePoint: CGPoint(x: rectInHost.midX, y: rectInHost.minY - 8)
            )
            editMenuInteraction?.presentEditMenu(with: configuration)
        }

        func clearTextSelection() {
            guard activeSelection != nil else { return }
            activeSelection = nil
            selectionPageView = nil
            selectionStartPDFPoint = nil
            selectionEndPDFPoint = nil
            dragAnchorPDFPoint = nil
            host?.pageViews.forEach { $0.textSelectionView.clear() }
            editMenuInteraction?.dismissMenu()
        }

        // MARK: Edit menu

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            if lassoGroupActive {
                return UIMenu(children: [
                    UIAction(
                        title: "Duplicate",
                        image: UIImage(systemName: "plus.square.on.square")
                    ) { [weak self] _ in
                        self?.duplicateLassoGroup()
                    },
                    UIAction(
                        title: "Delete",
                        image: UIImage(systemName: "trash"),
                        attributes: .destructive
                    ) { [weak self] _ in
                        self?.deleteLassoGroup()
                    }
                ])
            }

            guard let selection = activeSelection,
                  let rawText = selection.string else { return nil }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let context = selectionContext(fallback: text)

            let standard: [UIMenuElement] = [
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    UIPasteboard.general.string = text
                    self?.clearTextSelection()
                },
                UIAction(title: "Select All", image: UIImage(systemName: "text.justify")) { [weak self] _ in
                    self?.selectAllOnCurrentPage()
                },
                UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    self?.presentShare(for: text)
                }
            ]

            // Capture the selection's location so Define can underline the word.
            let annotationTarget: WordAnnotationTarget? = {
                guard let pageView = selectionPageView, let page = pageView.pdfPage else { return nil }
                let rects = selection.selectionsByLine()
                    .map { $0.bounds(for: page) }
                    .filter { $0.width > 0.1 }
                guard !rects.isEmpty else { return nil }
                return WordAnnotationTarget(pageID: pageView.pageID, pdfRects: rects)
            }()

            let custom: [UIMenuElement] = [
                UIAction(title: "Define", image: UIImage(systemName: "character.book.closed")) { [weak self] _ in
                    self?.parent.onWordLookup(text, context, annotationTarget)
                    self?.clearTextSelection()
                },
                UIAction(title: "Ask AI", image: UIImage(systemName: "sparkles")) { [weak self] _ in
                    self?.parent.onTextAction(.askAI, text, context)
                },
                UIAction(title: "Translate", image: UIImage(systemName: "globe")) { [weak self] _ in
                    self?.parent.onTextAction(.translate, text, context)
                },
                UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
                    self?.highlightActiveSelection()
                },
                UIAction(title: "Add Note", image: UIImage(systemName: "note.text.badge.plus")) { [weak self] _ in
                    self?.addNoteForActiveSelection(text: text)
                }
            ]

            return UIMenu(children: standard + custom)
        }

        private func selectionContext(fallback: String) -> String {
            guard let page = selectionPageView?.pdfPage,
                  let start = selectionStartPDFPoint,
                  let line = page.selectionForLine(at: start)?.string,
                  !line.isEmpty else { return fallback }
            return line
        }

        private func selectAllOnCurrentPage() {
            guard let pageView = selectionPageView, let page = pageView.pdfPage else { return }
            let pageBounds = page.bounds(for: .mediaBox)
            guard let selection = page.selection(for: pageBounds),
                  !(selection.string ?? "").isEmpty else { return }
            setSelection(selection, on: pageView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.presentSelectionMenu()
            }
        }

        private func presentShare(for text: String) {
            guard let host, let presenter = topViewController() else { return }
            let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = host
                if let pageView = selectionPageView {
                    popover.sourceRect = pageView.convert(
                        pageView.textSelectionView.selectionBoundingRect,
                        to: host
                    )
                } else {
                    popover.sourceRect = CGRect(
                        x: host.bounds.midX,
                        y: host.bounds.midY,
                        width: 1,
                        height: 1
                    )
                }
            }
            presenter.present(activity, animated: true)
            clearTextSelection()
        }

        private func topViewController() -> UIViewController? {
            guard let root = host?.window?.rootViewController else { return nil }
            var top = root
            while let presented = top.presentedViewController {
                top = presented
            }
            return top
        }

        /// Lays permanent highlighter ink over the selected lines, so the
        /// highlight is erasable, undoable, and included in exports.
        private func highlightActiveSelection() {
            guard let selection = activeSelection,
                  let pageView = selectionPageView,
                  let page = pageView.pdfPage else { return }

            var drawing = pageView.canvasView.drawing
            let ink = PKInk(.marker, color: UIColor.systemYellow.withAlphaComponent(0.45))

            for line in selection.selectionsByLine() {
                let viewRect = pageView.viewRect(forPDFRect: line.bounds(for: page))
                guard viewRect.width > 1, viewRect.height > 1 else { continue }
                let strokeSize = CGSize(width: viewRect.height, height: viewRect.height)
                var points: [PKStrokePoint] = []
                var x = viewRect.minX
                var index = 0
                while x < viewRect.maxX {
                    points.append(strokePoint(at: CGPoint(x: x, y: viewRect.midY), index: index, size: strokeSize))
                    x += 6
                    index += 1
                }
                points.append(strokePoint(at: CGPoint(x: viewRect.maxX, y: viewRect.midY), index: index, size: strokeSize))
                guard points.count >= 2 else { continue }
                drawing.strokes.append(
                    PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
                )
            }

            pageView.canvasView.drawing = drawing
            parent.onDrawingChanged(pageView.pageID, drawing.dataRepresentation())
            parent.controller.refreshHistoryState()
            clearTextSelection()
        }

        private func strokePoint(at location: CGPoint, index: Int, size: CGSize) -> PKStrokePoint {
            PKStrokePoint(
                location: location,
                timeOffset: TimeInterval(index) * 0.01,
                size: size,
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }

        /// Drops an editable text box just below the selection, pre-filled with
        /// the selected text.
        private func addNoteForActiveSelection(text: String) {
            guard let selection = activeSelection,
                  let pageView = selectionPageView,
                  let page = pageView.pdfPage,
                  let lastLine = selection.selectionsByLine().last else { return }
            let viewRect = pageView.viewRect(forPDFRect: lastLine.bounds(for: page))
            let origin = CGPoint(
                x: max(viewRect.minX, 8),
                y: min(viewRect.maxY + 10, pageView.bounds.height - 60)
            )
            clearTextSelection()
            pageView.elementsView.addTextElement(
                at: origin,
                fontSize: parent.controller.textFontSize,
                initialText: text
            )
        }

        // MARK: Lasso group selection

        @objc func handleLassoGesture(_ gesture: UIPanGestureRecognizer) {
            guard let host else { return }
            let containerPoint = gesture.location(in: host.pagesContainer)

            switch gesture.state {
            case .began:
                lassoBegan(containerPoint: containerPoint, host: host)
            case .changed:
                lassoChanged(containerPoint: containerPoint)
            case .ended:
                lassoEnded()
            case .cancelled, .failed:
                if case .drawing = lassoMode {
                    lassoPageView?.lassoOverlayView.clearPath()
                }
                lassoMode = .idle
            default:
                break
            }
        }

        private func lassoBegan(containerPoint: CGPoint, host: MultiPageScrollView) {
            if lassoGroupActive, let pageView = lassoPageView {
                let local = host.pagesContainer.convert(containerPoint, to: pageView)
                let handleTolerance: CGFloat = 30

                // Corner grab → scale about the opposite corner.
                let corners = [
                    CGPoint(x: lassoGroupBox.minX, y: lassoGroupBox.minY),
                    CGPoint(x: lassoGroupBox.maxX, y: lassoGroupBox.minY),
                    CGPoint(x: lassoGroupBox.minX, y: lassoGroupBox.maxY),
                    CGPoint(x: lassoGroupBox.maxX, y: lassoGroupBox.maxY)
                ]
                for (index, corner) in corners.enumerated()
                where hypot(local.x - corner.x, local.y - corner.y) < handleTolerance {
                    let anchor = corners[3 - index]
                    lassoMode = .scaling(anchor: anchor, startPoint: local)
                    lassoScaleStartBox = lassoGroupBox
                    lassoPendingStrokeScale = 1
                    lassoPendingStrokeTranslation = .zero
                    editMenuInteraction?.dismissMenu()
                    return
                }

                // Inside the box → move the whole group.
                if lassoGroupBox.insetBy(dx: -10, dy: -10).contains(local) {
                    lassoMode = .moving
                    lassoLastPoint = local
                    lassoPendingStrokeTranslation = .zero
                    lassoPendingStrokeScale = 1
                    editMenuInteraction?.dismissMenu()
                    return
                }

                clearLassoSelection()
            }

            guard let pageView = host.pageViews.first(where: { $0.frame.contains(containerPoint) }) else {
                lassoMode = .idle
                return
            }
            lassoPageView = pageView
            lassoMode = .drawing
            lassoPathPoints = [host.pagesContainer.convert(containerPoint, to: pageView)]
            pageView.lassoOverlayView.updatePath(lassoPathPoints)
        }

        private func lassoChanged(containerPoint: CGPoint) {
            guard let host, let pageView = lassoPageView else { return }
            let local = host.pagesContainer.convert(containerPoint, to: pageView)

            switch lassoMode {
            case .drawing:
                lassoPathPoints.append(local)
                pageView.lassoOverlayView.updatePath(lassoPathPoints)
            case .moving:
                let delta = CGPoint(x: local.x - lassoLastPoint.x, y: local.y - lassoLastPoint.y)
                lassoLastPoint = local
                lassoPendingStrokeTranslation.x += delta.x
                lassoPendingStrokeTranslation.y += delta.y
                lassoGroupBox = lassoGroupBox.offsetBy(dx: delta.x, dy: delta.y)
                pageView.elementsView.transformElements(
                    ids: lassoElementIDs,
                    translation: delta,
                    scale: 1,
                    anchor: .zero
                )
                pageView.lassoOverlayView.showGroup(box: lassoGroupBox)
            case .scaling(let anchor, let startPoint):
                let startDistance = max(hypot(startPoint.x - anchor.x, startPoint.y - anchor.y), 1)
                let currentDistance = max(hypot(local.x - anchor.x, local.y - anchor.y), 1)
                let totalScale = min(max(currentDistance / startDistance, 0.2), 8)
                let stepScale = totalScale / lassoPendingStrokeScale
                lassoPendingStrokeScale = totalScale
                pageView.elementsView.transformElements(
                    ids: lassoElementIDs,
                    translation: .zero,
                    scale: stepScale,
                    anchor: anchor
                )
                lassoGroupBox = scaled(lassoScaleStartBox, by: totalScale, about: anchor)
                pageView.lassoOverlayView.showGroup(box: lassoGroupBox)
            case .idle:
                break
            }
        }

        private func lassoEnded() {
            guard let pageView = lassoPageView else {
                lassoMode = .idle
                return
            }

            switch lassoMode {
            case .drawing:
                pageView.lassoOverlayView.clearPath()
                finishLassoSelection(on: pageView)
            case .moving:
                applyPendingStrokeTransform(
                    translation: lassoPendingStrokeTranslation,
                    scale: 1,
                    anchor: .zero,
                    on: pageView
                )
                presentLassoMenu()
            case .scaling(let anchor, _):
                applyPendingStrokeTransform(
                    translation: .zero,
                    scale: lassoPendingStrokeScale,
                    anchor: anchor,
                    on: pageView
                )
                presentLassoMenu()
            case .idle:
                break
            }
            lassoMode = .idle
        }

        private func finishLassoSelection(on pageView: PageCanvasView) {
            guard lassoPathPoints.count >= 8 else {
                clearLassoSelection()
                return
            }
            let path = UIBezierPath()
            path.move(to: lassoPathPoints[0])
            for point in lassoPathPoints.dropFirst() {
                path.addLine(to: point)
            }
            path.close()

            // Strokes: selected when most of their sampled points fall inside.
            var strokeIndices: [Int] = []
            let strokes = pageView.canvasView.drawing.strokes
            for (index, stroke) in strokes.enumerated() {
                let samples = Array(stroke.path.interpolatedPoints(by: .distance(12)))
                guard !samples.isEmpty else { continue }
                let insideCount = samples.filter {
                    path.contains($0.location.applying(stroke.transform))
                }.count
                if Double(insideCount) / Double(samples.count) > 0.5 {
                    strokeIndices.append(index)
                }
            }

            let elementIDs = pageView.elementsView.elementIDs(withCentersIn: path)

            guard !strokeIndices.isEmpty || !elementIDs.isEmpty else {
                clearLassoSelection()
                return
            }

            var box = CGRect.null
            for index in strokeIndices {
                box = box.union(strokes[index].renderBounds)
            }
            for id in elementIDs {
                if let frame = pageView.elementsView.elementFrame(id: id) {
                    box = box.union(frame)
                }
            }
            guard !box.isNull else {
                clearLassoSelection()
                return
            }

            lassoStrokeIndices = strokeIndices
            lassoElementIDs = elementIDs
            lassoGroupBox = box.insetBy(dx: -8, dy: -8)
            lassoGroupActive = true
            UISelectionFeedbackGenerator().selectionChanged()
            pageView.lassoOverlayView.showGroup(box: lassoGroupBox)
            presentLassoMenu()
        }

        private func applyPendingStrokeTransform(
            translation: CGPoint,
            scale: CGFloat,
            anchor: CGPoint,
            on pageView: PageCanvasView
        ) {
            guard !lassoStrokeIndices.isEmpty,
                  translation != .zero || abs(scale - 1) > 0.001 else { return }
            let transform = CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale,
                tx: anchor.x * (1 - scale) + translation.x,
                ty: anchor.y * (1 - scale) + translation.y
            )
            var drawing = pageView.canvasView.drawing
            for index in lassoStrokeIndices where drawing.strokes.indices.contains(index) {
                drawing.strokes[index].transform =
                    drawing.strokes[index].transform.concatenating(transform)
            }
            isReplacingStroke = true
            pageView.canvasView.drawing = drawing
            isReplacingStroke = false
            parent.onDrawingChanged(pageView.pageID, drawing.dataRepresentation())
            parent.controller.refreshHistoryState()
        }

        private func scaled(_ rect: CGRect, by scale: CGFloat, about anchor: CGPoint) -> CGRect {
            CGRect(
                x: anchor.x + (rect.origin.x - anchor.x) * scale,
                y: anchor.y + (rect.origin.y - anchor.y) * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
        }

        func presentLassoMenu() {
            guard lassoGroupActive, let host, let pageView = lassoPageView else { return }
            let rectInHost = pageView.convert(lassoGroupBox, to: host)
            let configuration = UIEditMenuConfiguration(
                identifier: nil,
                sourcePoint: CGPoint(x: rectInHost.midX, y: rectInHost.minY - 8)
            )
            editMenuInteraction?.presentEditMenu(with: configuration)
        }

        func clearLassoSelection() {
            lassoMode = .idle
            lassoPathPoints = []
            lassoStrokeIndices = []
            lassoElementIDs = []
            lassoGroupBox = .null
            if lassoGroupActive {
                lassoGroupActive = false
                editMenuInteraction?.dismissMenu()
            }
            host?.pageViews.forEach { $0.lassoOverlayView.clearAll() }
            lassoPageView = nil
        }

        private func duplicateLassoGroup() {
            guard let pageView = lassoPageView else { return }
            if !lassoStrokeIndices.isEmpty {
                var drawing = pageView.canvasView.drawing
                let offset = CGAffineTransform(translationX: 24, y: 24)
                for index in lassoStrokeIndices where drawing.strokes.indices.contains(index) {
                    var copy = drawing.strokes[index]
                    copy.transform = copy.transform.concatenating(offset)
                    drawing.strokes.append(copy)
                }
                isReplacingStroke = true
                pageView.canvasView.drawing = drawing
                isReplacingStroke = false
                parent.onDrawingChanged(pageView.pageID, drawing.dataRepresentation())
            }
            pageView.elementsView.duplicateElements(ids: lassoElementIDs)
            clearLassoSelection()
        }

        private func deleteLassoGroup() {
            guard let pageView = lassoPageView else { return }
            if !lassoStrokeIndices.isEmpty {
                var drawing = pageView.canvasView.drawing
                for index in lassoStrokeIndices.sorted(by: >)
                where drawing.strokes.indices.contains(index) {
                    drawing.strokes.remove(at: index)
                }
                isReplacingStroke = true
                pageView.canvasView.drawing = drawing
                isReplacingStroke = false
                parent.onDrawingChanged(pageView.pageID, drawing.dataRepresentation())
            }
            pageView.elementsView.removeElements(ids: lassoElementIDs)
            clearLassoSelection()
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

// MARK: - Word annotation underlines

/// Draws colored underlines for saved dictionary words. Rects live in PDF
/// space, so underlines track their words through zoom and relayout.
final class AnnotationUnderlineView: UIView {
    var pageRef: CGPDFPage?
    private var annotations: [WordAnnotation] = []

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

    func setAnnotations(_ annotations: [WordAnnotation]) {
        guard self.annotations != annotations else { return }
        self.annotations = annotations
        setNeedsDisplay()
    }

    /// The annotation whose word area contains the given view-space point.
    func annotation(at point: CGPoint) -> WordAnnotation? {
        guard let transform = pageTransform() else { return nil }
        for annotation in annotations {
            for pdfRect in annotation.cgRects {
                let rect = viewRect(for: pdfRect, transform: transform).insetBy(dx: -4, dy: -6)
                if rect.contains(point) {
                    return annotation
                }
            }
        }
        return nil
    }

    override func draw(_ rect: CGRect) {
        guard !annotations.isEmpty,
              let transform = pageTransform(),
              let context = UIGraphicsGetCurrentContext() else { return }

        for annotation in annotations {
            let color = UIColor(hexString: annotation.colorHex)
            context.setFillColor(color.cgColor)
            for pdfRect in annotation.cgRects {
                let wordRect = viewRect(for: pdfRect, transform: transform)
                guard wordRect.width > 1 else { continue }
                let underline = CGRect(
                    x: wordRect.minX,
                    y: wordRect.maxY + 0.5,
                    width: wordRect.width,
                    height: 2.4
                )
                context.addPath(UIBezierPath(roundedRect: underline, cornerRadius: 1.2).cgPath)
                context.fillPath()
            }
        }
    }

    private func pageTransform() -> CGAffineTransform? {
        guard let pageRef else { return nil }
        return pageRef.getDrawingTransform(
            .mediaBox,
            rect: bounds,
            rotate: 0,
            preserveAspectRatio: true
        )
    }

    private func viewRect(for pdfRect: CGRect, transform: CGAffineTransform) -> CGRect {
        let cornerA = pdfRect.origin.applying(transform)
        let cornerB = CGPoint(x: pdfRect.maxX, y: pdfRect.maxY).applying(transform)
        return CGRect(
            x: min(cornerA.x, cornerB.x),
            y: bounds.height - max(cornerA.y, cornerB.y),
            width: abs(cornerB.x - cornerA.x),
            height: abs(cornerB.y - cornerA.y)
        )
    }
}

// MARK: - Lasso overlay

/// Visual layer for the custom lasso: the in-progress dashed path while
/// circling, and the dashed group box with corner knobs once a selection
/// exists. Purely visual — gestures are handled by the scroll view.
final class LassoOverlayView: UIView {
    private var pathPoints: [CGPoint] = []
    private var groupBox: CGRect = .null

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

    func updatePath(_ points: [CGPoint]) {
        pathPoints = points
        setNeedsDisplay()
    }

    func clearPath() {
        pathPoints = []
        setNeedsDisplay()
    }

    func showGroup(box: CGRect) {
        groupBox = box
        setNeedsDisplay()
    }

    func clearAll() {
        pathPoints = []
        groupBox = .null
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        if pathPoints.count > 1 {
            let path = UIBezierPath()
            path.move(to: pathPoints[0])
            for point in pathPoints.dropFirst() {
                path.addLine(to: point)
            }
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setLineWidth(2)
            context.setLineDash(phase: 0, lengths: [6, 4])
            context.addPath(path.cgPath)
            context.strokePath()
        }

        guard !groupBox.isNull else { return }
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [6, 4])
        context.addPath(UIBezierPath(roundedRect: groupBox, cornerRadius: 6).cgPath)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])

        let knobRadius: CGFloat = 6
        let corners = [
            CGPoint(x: groupBox.minX, y: groupBox.minY),
            CGPoint(x: groupBox.maxX, y: groupBox.minY),
            CGPoint(x: groupBox.minX, y: groupBox.maxY),
            CGPoint(x: groupBox.maxX, y: groupBox.maxY)
        ]
        for corner in corners {
            let knobRect = CGRect(
                x: corner.x - knobRadius,
                y: corner.y - knobRadius,
                width: knobRadius * 2,
                height: knobRadius * 2
            )
            context.setFillColor(UIColor.white.cgColor)
            context.fillEllipse(in: knobRect)
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: knobRect)
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
