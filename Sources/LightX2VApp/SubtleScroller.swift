import AppKit
import SwiftUI

/// Draw only the thumb; AppKit retains scrolling, dragging and accessibility.
final class SubtleScroller: NSScroller {
    private(set) var hovered = false
    private var dragging = false
    private var pointerArea: NSTrackingArea?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func draw(_ dirtyRect: NSRect) { drawKnob() }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        guard isEnabled, knobProportion < 1 else { return }
        // Overlay scrollers can change their tracking regions while the pointer
        // is stationary. Resolve the actual position again before painting.
        if let window { refreshHover(at: window.mouseLocationOutsideOfEventStream) }
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
        super.updateTrackingAreas()
        // inVisibleRect follows resizing itself. Replacing this area on every
        // layout can send an exit for the old area while the mouse is still here.
        if pointerArea == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            pointerArea = area
        }
        if let window { refreshHover(at: window.mouseLocationOutsideOfEventStream) }
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea !== pointerArea { super.mouseEntered(with: event) }
        refreshHover(at: event.locationInWindow)
        NSCursor.arrow.set()
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea !== pointerArea { super.mouseExited(with: event) }
        // NSScroller also owns tracking areas for its knob and slot. Leaving one
        // of those areas does not mean the pointer has left the whole scroller.
        refreshHover(at: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        refreshHover(at: event.locationInWindow)
    }

    private func refreshHover(at windowPoint: NSPoint) {
        let inside = !isHiddenOrHasHiddenAncestor && visibleRect.contains(convert(windowPoint, from: nil))
        if hovered != inside { hovered = inside; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        needsDisplay = true
        super.mouseDown(with: event)
        dragging = false
        if let window { refreshHover(at: window.mouseLocationOutsideOfEventStream) }
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
