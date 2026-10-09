import AppKit
import SwiftUI

/// Draw only the thumb; AppKit retains scrolling, dragging and accessibility.
final class SubtleScroller: NSScroller {
    private(set) var hovered = false
    private var dragging = false
    private var pointerLocation: NSPoint?
    private var eventMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var windowArea: NSTrackingArea?
    private weak var trackingView: NSView?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    /// The visual hover target is the thumb, not NSScroller's wider drag target.
    var thumbRect: NSRect {
        var thumb = rect(for: .knob)
        guard !thumb.isEmpty else { return .zero }
        if bounds.height >= bounds.width {
            thumb.origin.x = bounds.midX - 3
            thumb.size.width = 6
        } else {
            thumb.origin.y = bounds.midY - 3
            thumb.size.height = 6
        }
        return thumb.intersection(visibleRect)
    }

    override func draw(_ dirtyRect: NSRect) { drawKnob() }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        // Scrolling or resizing can move the thumb under a stationary pointer.
        refreshHover()
        guard isEnabled, knobProportion < 1, !thumbRect.isEmpty else { return }
        NSColor(Palette.scrollThumb).withAlphaComponent(dragging ? 0.7 : hovered ? 0.5 : 0.25).setFill()
        NSBezierPath(roundedRect: thumbRect, xRadius: 3, yRadius: 3).fill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingPointer()
        guard let window, let contentView = window.contentView else { return }
        window.acceptsMouseMovedEvents = true
        // Observe moves throughout the window: overlay scrollers can replace their
        // own tracking regions, so their mouseExited events are not a reliable reset.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .scrollWheel
        ]) { [weak self] event in
            self?.observePointerEvent(event)
            return event
        }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self)
        contentView.addTrackingArea(area)
        trackingView = contentView
        windowArea = area
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.clearPointer()
            })
        }
        windowObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.clearPointer()
        })
    }

    deinit { stopObservingPointer() }

    private func stopObservingPointer() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let windowArea { trackingView?.removeTrackingArea(windowArea) }
        windowArea = nil
        trackingView = nil
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        clearPointer()
    }

    // Kept separate from the monitor to exercise real AppKit geometry in tests.
    func observePointerEvent(_ event: NSEvent) {
        guard let window, event.window === window else { clearPointer(); return }
        pointerLocation = event.locationInWindow
        refreshHover()
    }

    private func refreshHover() {
        let inside: Bool
        if let pointerLocation, window != nil, isEnabled, knobProportion < 1,
           !isHiddenOrHasHiddenAncestor {
            inside = thumbRect.contains(convert(pointerLocation, from: nil))
        } else {
            inside = false
        }
        if hovered != inside { hovered = inside; needsDisplay = true }
    }

    private func clearPointer() {
        pointerLocation = nil
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea !== windowArea { super.mouseEntered(with: event) }
        observePointerEvent(event)
        if hovered { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === windowArea {
            clearPointer()
        } else {
            super.mouseExited(with: event)
            observePointerEvent(event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        observePointerEvent(event)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        needsDisplay = true
        super.mouseDown(with: event)
        dragging = false
        // Native dragging runs its own tracking loop. Reconcile after release,
        // including a release outside the thumb or outside this window.
        pointerLocation = window?.mouseLocationOutsideOfEventStream
        refreshHover()
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
