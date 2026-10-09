import SwiftUI

/// Reveals content in place, inside its own changing bounds. The content is
/// always laid out at its natural height, so controls never squeeze or slide
/// through the section header while the surrounding stack changes height.
struct ClippedReveal<Content: View>: View {
    let progress: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        RevealLayout(progress: progress) { content }
            .clipped()
            .contentShape(Rectangle())
            .opacity(progress)
            .allowsHitTesting(progress > 0)
            .disabled(progress == 0)
            .accessibilityHidden(progress == 0)
    }
}

private struct RevealLayout: Layout {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * min(1, max(0, progress)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
