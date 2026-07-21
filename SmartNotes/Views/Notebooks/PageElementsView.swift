import UIKit

/// Layer that hosts the movable text boxes and photos on a notebook page.
/// Sits between the PDF background and the PencilKit canvas; interactive only
/// while a non-drawing tool (hand or text) is selected.
///
/// Selected elements show corner resize handles and support move, rotate
/// (two-finger twist), proportional scaling, duplication, image cropping, and
/// text styling through the system edit menu.
@MainActor
final class PageElementsView: UIView, UIEditMenuInteractionDelegate {
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
    private var menuElementID: UUID?
    private var editMenuInteraction: UIEditMenuInteraction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let interaction = UIEditMenuInteraction(delegate: self)
        addInteraction(interaction)
        editMenuInteraction = interaction
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
    func addTextElement(at point: CGPoint, fontSize: Double, initialText: String = "") -> PageElement {
        var element = PageElement.textElement(at: point, fontSize: fontSize)
        element.text = initialText
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

    func duplicateElement(id: UUID) {
        guard let element = elements.first(where: { $0.id == id }) else { return }
        let copy = element.duplicated()
        elements.append(copy)
        attachView(for: copy)
        selectElement(copy.id)
        persist()
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
        if id == nil {
            editMenuInteraction?.dismissMenu()
        }
    }

    func deselect() {
        selectElement(nil)
    }

    // MARK: - Group support (used by the lasso tool)

    func elementIDs(withCentersIn path: UIBezierPath) -> [UUID] {
        elements
            .filter { path.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            .map(\.id)
    }

    func elementFrame(id: UUID) -> CGRect? {
        elements.first { $0.id == id }?.frame
    }

    /// Applies a translation and scale (about `anchor`) to the given elements.
    func transformElements(ids: [UUID], translation: CGPoint, scale: CGFloat, anchor: CGPoint) {
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let index = elements.firstIndex(where: { $0.id == id }) else { continue }
            var element = elements[index]
            var frame = element.frame
            frame.origin.x = anchor.x + (frame.origin.x - anchor.x) * scale + translation.x
            frame.origin.y = anchor.y + (frame.origin.y - anchor.y) * scale + translation.y
            frame.size.width *= scale
            frame.size.height *= scale
            element.frame = frame
            if element.kind == .text {
                element.fontSize = min(max(element.fontSize * scale, 6), 200)
            }
            elements[index] = element
            elementViews[id]?.reload(from: element)
        }
        persist()
    }

    func duplicateElements(ids: [UUID]) {
        for id in ids {
            guard let element = elements.first(where: { $0.id == id }) else { continue }
            let copy = element.duplicated()
            elements.append(copy)
            attachView(for: copy)
        }
        persist()
    }

    func removeElements(ids: [UUID]) {
        for id in ids {
            elements.removeAll { $0.id == id }
            elementViews[id]?.removeFromSuperview()
            elementViews[id] = nil
        }
        persist()
    }

    // MARK: - View management

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
        view.onMenuRequest = { [weak self] id in
            self?.presentMenu(for: id)
        }
        view.isInteractionAllowedProvider = { [weak self] in
            self?.isInteractionAllowed ?? false
        }
        addSubview(view)
        elementViews[element.id] = view
        return view
    }

    // MARK: - Edit menu

    private func presentMenu(for id: UUID) {
        guard let view = elementViews[id] else { return }
        menuElementID = id
        let topCenter = CGPoint(x: view.center.x, y: view.center.y - view.bounds.height / 2 - 8)
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: topCenter)
        editMenuInteraction?.presentEditMenu(with: configuration)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let id = menuElementID,
              let element = elements.first(where: { $0.id == id }),
              let view = elementViews[id] else { return nil }

        var children: [UIMenuElement] = []

        if element.kind == .text {
            children.append(UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { _ in
                view.beginTextEditing()
            })
            children.append(contentsOf: textStyleActions(for: element, view: view))
        } else {
            children.append(contentsOf: imageActions(for: element, view: view))
        }

