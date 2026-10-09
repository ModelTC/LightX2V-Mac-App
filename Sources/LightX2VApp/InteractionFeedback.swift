import SwiftUI

enum InteractionMotion {
    static func hover(reduced: Bool) -> Animation? {
        reduced ? nil : .easeOut(duration: 0.14)
    }
}

/// Feedback stays within the control's existing shape; it never moves its label.
private struct HoverFeedback: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    var pressed = false
    var radius: CGFloat = 8
    var bright = false
    var border = false

    private var active: Bool { enabled && hovered }

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .fill((bright ? Color.white : Color.black)
                        .opacity(enabled && pressed ? (bright ? 0.18 : 0.065) : active ? (bright ? 0.10 : 0.035) : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(active && border ? Palette.borderStrong.opacity(0.65) : .clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
            .animation(InteractionMotion.hover(reduced: reduceMotion), value: active)
            .animation(InteractionMotion.hover(reduced: reduceMotion), value: enabled && pressed)
    }
}

extension View {
    func hoverSurface(radius: CGFloat = 8, border: Bool = true) -> some View {
        modifier(HoverFeedback(radius: radius, border: border))
    }
}

struct HoverButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var radius: CGFloat = 8
    var bright = false
    var border = false
    var dimsWhenDisabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .modifier(HoverFeedback(pressed: configuration.isPressed, radius: radius, bright: bright, border: border))
            .opacity(enabled || !dimsWhenDisabled ? 1 : 0.45)
    }
}

/// Compact form actions use the same palette and feedback as the main window.
struct SettingsActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(enabled ? (prominent ? Palette.onButton : Palette.ink) : Palette.disabledInk)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(enabled && prominent ? Palette.button : Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(prominent ? .clear : Palette.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .modifier(HoverFeedback(pressed: configuration.isPressed, radius: 7, bright: prominent, border: !prominent))
    }
}
