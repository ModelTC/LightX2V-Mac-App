import AppKit

// Exercise the real AppKit text storage and layout without opening a window.
final class EditorDelegate: NSObject, NSTextViewDelegate {
    let undo = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { undo }
}
let app = NSApplication.shared
let scroll = PromptScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 28))
let editor = scroll.editor
let delegate = EditorDelegate()
editor.delegate = delegate
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL \(message)\n", stderr); exit(1) }
    print("PASS \(message)")
}
func setText(_ value: String) {
    editor.string = value
    scroll.updateTextLayout()
}
setText("")
check(editor.showsPlaceholder && scroll.measuredHeight == 28 && !scroll.hasVerticalScroller, "empty editor is compact and has no scrollbar")
setText("A quiet forest")
check(!editor.showsPlaceholder && scroll.measuredHeight == 28, "one line keeps the compact height")
let oneLine = scroll.measuredHeight
setText("A quiet forest\n")
check(scroll.measuredHeight > oneLine && !scroll.hasVerticalScroller, "Return grows the editor including its empty final line")
setText(String(repeating: "自然光下的森林与玻璃小屋。", count: 8))
let wideHeight = scroll.measuredHeight
scroll.setFrameSize(NSSize(width: 260, height: 28))
scroll.tile()
scroll.updateTextLayout()
check(scroll.measuredHeight > wideHeight, "narrower width reflows Chinese text and grows the editor")
setText((1...30).map { "第\($0)行：自然光下的森林与玻璃小屋" }.joined(separator: "\n"))
check(scroll.measuredHeight == PromptScrollView.maximumHeight && scroll.hasVerticalScroller, "long prompt caps height and enables scrolling")
setText("")
check(scroll.measuredHeight == 28 && !scroll.hasVerticalScroller && scroll.contentView.bounds.origin.y == 0, "clearing restores compact height and removes scrolling")
var observedComposition = false
editor.onInputChange = { observedComposition = editor.hasMarkedText(); scroll.updateTextLayout() }
editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
check(editor.hasMarkedText() && observedComposition && !editor.showsPlaceholder, "IME preedit hides placeholder before commitment")
editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
check(editor.string == "中文" && !editor.hasMarkedText() && !observedComposition && !editor.showsPlaceholder, "IME commitment keeps Chinese text and clears composition state")
setText("")
editor.setSelectedRange(NSRange(location: 0, length: 0))
editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
check(editor.string.isEmpty && editor.showsPlaceholder && !observedComposition, "cancelled composition restores placeholder")
delegate.undo.removeAllActions()
editor.breakUndoCoalescing()
editor.insertText("第一行\n第二行", replacementRange: NSRange(location: NSNotFound, length: 0))
check(editor.string == "第一行\n第二行" && scroll.measuredHeight > 28, "multiline paste preserves text and expands")
editor.undoManager?.undo()
scroll.updateTextLayout()
check(editor.string.isEmpty && scroll.measuredHeight == 28, "undo restores empty prompt and compact height")
print("Prompt editor checks passed")
