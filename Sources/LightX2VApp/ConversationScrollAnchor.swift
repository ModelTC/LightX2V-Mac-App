import AppKit
import SwiftUI

/// Keep the latest reply visible through asynchronous decoding and composer
/// resizing, without pulling someone away from an older reply they are reading.
struct ConversationScrollAnchor: NSViewRepresentable {
    let turns: [UUID]

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.update(turns: turns) }

    final class AnchorView: NSView {
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var turns: [UUID] = []
        private var pinned = true
        private var requestedBottom = true
        private var scheduled = false
        private var adjusting = false
        private var userScrolled = false
        private var eventMonitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); schedule() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        }

        func update(turns: [UUID]) {
            if self.turns != turns { self.turns = turns; pinned = true; requestedBottom = true }
            schedule()
        }

        private func schedule() {
            guard !scheduled, !adjusting else { return }
            scheduled = true
            // Reconcile after SwiftUI has committed both the document and viewport
            // frames. No timer, animation or published geometry feedback is needed.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.reconcile()
            }
        }

        private func reconcile() {
            guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            if scrollView !== scroll {
                observers.forEach { NotificationCenter.default.removeObserver($0) }
                observers = []
                scrollView = scroll
                pinned = true
                if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged, .keyDown]) { [weak self, weak scroll, weak document] event in
                    guard let self, let scroll, let document, event.window === scroll.window else { return event }
                    let withinScroll = scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
                    let navigationKey = event.type == .keyDown && [115, 116, 119, 121, 125, 126, 49].contains(event.keyCode)
                        && (scroll.window?.firstResponder as? NSView)?.isDescendant(of: document) == true
                    if (event.type != .keyDown && withinScroll) || navigationKey {
                        self.userScrolled = true
                        self.schedule()
                    }
                    return event
                }
                observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                    self?.userScrolled = true
                    self?.schedule()
                })
                document.postsFrameChangedNotifications = true
                scroll.contentView.postsBoundsChangedNotifications = true
                scroll.contentView.postsFrameChangedNotifications = true
                scroll.postsFrameChangedNotifications = true
                for (name, object) in [(NSView.frameDidChangeNotification, document),
                                       (NSView.boundsDidChangeNotification, scroll.contentView),
                                       (NSView.frameDidChangeNotification, scroll.contentView),
                                       (NSView.frameDidChangeNotification, scroll)] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                        self?.schedule()
                    })
                }
            }
            let viewport = scroll.contentView.bounds
            let documentSize = document.frame.size
            let bottom = max(0, documentSize.height - viewport.height)
            let targetY = document.isFlipped ? bottom : 0
            // AppKit/SwiftUI can adjust the origin after committing a resized
            // document. Only actual user scrolling releases the bottom anchor.
            if userScrolled && !requestedBottom { pinned = abs(viewport.origin.y - targetY) <= 2 }
            if pinned || requestedBottom {
                if abs(viewport.origin.y - targetY) > 0.5 {
                    adjusting = true
                    scroll.contentView.scroll(to: NSPoint(x: viewport.origin.x, y: targetY))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    adjusting = false
                }
            }
            requestedBottom = false
            userScrolled = false
        }
    }
}
