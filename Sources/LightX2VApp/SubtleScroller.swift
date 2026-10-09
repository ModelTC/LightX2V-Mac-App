import AppKit
import SwiftUI

/// Draw only the thumb; AppKit retains scrolling, dragging and accessibility.
final class SubtleScroller: NSScroller {
    private var hovered = false
    private var dragging = false
    private var pointerArea: NSTrackingArea?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func draw(_ dirtyRect: NSRect) { drawKnob() }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        guard isEnabled, knobProportion < 1 else { return }
        var thumb = rect(for: .knob)
        guard !thumb.isEmpty else { return }
        // A six-point visual thumb inside the full native drag target.
        if bounds.height >= bounds.width {
            thumb.origin.x = bounds.midX - 3
            thumb.size.width = 6
        } else {
            thumb.origin.y = bounds.midY - 3
            thumb.size.height = 6
        }
        NSColor(Palette.scrollThumb).withAlphaComponent(dragging ? 0.7 : hovered ? 0.5 : 0.25).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 3, yRadius: 3).fill()
    }

    override func updateTrackingAreas() {
        if let pointerArea { removeTrackingArea(pointerArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true; NSCursor.arrow.set() }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        needsDisplay = true
        super.mouseDown(with: event)
        dragging = false
        needsDisplay = true
    }

    static func install(on scrollView: NSScrollView) {
        for horizontal in [false, true] {
            let current = horizontal ? scrollView.horizontalScroller : scrollView.verticalScroller
            guard let current, !(current is SubtleScroller) else { continue }
            let scroller = SubtleScroller(frame: current.frame)
            scroller.controlSize = current.controlSize
            scroller.knobProportion = current.knobProportion
            scroller.doubleValue = current.doubleValue
            if horizontal { scrollView.horizontalScroller = scroller }
            else { scrollView.verticalScroller = scroller }
        }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
    }
}

extension View {
    /// Attach to the content inside a SwiftUI ScrollView, not its outer frame.
    func subtleScrollbars() -> some View { background(ScrollStyleAnchor()) }
}

private struct ScrollStyleAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.scheduleStyle() }

    final class AnchorView: NSView {
        private var scheduled = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleStyle() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleStyle() }

        func scheduleStyle() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                if let scrollView = self.enclosingScrollView { SubtleScroller.install(on: scrollView) }
            }
        }
    }
}
