import AppKit
import SwiftUI

extension View {
    func dismissEditingOnOutsideClick() -> some View {
        modifier(OutsideClickEditingModifier())
    }
}

private struct OutsideClickEditingModifier: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .background(OutsideClickObserver(isEditing: isFocused))
    }
}

private struct OutsideClickObserver: NSViewRepresentable {
    let isEditing: Bool

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.isEditing = isEditing
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        view.stopObserving()
    }

    final class ObserverView: NSView {
        var isEditing = false
        private var monitor: Any?

        // The observer measures the input, but never intercepts its clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, self.isEditing, let window = self.window,
                      event.window === window, !self.isHiddenOrHasHiddenAncestor,
                      !self.convert(self.bounds, to: nil).contains(event.locationInWindow) else { return event }
                // End editing before dispatching the same click, so another input
                // can acquire focus and buttons still activate on the first click.
                // Let AppKit update FocusState; resetting it here can clear the
                // new input's focus after the click has already been dispatched.
                window.makeFirstResponder(nil)
                return event
            }
        }

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
