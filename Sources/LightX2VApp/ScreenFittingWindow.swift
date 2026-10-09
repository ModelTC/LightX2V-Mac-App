import AppKit
import SwiftUI

/// Fits the main window once per launch, after macOS restores its saved frame.
struct ScreenFittingWindow: NSViewRepresentable {
    static var launchScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    static var minimumContentSize: CGSize {
        let visible = launchScreen?.visibleFrame.size ?? CGSize(width: 1320, height: 860)
        // Leave room for native window chrome on smaller display scale settings.
        return CGSize(width: min(1004, visible.width), height: min(680, max(1, visible.height - 40)))
    }

    static func fit(_ window: NSWindow, on screen: NSScreen? = nil) {
        guard !window.styleMask.contains(.fullScreen),
              let screen = screen ?? window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.visibleFrame, display: true)
    }

    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ view: WindowView, context: Context) {}

    static func dismantleNSView(_ view: WindowView, coordinator: ()) {
        view.stopObserving()
    }

    final class WindowView: NSView {
        private var observer: NSObjectProtocol?
        private weak var fittedWindow: NSWindow?
        private var fitScheduled = false
        private let initialScreen = ScreenFittingWindow.launchScreen

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window, fittedWindow !== window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.scheduleFit() }
            if window.isVisible { scheduleFit() }
        }

        private func scheduleFit() {
            guard !fitScheduled, let window, fittedWindow !== window else { return }
            fitScheduled = true
            // Wait until the initial display/restoration pass has finished.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self else { return }
                self.fitScheduled = false
                guard let window, self.window === window, self.fittedWindow !== window else { return }
                self.fittedWindow = window
                self.stopObserving()
                ScreenFittingWindow.fit(window, on: self.initialScreen)
            }
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}

/// A transparent title-bar region: drag to move, double-click to fit the screen.
struct WindowDragArea: NSViewRepresentable {
    var isNativeTitleBar = false

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.isNativeTitleBar = isNativeTitleBar
        return view
    }
    func updateNSView(_ view: DragView, context: Context) {}

    static func dismantleNSView(_ view: DragView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class DragView: NSView {
        var isNativeTitleBar = false
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.attachedSheet == nil,
                      self.contains(event.locationInWindow, in: window),
                      !self.isWindowButton(at: event.locationInWindow, in: window) else { return event }
                if event.clickCount == 2 {
                    ScreenFittingWindow.fit(window)
                } else if !self.isNativeTitleBar {
                    window.performDrag(with: event)
                } else {
                    return event
                }
                // Consume the click so the native title-bar action cannot undo the fit.
                return nil
            }
        }

        private func contains(_ point: NSPoint, in window: NSWindow) -> Bool {
            if isNativeTitleBar {
                // The native title bar sits outside SwiftUI's safe-area layout.
                return NSRect(x: 0, y: window.frame.height - 28,
                              width: window.frame.width, height: 28).contains(point)
            }
            return bounds.contains(convert(point, from: nil))
        }

        private func isWindowButton(at point: NSPoint, in window: NSWindow) -> Bool {
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            return buttons.contains { type in
                guard let button = window.standardWindowButton(type), !button.isHidden else { return false }
                return button.bounds.contains(button.convert(point, from: nil))
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
