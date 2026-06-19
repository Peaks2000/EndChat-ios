import SwiftUI

struct AdaptiveGlass: ViewModifier {
    var radius: CGFloat = 28

    func body(content: Content) -> some View {
        // Keep Liquid Glass optional. Xcode/iOS versions that do not know the
        // iOS 26 glass APIs compile and run through the material fallback.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(.white.opacity(0.25), lineWidth: 1)
            )
    }
}

extension View {
    func adaptiveGlass(radius: CGFloat = 28) -> some View {
        modifier(AdaptiveGlass(radius: radius))
    }
}
