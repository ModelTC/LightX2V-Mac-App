import AppKit
import SwiftUI

extension View {
    func dismissEditingOnOutsideClick() -> some View {
        modifier(OutsideClickEditingModifier())
    }
}

private struct OutsideClickEditingModifier: ViewModifier {
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .background(OutsideClickObserver(isEditing: isFocused, isEnabled: isEnabled))
    }
}

struct OutsideClickObserver: NSViewRepresentable {
    let isEditing: Bool
    let isEnabled: Bool
    var onHoverChange: ((Bool) -> Void)?
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> EditingBoundaryView { EditingBoundaryView() }

    func updateNSView(_ view: EditingBoundaryView, context: Context) {
        view.isEditing = isEditing
        view.isInputEnabled = isEnabled
        view.inputCornerRadius = cornerRadius
        view.onHoverChange = onHoverChange
        view.updateTrackingAreas()
    }

    static func dismantleNSView(_ view: EditingBoundaryView, coordinator: ()) {
        view.stopObserving()
    }
}

final class EditingBoundaryView: NSView {
    private static let inputs = NSHashTable<EditingBoundaryView>.weakObjects()
    var isEditing = false
    var isInputEnabled = true
    var inputCornerRadius: CGFloat = 0
    var onHoverChange: ((Bool) -> Void)?
    private(set) var hovered = false
    private var monitor: Any?
    private var pendingEvent: NSEvent?
    private var cursorUpdateScheduled = false
    private var pointerArea: NSTrackingArea?
    private var windowObservers: [NSObjectProtocol] = []

    // The observer measures the input, but never intercepts its clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        Self.inputs.add(self)
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .leftMouseUp, .mouseMoved,
            .mouseEntered, .mouseExited, .cursorUpdate
        ]) { [weak self] event in
            guard let self, self.isEditing || self.onHoverChange != nil, let window = self.window,
                  event.window === window, !self.isHiddenOrHasHiddenAncestor else { return event }
            if event.type != .leftMouseDown && event.type != .rightMouseDown {
                self.observePointerEvent(event)
                return event
            }
            guard self.isEditing, !self.containsInput(event.locationInWindow) else { return event }
            // End editing before dispatching the same click, so another input
            // can acquire focus and buttons still activate on the first click.
            // Let AppKit update FocusState; resetting it here can clear the
            // new input's focus after the click has already been dispatched.
            window.makeFirstResponder(nil)
            self.pendingEvent = nil
            return event
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.setHovered(false)
                self?.pendingEvent = nil
            })
        }
        updateTrackingAreas()
    }

    deinit { stopObserving() }

    private func containsInput(_ point: NSPoint) -> Bool {
        isInputEnabled && coversInput(point)
    }

    private func coversInput(_ point: NSPoint) -> Bool {
        // On recent macOS versions visibleRect may exceed bounds for unclipped views.
        let local = convert(point, from: nil)
        guard !isHiddenOrHasHiddenAncestor, bounds.intersection(visibleRect).contains(local) else { return false }
        return inputCornerRadius == 0 || NSBezierPath(roundedRect: bounds, xRadius: inputCornerRadius, yRadius: inputCornerRadius).contains(local)
    }

    override func updateTrackingAreas() {
        if let pointerArea { removeTrackingArea(pointerArea) }
        pointerArea = nil
        super.updateTrackingAreas()
        guard onHoverChange != nil, window != nil else { return }
        // This exact rectangle also owns the highlight and the click-to-focus area.
        let area = NSTrackingArea(rect: bounds.intersection(visibleRect),
                                  options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseEntered(with event: NSEvent) { observePointerEvent(event) }
    override func mouseExited(with event: NSEvent) { observePointerEvent(event) }
    override func cursorUpdate(with event: NSEvent) { observePointerEvent(event) }

    func observePointerEvent(_ event: NSEvent) {
        guard event.window === window else { setHovered(false); pendingEvent = nil; return }
        switch event.type {
        case .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate, .leftMouseUp: break
        default: return
        }
        setHovered(containsInput(event.locationInWindow))
        scheduleCursorUpdate(for: event)
    }

    private func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        onHoverChange?(value)
    }

    private func scheduleCursorUpdate(for event: NSEvent) {
        pendingEvent = event
        guard !cursorUpdateScheduled else { return }
        cursorUpdateScheduled = true
        // A local monitor runs before AppKit. Apply after dispatch, otherwise
        // the shared field editor can overwrite the arrow with its old I-beam.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cursorUpdateScheduled = false
            defer { self.pendingEvent = nil }
            guard self.isEditing || self.onHoverChange != nil,
                  self.window?.isKeyWindow == true, NSApp.isActive,
                  self.window?.attachedSheet == nil, NSEvent.pressedMouseButtons == 0,
                  let event = self.pendingEvent else { return }
            self.cursor(for: event)?.set()
        }
    }

    // Real view geometry is also exercised by the native regression checks.
    func cursor(for event: NSEvent) -> NSCursor? {
        guard event.window === window else { return nil }
        switch event.type {
        case .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate, .leftMouseUp: break
        default: return nil // Selection and scrollbar drags keep their native cursor.
        }
        let point = event.locationInWindow
        guard let window, let content = window.contentView,
              content.bounds.contains(content.convert(point, from: nil)) else { return nil }
        if let input = Self.inputs.allObjects.first(where: { $0.window === window && $0.coversInput(point) }) {
            return input.isInputEnabled ? .iBeam : .arrow
        }
        // Keep selectable text and the prompt editor native, but never extend
        // a clipped text document's cursor over its scrollbar or nearby buttons.
        let hitPoint = content.superview?.convert(point, from: nil) ?? point
        var hit = content.hitTest(hitPoint)
        while let view = hit {
            if view is NSScroller { return .arrow }
            if let field = view as? NSTextField {
                return field.isEnabled && (field.isEditable || field.isSelectable) ? .iBeam : .arrow
            }
            if let text = view as? NSTextView {
                return text.isSelectable ? .iBeam : .arrow
            }
            hit = view.superview
        }
        return .arrow
    }

    func stopObserving() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingEvent = nil
        Self.inputs.remove(self)
        if let pointerArea { removeTrackingArea(pointerArea) }
        pointerArea = nil
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        setHovered(false)
    }
}
