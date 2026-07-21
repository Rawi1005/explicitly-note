import UIKit

/// Native-style PDF text selection chrome: translucent blue line highlights
/// plus draggable start/end lollipop handles, drawn per page above the ink.
/// The selection itself comes from the PDF's real text layer (PDFSelection).
final class TextSelectionOverlayView: UIView {
    var onHandleMoved: ((_ isStartHandle: Bool, _ location: CGPoint) -> Void)?
    var onHandleDragEnded: (() -> Void)?

    private(set) var selectionRects: [CGRect] = []
    private let startHandle = SelectionHandleView(isStart: true)
    private let endHandle = SelectionHandleView(isStart: false)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        startHandle.isHidden = true
        endHandle.isHidden = true
        addSubview(startHandle)
        addSubview(endHandle)

        for handle in [startHandle, endHandle] {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            handle.addGestureRecognizer(pan)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var hasSelection: Bool {
        !selectionRects.isEmpty
    }

    var selectionBoundingRect: CGRect {
        selectionRects.reduce(CGRect.null) { $0.union($1) }
    }

    func show(rects: [CGRect]) {
        selectionRects = rects
        guard let first = rects.first, let last = rects.last else {
            clear()
            return
        }
        startHandle.isHidden = false
        endHandle.isHidden = false
        startHandle.place(onLineRect: first)
        endHandle.place(onLineRect: last)
        setNeedsDisplay()
    }

    func clear() {
        guard hasSelection || !startHandle.isHidden else { return }
        selectionRects = []
        startHandle.isHidden = true
        endHandle.isHidden = true
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !selectionRects.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.25).cgColor)
        for selectionRect in selectionRects {
            context.addPath(UIBezierPath(roundedRect: selectionRect, cornerRadius: 2).cgPath)
        }
        context.fillPath()
    }

    /// Only the handles are touchable; everything else passes through so
    /// scrolling, taps, and element gestures keep working.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for handle in [startHandle, endHandle] where !handle.isHidden {
            if handle.frame.insetBy(dx: -18, dy: -18).contains(point) {
                return handle
            }
        }
        return nil
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view as? SelectionHandleView else { return }
        switch gesture.state {
        case .began, .changed:
            onHandleMoved?(handle.isStart, gesture.location(in: self))
        case .ended, .cancelled:
            onHandleDragEnded?()
        default:
            break
        }
    }
}

/// One draggable selection handle: a vertical bar with a round knob, knob on
/// top for the start handle and on the bottom for the end handle (iOS style).
final class SelectionHandleView: UIView {
    let isStart: Bool
    private let knobDiameter: CGFloat = 10
    private let handleWidth: CGFloat = 22

    init(isStart: Bool) {
        self.isStart = isStart
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func place(onLineRect rect: CGRect) {
        if isStart {
            frame = CGRect(
                x: rect.minX - handleWidth / 2,
                y: rect.minY - knobDiameter - 1,
                width: handleWidth,
                height: rect.height + knobDiameter + 1
            )
        } else {
            frame = CGRect(
                x: rect.maxX - handleWidth / 2,
                y: rect.minY,
                width: handleWidth,
                height: rect.height + knobDiameter + 1
            )
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.systemBlue.cgColor)

        let barRect = CGRect(
            x: bounds.midX - 1,
            y: isStart ? knobDiameter : 0,
            width: 2,
            height: bounds.height - knobDiameter
        )
        context.fill(barRect)

        let knobRect = CGRect(
            x: bounds.midX - knobDiameter / 2,
            y: isStart ? 0 : bounds.height - knobDiameter,
            width: knobDiameter,
            height: knobDiameter
        )
        context.fillEllipse(in: knobRect)
    }
}
