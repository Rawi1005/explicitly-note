import SwiftUI

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

/// Card-style press feedback used across the notebook library.
struct PressableCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}
