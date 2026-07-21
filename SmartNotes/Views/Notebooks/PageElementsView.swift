import UIKit

/// Layer that hosts the movable text boxes and photos on a notebook page.
/// Sits between the PDF background and the PencilKit canvas; interactive only
/// while a non-drawing tool (hand or text) is selected.
@MainActor
final class PageElementsView: UIView {
    private(set) var elements: [PageElement] = []
    var onElementsChanged: (([PageElement]) -> Void)?
    var imageProvider: ((String) -> UIImage?)?

    var isInteractionAllowed = false {
        didSet {
            guard oldValue != isInteractionAllowed else { return }
            if !isInteractionAllowed {
                selectElement(nil)
            }
        }
    }

    private var elementViews: [UUID: ElementItemView] = [:]
    private var selectedElementID: UUID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Empty regions pass touches through to the page (for scrolling/word taps).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self ? nil : view
    }

    // MARK: - Loading & persistence

    func load(elements: [PageElement]) {
        self.elements = elements
        elementViews.values.forEach { $0.removeFromSuperview() }
        elementViews = [:]
        selectedElementID = nil
        for element in elements {
            attachView(for: element)
        }
    }

    private func persist() {
        onElementsChanged?(elements)
    }

    private func updateElement(_ element: PageElement) {
        guard let index = elements.firstIndex(where: { $0.id == element.id }) else { return }
        elements[index] = element
        persist()
    }

    // MARK: - Adding elements

    @discardableResult
    func addTextElement(at point: CGPoint, fontSize: Double) -> PageElement {
        var element = PageElement.textElement(at: point, fontSize: fontSize)
        element.frame.origin.x = min(max(0, element.frame.origin.x), max(bounds.width - element.frame.width, 0))
        element.frame.origin.y = min(max(0, element.frame.origin.y), max(bounds.height - element.frame.height, 0))
        elements.append(element)
        let view = attachView(for: element)
        selectElement(element.id)
        view.beginTextEditing()
        persist()
        return element
    }

    @discardableResult
    func addImageElement(fileName: String, image: UIImage) -> PageElement {
        let maxSide = min(bounds.width, bounds.height) * 0.5
        let scale = min(1, maxSide / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let frame = CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        let element = PageElement.imageElement(frame: frame, fileName: fileName)
        elements.append(element)
        attachView(for: element)
        selectElement(element.id)
        persist()
        return element
    }

    func removeElement(id: UUID) {
        elements.removeAll { $0.id == id }
        elementViews[id]?.removeFromSuperview()
        elementViews[id] = nil
        if selectedElementID == id {
            selectedElementID = nil
        }
        persist()
    }

    func selectElement(_ id: UUID?) {
        selectedElementID = id
        for (elementID, view) in elementViews {
            view.setSelected(elementID == id)
        }
    }

    func deselect() {
        selectElement(nil)
    }

    @discardableResult
    private func attachView(for element: PageElement) -> ElementItemView {
        let image = element.imageFileName.flatMap { imageProvider?($0) }
        let view = ElementItemView(element: element, image: image)
        view.onChanged = { [weak self] updated in
            self?.updateElement(updated)
        }
        view.onDelete = { [weak self] id in
            self?.removeElement(id: id)
        }
        view.onSelectRequest = { [weak self] id in
            self?.selectElement(id)
        }
        view.isInteractionAllowedProvider = { [weak self] in
            self?.isInteractionAllowed ?? false
        }
        addSubview(view)
        elementViews[element.id] = view
        return view
    }
}

// MARK: - Individual element view

