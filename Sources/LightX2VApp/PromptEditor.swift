import AppKit
import SwiftUI

/// A compact editor whose placeholder, marked text and sizing share one text layout.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var focused: Bool
    @Binding var composing: Bool
    var placeholder = "描述你想生成的画面…"
    var onDropFiles: (([URL]) -> Void)?
    var onDropHover: ((Bool) -> Void)?
    var onPasteImages: ((NSPasteboard) -> Bool)?
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PromptScrollView {
        let view = PromptScrollView()
        view.editor.delegate = context.coordinator
        view.editor.onInputChange = { [weak coordinator = context.coordinator] in coordinator?.readInput() }
        view.editor.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.readInput()
            coordinator?.parent.onSubmit()
        }
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
        view.editor.placeholder = placeholder
        view.editor.onDropFiles = onDropFiles
        view.editor.onDropHover = onDropHover
        view.editor.onPasteImages = onPasteImages
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
        editor.registerForDraggedTypes([.fileURL])
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
    var onSubmit: (() -> Void)?
    var placeholder = "描述你想生成的画面…" { didSet { if oldValue != placeholder { needsDisplay = true } } }
    var onDropFiles: (([URL]) -> Void)?
    var onDropHover: ((Bool) -> Void)?
    var onPasteImages: ((NSPasteboard) -> Bool)?
    private var pointerArea: NSTrackingArea?
    var showsPlaceholder: Bool { string.isEmpty && !hasMarkedText() }

    private func isFileDrop(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.types?.contains(.fileURL) == true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isFileDrop(sender) else { return super.draggingEntered(sender) }
        let accepted = onDropFiles != nil
        onDropHover?(accepted)
        return accepted ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isFileDrop(sender) ? draggingEntered(sender) : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropHover?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isFileDrop(sender) ? onDropFiles != nil : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isFileDrop(sender) else { return super.performDragOperation(sender) }
        onDropHover?(false)
        guard let onDropFiles,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onDropFiles(urls)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.keyCode == 9, modifiers == .control {
            if !event.isARepeat { paste(nil) }
            return
        }
        // Decide before the input method commits marked text. Checking only in
        // insertNewline would risk sending the Return used to confirm a candidate.
        if isReturn, !hasMarkedText() {
            if modifiers == .shift, isEditable {
                // Keypad Enter has a different default AppKit binding. Give
                // both Enter keys the same native newline/undo behavior.
                super.insertNewline(nil)
                inputChanged()
                return
            }
            if modifiers.isEmpty, let onSubmit {
                if isEditable, !event.isARepeat, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onSubmit()
                }
                return
            }
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if onPasteImages?(NSPasteboard.general) == true { return }
        super.paste(sender)
        inputChanged()
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), ImagePasteboard.containsImages(.general) {
            return isEditable && onPasteImages != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsPlaceholder else { return }
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: [
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
