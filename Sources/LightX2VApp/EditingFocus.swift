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

private struct OutsideClickObserver: NSViewRepresentable {
    let isEditing: Bool
    let isEnabled: Bool

    func makeNSView(context: Context) -> EditingBoundaryView { EditingBoundaryView() }

    func updateNSView(_ view: EditingBoundaryView, context: Context) {
        view.isEditing = isEditing
        view.isInputEnabled = isEnabled
    }

    static func dismantleNSView(_ view: EditingBoundaryView, coordinator: ()) {
        view.stopObserving()
    }
}

final class EditingBoundaryView: NSView {
    private static let inputs = NSHashTable<EditingBoundaryView>.weakObjects()
    var isEditing = false
    var isInputEnabled = true
    private var monitor: Any?
    private var pendingEvent: NSEvent?
    private var cursorUpdateScheduled = false

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
            guard let self, self.isEditing, let window = self.window,
                  event.window === window, !self.isHiddenOrHasHiddenAncestor else { return event }
            if event.type != .leftMouseDown && event.type != .rightMouseDown {
                self.scheduleCursorUpdate(for: event)
                return event
            }
            guard !self.containsInput(event.locationInWindow) else { return event }
            // End editing before dispatching the same click, so another input
            // can acquire focus and buttons still activate on the first click.
            // Let AppKit update FocusState; resetting it here can clear the
            // new input's focus after the click has already been dispatched.
            window.makeFirstResponder(nil)
            self.pendingEvent = nil
            return event
        }
    }

    deinit { stopObserving() }

    private func containsInput(_ point: NSPoint) -> Bool {
        // On recent macOS versions visibleRect may exceed bounds for unclipped views.
        isInputEnabled && !isHiddenOrHasHiddenAncestor && bounds.intersection(visibleRect).contains(convert(point, from: nil))
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
            guard self.isEditing, self.window?.isKeyWindow == true, NSApp.isActive,
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
        if Self.inputs.allObjects.contains(where: { $0.window === window && $0.containsInput(point) }) {
            return .iBeam
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
    }
}