@MainActor
private final class ElementItemView: UIView, UITextViewDelegate {
    private var element: PageElement
    var onChanged: ((PageElement) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onSelectRequest: ((UUID) -> Void)?
    var isInteractionAllowedProvider: (() -> Bool)?

    private let borderLayer = CAShapeLayer()
    private let deleteButton = UIButton(type: .system)
    private var textView: UITextView?
    private var imageView: UIImageView?
    private var isSelected = false
    private var pinchStartFrame: CGRect = .zero
    private var pinchStartFontSize: Double = 18

    init(element: PageElement, image: UIImage?) {
        self.element = element
        super.init(frame: element.frame.insetBy(dx: -8, dy: -8))
        backgroundColor = .clear

        switch element.kind {
        case .text:
            let textView = UITextView()
            textView.backgroundColor = .clear
            textView.isScrollEnabled = false
            textView.font = .systemFont(ofSize: element.fontSize)
            textView.textColor = UIColor(hexString: element.colorHex)
            textView.text = element.text
            textView.delegate = self
            textView.textContainerInset = UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
            textView.isEditable = false
            addSubview(textView)
            self.textView = textView
        case .image:
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 4
            addSubview(imageView)
            self.imageView = imageView
        }

        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.strokeColor = UIColor.tintColor.cgColor
        borderLayer.lineWidth = 1.5
        borderLayer.lineDashPattern = [5, 4]
        borderLayer.isHidden = true
        layer.addSublayer(borderLayer)

        var deleteConfiguration = UIButton.Configuration.filled()
        deleteConfiguration.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        )
        deleteConfiguration.cornerStyle = .capsule
        deleteConfiguration.baseBackgroundColor = .systemRed
        deleteConfiguration.baseForegroundColor = .white
        deleteConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        deleteButton.configuration = deleteConfiguration
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        deleteButton.isHidden = true
        deleteButton.accessibilityLabel = "Delete Element"
        addSubview(deleteButton)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let contentFrame = bounds.insetBy(dx: 8, dy: 8)
        textView?.frame = contentFrame
        imageView?.frame = contentFrame
        borderLayer.frame = bounds
        borderLayer.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 4, dy: 4),
            cornerRadius: 6
        ).cgPath
        deleteButton.frame = CGRect(x: bounds.maxX - 22, y: 0, width: 22, height: 22)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isInteractionAllowedProvider?() == true else { return nil }
        return super.hitTest(point, with: event)
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        borderLayer.isHidden = !selected
        deleteButton.isHidden = !selected
        if !selected, let textView, textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    func beginTextEditing() {
        guard let textView else { return }
        textView.isEditable = true
        textView.becomeFirstResponder()
    }

    // MARK: - Gestures

    @objc private func handleTap() {
        if isSelected, element.kind == .text {
            beginTextEditing()
        } else {
            onSelectRequest?(element.id)
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { return }
        if gesture.state == .began {
            onSelectRequest?(element.id)
        }
        let translation = gesture.translation(in: superview)
        center = CGPoint(x: center.x + translation.x, y: center.y + translation.y)
        gesture.setTranslation(.zero, in: superview)
        if gesture.state == .ended || gesture.state == .cancelled {
            commitFrame()
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            onSelectRequest?(element.id)
            pinchStartFrame = frame
            pinchStartFontSize = element.fontSize
        case .changed:
            let scale = gesture.scale
            let newWidth = max(pinchStartFrame.width * scale, 40)
            let newHeight = max(pinchStartFrame.height * scale, 30)
            let centerPoint = CGPoint(x: pinchStartFrame.midX, y: pinchStartFrame.midY)
            frame = CGRect(
                x: centerPoint.x - newWidth / 2,
                y: centerPoint.y - newHeight / 2,
                width: newWidth,
                height: newHeight
            )
            if element.kind == .text {
                let newFontSize = min(max(pinchStartFontSize * scale, 9), 96)
                element.fontSize = newFontSize
                textView?.font = .systemFont(ofSize: newFontSize)
            }
            setNeedsLayout()
        case .ended, .cancelled:
            commitFrame()
        default:
            break
        }
    }

    @objc private func deleteTapped() {
        onDelete?(element.id)
    }

    private func commitFrame() {
        element.frame = frame.insetBy(dx: 8, dy: 8)
        onChanged?(element)
    }

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        element.text = textView.text
        // Grow the box vertically to fit the text.
        let fitted = textView.sizeThatFits(
            CGSize(width: textView.frame.width, height: .greatestFiniteMagnitude)
        )
        if fitted.height > textView.frame.height {
            var newFrame = frame
            newFrame.size.height = fitted.height + 16
            frame = newFrame
            setNeedsLayout()
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        textView.isEditable = false
        element.text = textView.text
        if element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onDelete?(element.id)
        } else {
            commitFrame()
        }
    }
}
