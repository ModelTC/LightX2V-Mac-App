import AppKit
import SwiftUI

/// Own the inspector's viewport so showing a scroller never changes the width
/// proposed to its cards. SwiftUI's scroll container can reserve a gutter during
/// disclosure before the native scroller style is applied.
struct InspectorScrollView<Content: View>: NSViewRepresentable {
    let focus: Int
    @ViewBuilder var content: Content

    func makeCoordinator() -> Coordinator { Coordinator(focus: focus) }

    func makeNSView(context: Context) -> NativeInspectorScrollView<Content> {
        NativeInspectorScrollView(content: content)
    }

    func updateNSView(_ view: NativeInspectorScrollView<Content>, context: Context) {
        view.host.rootView = content
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            DispatchQueue.main.async { [weak view] in view?.scrollToTop() }
        }
    }

    final class Coordinator {
        var focus: Int
        init(focus: Int) { self.focus = focus }
    }
}

final class NativeInspectorScrollView<Content: View>: NSScrollView {
    let host: NSHostingView<Content>

    // AppKit can update the style when the system scrollbar preference changes.
    // This panel consistently uses an overlay, including "Always" scrollbars.
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }

    init(content: Content) {
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        verticalScroller = SubtleScroller()
        scrollerStyle = .overlay
        autohidesScrollers = true
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        horizontalScrollElasticity = .none
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        documentView = host
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            host.topAnchor.constraint(equalTo: contentView.topAnchor),
            host.widthAnchor.constraint(equalTo: contentView.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func scrollToTop() {
        layoutSubtreeIfNeeded()
        contentView.scroll(to: NSPoint(x: 0, y: host.isFlipped ? 0 : max(0, host.frame.height - contentView.bounds.height)))
        reflectScrolledClipView(contentView)
    }
}