        children.append(UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
            self?.duplicateElement(id: id)
        })
        children.append(UIAction(
            title: "Delete",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.removeElement(id: id)
        })

        return UIMenu(children: children)
    }

    private func imageActions(for element: PageElement, view: ElementItemView) -> [UIMenuElement] {
        var actions: [UIMenuElement] = []
        actions.append(UIAction(
            title: view.isCropping ? "Done Cropping" : "Crop",
            image: UIImage(systemName: "crop")
        ) { _ in
            view.toggleCropMode()
        })
        if element.cropRect != nil {
            actions.append(UIAction(title: "Reset Crop", image: UIImage(systemName: "arrow.uturn.backward.circle")) { _ in
                view.resetCrop()
            })
        }
        return actions
    }

    private func textStyleActions(for element: PageElement, view: ElementItemView) -> [UIMenuElement] {
        let sizeMenu = UIMenu(title: "Size", image: UIImage(systemName: "textformat.size"), children: [
            UIAction(title: "Smaller", image: UIImage(systemName: "minus")) { _ in
                view.modifyElement { $0.fontSize = max($0.fontSize - 2, 8) }
            },
            UIAction(title: "Larger", image: UIImage(systemName: "plus")) { _ in
                view.modifyElement { $0.fontSize = min($0.fontSize + 2, 120) }
            }
        ])

        let styleMenu = UIMenu(title: "Style", image: UIImage(systemName: "bold.italic.underline"), children: [
            UIAction(title: "Bold", state: element.isBold == true ? .on : .off) { _ in
                view.modifyElement { $0.isBold = ($0.isBold == true) ? false : true }
            },
            UIAction(title: "Italic", state: element.isItalic == true ? .on : .off) { _ in
                view.modifyElement { $0.isItalic = ($0.isItalic == true) ? false : true }
            }
        ])

        let fonts: [(String, String)] = [
            ("System", "system"), ("Serif", "serif"), ("Rounded", "rounded"), ("Mono", "mono")
        ]
        let fontMenu = UIMenu(title: "Font", image: UIImage(systemName: "textformat"), children: fonts.map { label, key in
            UIAction(title: label, state: (element.fontDesign ?? "system") == key ? .on : .off) { _ in
                view.modifyElement { $0.fontDesign = key }
            }
        })

        let alignments: [(String, String, String)] = [
            ("Left", "left", "text.alignleft"),
            ("Center", "center", "text.aligncenter"),
            ("Right", "right", "text.alignright")
        ]
        let alignMenu = UIMenu(title: "Align", image: UIImage(systemName: "text.aligncenter"), children: alignments.map { label, key, icon in
            UIAction(
                title: label,
                image: UIImage(systemName: icon),
                state: (element.alignment ?? "left") == key ? .on : .off
            ) { _ in
                view.modifyElement { $0.alignment = key }
            }
        })

        let colors: [(String, String)] = [
            ("Black", "#000000"), ("Blue", "#0A84FF"), ("Red", "#FF3B30"),
            ("Green", "#34C759"), ("Orange", "#FF9500")
        ]
        let colorMenu = UIMenu(title: "Color", image: UIImage(systemName: "paintpalette"), children: colors.map { label, hex in
            UIAction(title: label, state: element.colorHex.uppercased() == hex ? .on : .off) { _ in
                view.modifyElement { $0.colorHex = hex }
            }
        })

        return [sizeMenu, styleMenu, fontMenu, alignMenu, colorMenu]
    }
}

// MARK: - Individual element view

@MainActor
final class ElementItemView: UIView, UITextViewDelegate {
    private var element: PageElement
    var onChanged: ((PageElement) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onSelectRequest: ((UUID) -> Void)?
    var onMenuRequest: ((UUID) -> Void)?
    var isInteractionAllowedProvider: (() -> Bool)?

    private(set) var isCropping = false

    private let contentPadding: CGFloat = 8
    private let borderLayer = CAShapeLayer()
    private let deleteButton = UIButton(type: .system)
    private var cornerHandles: [ResizeHandleView] = []
    private var textView: UITextView?
    private var imageView: UIImageView?
    private var isSelected = false

    private var pinchStartSize: CGSize = .zero
    private var pinchStartFontSize: Double = 18
    private var cornerStartSize: CGSize = .zero

    init(element: PageElement, image: UIImage?) {
        self.element = element
        let paddedSize = CGSize(
            width: element.frame.width + 16,
            height: element.frame.height + 16
        )
        super.init(frame: CGRect(origin: .zero, size: paddedSize))
        center = CGPoint(x: element.frame.midX, y: element.frame.midY)
        transform = CGAffineTransform(rotationAngle: element.rotationAngle)
        backgroundColor = .clear

        switch element.kind {
        case .text:
            let textView = UITextView()
            textView.backgroundColor = .clear
            textView.isScrollEnabled = false
            textView.delegate = self
            textView.textContainerInset = UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
            textView.isEditable = false
            addSubview(textView)
            self.textView = textView
        case .image:
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleToFill
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

        for corner in 0..<4 {
            let handle = ResizeHandleView()
            handle.tag = corner
            handle.isHidden = true
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleCornerPan(_:)))
            handle.addGestureRecognizer(pan)
            addSubview(handle)
            cornerHandles.append(handle)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(longPress)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        addGestureRecognizer(rotate)

        applyElementAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let contentFrame = bounds.insetBy(dx: contentPadding, dy: contentPadding)
        textView?.frame = contentFrame
        imageView?.frame = contentFrame
        borderLayer.frame = bounds
        borderLayer.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 4, dy: 4),
            cornerRadius: 6
        ).cgPath
        deleteButton.frame = CGRect(x: bounds.maxX - 22, y: 0, width: 22, height: 22)

