import AppKit
import SwiftUI

/// A compact editor whose placeholder, marked text and sizing share one text layout.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var focused: Bool
    @Binding var composing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PromptScrollView {
        let view = PromptScrollView()
        view.editor.delegate = context.coordinator
        view.editor.onInputChange = { [weak coordinator = context.coordinator] in coordinator?.readInput() }
        view.editor.onFocusChange = { [weak coordinator = context.coordinator] value in
            coordinator?.parent.focused = value
        }
        view.onHeightChange = { [weak coordinator = context.coordinator] value in
            // Layout can run during a SwiftUI update; publish only the latest measurement.
            DispatchQueue.main.async { [weak coordinator] in
                guard let coordinator, let view = coordinator.view,
                      abs(view.measuredHeight - value) < 0.5,
                      abs(coordinator.parent.height - value) > 0.5 else { return }
                coordinator.parent.height = value
            }
        }
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: PromptScrollView, context: Context) {
        context.coordinator.parent = self
        // SwiftUI updates also occur while the IME is still selecting a candidate.
        // Never replace that live text storage or move its selection.
        if !view.editor.hasMarkedText(), view.editor.string != text {
            view.editor.string = text
            view.editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            view.editor.undoManager?.removeAllActions()
            view.editor.needsDisplay = true
            view.updateTextLayout()
            view.editor.scrollRangeToVisible(view.editor.selectedRange())
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        weak var view: PromptScrollView?
        init(_ parent: PromptEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) { readInput() }

        func readInput() {
            guard let view else { return }
            let editor = view.editor
            if parent.composing != editor.hasMarkedText() { parent.composing = editor.hasMarkedText() }
            if parent.text != editor.string { parent.text = editor.string }
            editor.needsDisplay = true
            view.updateTextLayout()
        }
    }
}

final class PromptScrollView: NSScrollView {
    static let minimumHeight: CGFloat = 28
    static let maximumHeight: CGFloat = 144
    let editor = PromptTextView(frame: .zero)
    private(set) var measuredHeight = minimumHeight
    var onHeightChange: ((CGFloat) -> Void)?
    private var measuring = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        verticalScroller = SubtleScroller()
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .automatic
        horizontalScrollElasticity = .none
        contentView.drawsBackground = false
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = NSColor(Palette.ink)
        editor.insertionPointColor = NSColor(Palette.ink)
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 5
        editor.textContainer?.widthTracksTextView = true
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.setAccessibilityLabel("图像提示词")
        documentView = editor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        updateTextLayout()
    }

    func updateTextLayout() {
        guard !measuring, contentSize.width > 0,
              let container = editor.textContainer, let manager = editor.layoutManager else { return }
        measuring = true
        defer { measuring = false }
        let width = contentSize.width
        if abs(editor.frame.width - width) > 0.5 { editor.setFrameSize(NSSize(width: width, height: editor.frame.height)) }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        // Include the empty final line after Return, not only glyphs already drawn.
        let textHeight = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
        let naturalHeight = ceil(textHeight + editor.textContainerInset.height * 2)
        measuredHeight = min(Self.maximumHeight, max(Self.minimumHeight, naturalHeight))
        let overflow = naturalHeight > Self.maximumHeight
        if hasVerticalScroller != overflow { hasVerticalScroller = overflow }
        let documentHeight = max(naturalHeight, measuredHeight, contentSize.height)
        if abs(editor.frame.height - documentHeight) > 0.5 {
            editor.setFrameSize(NSSize(width: width, height: documentHeight))
        }
        if !overflow { contentView.scroll(to: .zero); reflectScrolledClipView(contentView) }
        onHeightChange?(measuredHeight)
        window?.invalidateCursorRects(for: editor)
    }
}

final class PromptTextView: NSTextView {
    var onInputChange: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    private var pointerArea: NSTrackingArea?
    var showsPlaceholder: Bool { string.isEmpty && !hasMarkedText() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsPlaceholder else { return }
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerOrigin.y)
        ("描述你想生成的画面…" as NSString).draw(at: origin, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(Palette.muted)
        ])
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        inputChanged()
    }

    override func unmarkText() {
        super.unmarkText()
        inputChanged()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        inputChanged()
    }

    private func inputChanged() { needsDisplay = true; onInputChange?() }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    override func resetCursorRects() {
        // The document can be taller than the viewport; never extend the I-beam
        // into the model picker or send button below the clipped text area.
        addCursorRect(visibleRect, cursor: .iBeam)
    }

    override func updateTrackingAreas() {
        if let pointerArea { removeTrackingArea(pointerArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerArea = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.iBeam.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.iBeam.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}
