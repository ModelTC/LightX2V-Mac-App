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
                guard !window.styleMask.contains(.fullScreen),
                      let screen = self.initialScreen ?? window.screen ?? NSScreen.main else { return }
                window.setFrame(screen.visibleFrame, display: true)
            }
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