        let corners = [
            CGPoint(x: bounds.minX + 4, y: bounds.minY + 4),
            CGPoint(x: bounds.maxX - 4, y: bounds.minY + 4),
            CGPoint(x: bounds.minX + 4, y: bounds.maxY - 4),
            CGPoint(x: bounds.maxX - 4, y: bounds.maxY - 4)
        ]
        for (index, handle) in cornerHandles.enumerated() {
            handle.center = corners[index]
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isInteractionAllowedProvider?() == true else { return nil }
        // Handles are small; give them a generous grab area when visible.
        for handle in cornerHandles where !handle.isHidden {
            if handle.frame.insetBy(dx: -14, dy: -14).contains(point) {
                return handle
            }
        }
        return super.hitTest(point, with: event)
    }

    // MARK: State

    func setSelected(_ selected: Bool) {
        isSelected = selected
        borderLayer.isHidden = !selected
        deleteButton.isHidden = !selected
        cornerHandles.forEach { $0.isHidden = !selected }
        if !selected {
            if isCropping {
                isCropping = false
            }
            if let textView, textView.isFirstResponder {
                textView.resignFirstResponder()
            }
        }
        borderLayer.strokeColor = (selected && isCropping)
            ? UIColor.systemOrange.cgColor
            : UIColor.tintColor.cgColor
    }

    func beginTextEditing() {
        guard let textView else { return }
        textView.isEditable = true
        textView.becomeFirstResponder()
    }

    func toggleCropMode() {
        guard element.kind == .image else { return }
        isCropping.toggle()
        borderLayer.strokeColor = isCropping ? UIColor.systemOrange.cgColor : UIColor.tintColor.cgColor
    }

    func resetCrop() {
        element.cropRect = nil
        applyElementAppearance()
        commitGeometry()
    }

    /// Mutates the backing element (used by the style menu) and refreshes.
    func modifyElement(_ change: (inout PageElement) -> Void) {
        change(&element)
        applyElementAppearance()
        onChanged?(element)
    }

    /// Re-applies geometry and appearance from an externally updated element.
    func reload(from element: PageElement) {
        self.element = element
        bounds.size = CGSize(
            width: element.frame.width + contentPadding * 2,
            height: element.frame.height + contentPadding * 2
        )
        center = CGPoint(x: element.frame.midX, y: element.frame.midY)
        transform = CGAffineTransform(rotationAngle: element.rotationAngle)
        applyElementAppearance()
        setNeedsLayout()
    }

    private func applyElementAppearance() {
        if let textView {
            textView.font = element.font
            textView.textColor = UIColor(hexString: element.colorHex)
            textView.textAlignment = element.textAlignment
            if textView.text != element.text {
                textView.text = element.text
            }
        }
        if let imageView {
            if let crop = element.cropRect {
                imageView.layer.contentsRect = crop
            } else {
                imageView.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
        }
    }

    private func commitGeometry() {
        element.frame = CGRect(
            x: center.x - (bounds.width - contentPadding * 2) / 2,
            y: center.y - (bounds.height - contentPadding * 2) / 2,
            width: bounds.width - contentPadding * 2,
            height: bounds.height - contentPadding * 2
        )
        onChanged?(element)
    }

    // MARK: Gestures

    @objc private func handleTap() {
        if isSelected {
            if element.kind == .text {
                beginTextEditing()
            } else {
                onMenuRequest?(element.id)
            }
        } else {
            onSelectRequest?(element.id)
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onSelectRequest?(element.id)
        onMenuRequest?(element.id)
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
            commitGeometry()
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            onSelectRequest?(element.id)
            pinchStartSize = bounds.size
            pinchStartFontSize = element.fontSize
        case .changed:
            let scale = gesture.scale
            bounds.size = CGSize(
                width: max(pinchStartSize.width * scale, 44),
                height: max(pinchStartSize.height * scale, 36)
            )
            if element.kind == .text {
                element.fontSize = min(max(pinchStartFontSize * scale, 8), 160)
                textView?.font = element.font
            }
            setNeedsLayout()
        case .ended, .cancelled:
            commitGeometry()
        default:
            break
        }
    }

    @objc private func handleRotate(_ gesture: UIRotationGestureRecognizer) {
        switch gesture.state {
        case .began:
            onSelectRequest?(element.id)
        case .changed:
            element.rotationAngle += Double(gesture.rotation)
            transform = CGAffineTransform(rotationAngle: element.rotationAngle)
            gesture.rotation = 0
        case .ended, .cancelled:
            onChanged?(element)
        default:
            break
        }
    }

    @objc private func handleCornerPan(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view else { return }
        if isCropping, element.kind == .image {
            cropCornerPan(gesture, corner: handle.tag)
            return
        }

        switch gesture.state {
        case .began:
            cornerStartSize = bounds.size
        case .changed:
            let location = gesture.location(in: self)
            let halfWidth = max(abs(location.x - bounds.midX), 22)
            let halfHeight = max(abs(location.y - bounds.midY), 18)
            if element.kind == .image {
                // Proportional from corners.
                let scale = max(
                    halfWidth * 2 / max(cornerStartSize.width, 1),
                    halfHeight * 2 / max(cornerStartSize.height, 1)
                )
                bounds.size = CGSize(
                    width: max(cornerStartSize.width * scale, 44),
                    height: max(cornerStartSize.height * scale, 36)
                )
            } else {
                bounds.size = CGSize(width: halfWidth * 2, height: halfHeight * 2)
            }
            setNeedsLayout()
        case .ended, .cancelled:
            commitGeometry()
        default:
            break
        }
    }

    /// In crop mode, corner drags trim the image: the crop rect and the box
    /// shrink together so the remaining content stays in place.
    private func cropCornerPan(_ gesture: UIPanGestureRecognizer, corner: Int) {
        guard gesture.state == .changed || gesture.state == .ended || gesture.state == .cancelled else { return }
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)

        let contentWidth = max(bounds.width - contentPadding * 2, 1)
        let contentHeight = max(bounds.height - contentPadding * 2, 1)
        var crop = element.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)

