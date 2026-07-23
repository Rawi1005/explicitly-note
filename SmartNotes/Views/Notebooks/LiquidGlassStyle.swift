import SwiftUI
import UIKit

extension View {
    /// Liquid Glass on iOS 26+, with a frosted-material fallback that keeps the
    /// same silhouette on earlier systems (e.g. iPadOS 17).
    @ViewBuilder
    func liquidGlass<S: InsettableShape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            // Borderless fallback: no outline, just frost and a whisper of depth.
            self
                .background(
                    shape
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
                )
        }
    }
}

extension View {
    /// Disables `delaysContentTouches` on the nearest enclosing `UIScrollView`.
    ///
    /// SwiftUI's `ScrollView` delays touches by default, so a button inside a
    /// horizontal toolbar scroll view eats the first tap (it's treated as the
    /// start of a possible scroll) and only responds on the second — the
    /// "have to double-tap the toolbar" bug. Attach this to the scroll content.
    func immediateScrollTouches() -> some View {
        background(ScrollTouchDelayDisabler())
    }
}

/// Walks up from an invisible probe view to find the host `UIScrollView` and
/// tells it to hand touches to its content buttons right away.
private struct ScrollTouchDelayDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        ScrollTouchDelayProbe()
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? ScrollTouchDelayProbe)?.configureNearestScrollView()
    }
}

/// SwiftUI may attach the representable after its first update pass, so a
/// one-shot asynchronous parent lookup is not reliable. Re-run the lookup as
/// the probe moves through the hierarchy to keep toolbar buttons single-tap.
private final class ScrollTouchDelayProbe: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        configureNearestScrollView()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        configureNearestScrollView()
    }

    func configureNearestScrollView() {
        DispatchQueue.main.async { [weak self] in
            var ancestor = self?.superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    scrollView.delaysContentTouches = false
                    scrollView.canCancelContentTouches = true
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

extension View {
    /// Marks this view as the origin of a zoom navigation transition (iOS 18+).
    /// Pair with `zoomNavigationDestination` on the pushed screen using the same
    /// id and namespace so the card visually expands into its destination.
    /// On iOS 17 it's a no-op and the standard push is used.
    @ViewBuilder
    func zoomTransitionSource(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Receiving half of `zoomTransitionSource` — apply to the pushed screen.
    @ViewBuilder
    func zoomNavigationDestination(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

/// Card-style press feedback used across the notebook library.
struct PressableCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}