        // Which edges this corner controls: 0 TL, 1 TR, 2 BL, 3 BR.
        let movesLeft = corner == 0 || corner == 2
        let movesTop = corner == 0 || corner == 1

        var dLeft: CGFloat = 0
        var dRight: CGFloat = 0
        var dTop: CGFloat = 0
        var dBottom: CGFloat = 0
        if movesLeft { dLeft = translation.x } else { dRight = -translation.x }
        if movesTop { dTop = translation.y } else { dBottom = -translation.y }

        // Clamp so at least 15% of the image remains in each dimension.
        let minWidth = contentWidth * 0.15
        let minHeight = contentHeight * 0.15
        dLeft = min(dLeft, contentWidth - minWidth - dRight)
        dRight = min(dRight, contentWidth - minWidth - dLeft)
        dTop = min(dTop, contentHeight - minHeight - dBottom)
        dBottom = min(dBottom, contentHeight - minHeight - dTop)
        dLeft = max(dLeft, -crop.origin.x / crop.width * contentWidth)
        dTop = max(dTop, -crop.origin.y / crop.height * contentHeight)
        dRight = max(dRight, -(1 - crop.maxX) / crop.width * contentWidth)
        dBottom = max(dBottom, -(1 - crop.maxY) / crop.height * contentHeight)

        crop.origin.x += dLeft / contentWidth * crop.width
        crop.size.width -= (dLeft + dRight) / contentWidth * crop.width
        crop.origin.y += dTop / contentHeight * crop.height
        crop.size.height -= (dTop + dBottom) / contentHeight * crop.height
        element.cropRect = crop

        bounds.size = CGSize(
            width: bounds.width - dLeft - dRight,
            height: bounds.height - dTop - dBottom
        )
        // Shift the center so the kept region stays put (respecting rotation).
        let localShift = CGPoint(x: (dLeft - dRight) / 2, y: (dTop - dBottom) / 2)
        let worldShift = localShift.applying(CGAffineTransform(rotationAngle: element.rotationAngle))
        center = CGPoint(x: center.x + worldShift.x, y: center.y + worldShift.y)

        applyElementAppearance()
        setNeedsLayout()

        if gesture.state != .changed {
            commitGeometry()
        }
    }

    @objc private func deleteTapped() {
        onDelete?(element.id)
    }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        element.text = textView.text
        let fitted = textView.sizeThatFits(
            CGSize(width: textView.frame.width, height: .greatestFiniteMagnitude)
        )
        if fitted.height > textView.frame.height {
            let growth = fitted.height - textView.frame.height
            bounds.size.height += growth
            // Keep the top edge fixed while the box grows downward.
            let worldShift = CGPoint(x: 0, y: growth / 2)
                .applying(CGAffineTransform(rotationAngle: element.rotationAngle))
            center = CGPoint(x: center.x + worldShift.x, y: center.y + worldShift.y)
            setNeedsLayout()
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        textView.isEditable = false
        element.text = textView.text
        if element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onDelete?(element.id)
        } else {
            commitGeometry()
        }
    }
}

/// Small circular corner handle used for resizing and cropping.
final class ResizeHandleView: UIView {
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 14, height: 14))
        backgroundColor = .white
        layer.cornerRadius = 7
        layer.borderWidth = 2
        layer.borderColor = UIColor.tintColor.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
