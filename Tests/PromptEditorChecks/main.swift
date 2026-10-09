import AppKit
import SwiftUI

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

// Native component checks: these windows are never presented, and no operating
// system mouse input is synthesized. Use actual NSScroller geometry and events.
let hoverWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                           styleMask: .borderless, backing: .buffered, defer: false)
let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                           styleMask: .borderless, backing: .buffered, defer: false)
func pointerEvent(_ point: NSPoint, in window: NSWindow = hoverWindow,
                  type: NSEvent.EventType = .mouseMoved) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                      windowNumber: window.windowNumber, context: nil,
                      eventNumber: 0, clickCount: 0, pressure: 0)!
}
for horizontal in [false, true] {
    let name = horizontal ? "horizontal" : "vertical"
    let scroller = SubtleScroller(frame: horizontal
        ? NSRect(x: 30, y: 30, width: 180, height: 15)
        : NSRect(x: 30, y: 30, width: 15, height: 180))
    hoverWindow.contentView!.addSubview(scroller)
    scroller.isEnabled = true
    scroller.knobProportion = 0.25
    scroller.doubleValue = 0.5
    let thumb = scroller.thumbRect
    check(!thumb.isEmpty && (horizontal ? thumb.height : thumb.width) == 6, "\(name): six-point thumb has native geometry")
    let center = NSPoint(x: thumb.midX, y: thumb.midY)
    let left = NSPoint(x: thumb.minX - 1, y: thumb.midY)
    let right = NSPoint(x: thumb.maxX + 1, y: thumb.midY)
    let below = NSPoint(x: thumb.midX, y: thumb.minY - 1)
    let above = NSPoint(x: thumb.midX, y: thumb.maxY + 1)
    func move(_ local: NSPoint) {
        let event = pointerEvent(scroller.convert(local, to: nil))
        scroller.mouseMoved(with: event)
    }
    for (direction, path) in [("left to right", [left, center, right]),
                              ("right to left", [right, center, left]),
                              ("bottom to top", [below, center, above]),
                              ("top to bottom", [above, center, below])] {
        move(path[0]); check(!scroller.hovered, "\(name) \(direction): outside is pale")
        move(path[1]); check(scroller.hovered, "\(name) \(direction): thumb is highlighted")
        scroller.needsDisplay = false
        move(path[2]); check(!scroller.hovered && scroller.needsDisplay, "\(name) \(direction): crossing the far edge clears AND repaints")
    }
    func paintedThumbColor() -> NSColor {
        let image = NSImage(size: scroller.bounds.size)
        image.lockFocus()
        NSColor.white.setFill(); scroller.bounds.fill()
        scroller.drawKnob()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let x = Int(center.x / scroller.bounds.width * CGFloat(bitmap.pixelsWide))
        let y = Int(center.y / scroller.bounds.height * CGFloat(bitmap.pixelsHigh))
        return bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }
    move(left); let pale = paintedThumbColor().redComponent
    move(center); let dark = paintedThumbColor().redComponent
    move(right); let restored = paintedThumbColor().redComponent
    check(dark < pale - 0.08 && abs(restored - pale) < 0.01,
          "\(name): rendered pixels darken on thumb and return to the original pale color")
    // Leaving only the painted thumb must reset, even inside the native hit area.
    let trackMargin = horizontal ? above : right
    check(scroller.bounds.contains(trackMargin), "\(name): regression point remains inside native drag target")
    move(center)
    scroller.observePointerEvent(pointerEvent(scroller.convert(trackMargin, to: nil)))
    check(!scroller.hovered, "\(name): window monitor clears hover without any mouseExited event")
    for _ in 0..<20 { move(center); move(right) }
    check(!scroller.hovered, "\(name): rapid repeated crossings do not leave hover stuck")
    move(center)
    let internalExit = NSEvent.enterExitEvent(with: .mouseExited,
        location: scroller.convert(center, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: hoverWindow.windowNumber, context: nil, eventNumber: 0,
        trackingNumber: 0, userData: nil)!
    scroller.mouseExited(with: internalExit)
    check(scroller.hovered, "\(name): internal tracking exit does not cancel a real thumb hover")
    scroller.observePointerEvent(pointerEvent(scroller.convert(right, to: nil), type: .leftMouseDragged))
    check(!scroller.hovered, "\(name): drag outside clears underlying hover")
    scroller.observePointerEvent(pointerEvent(scroller.convert(center, to: nil), type: .leftMouseUp))
    check(scroller.hovered, "\(name): release inside restores hover")
    scroller.observePointerEvent(pointerEvent(scroller.convert(right, to: nil), type: .leftMouseUp))
    check(!scroller.hovered, "\(name): release outside restores pale state")
    move(center)
    scroller.observePointerEvent(pointerEvent(scroller.convert(center, to: nil), in: otherWindow))
    check(!scroller.hovered, "\(name): moving into another window clears hover")
    move(center)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: hoverWindow)
    check(!scroller.hovered, "\(name): switching windows clears hover")
    move(center)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
    check(!scroller.hovered, "\(name): switching apps clears hover")
    move(center)
    scroller.isHidden = true
    move(center)
    check(!scroller.hovered, "\(name): hidden scrollbar cannot hover")
    scroller.isHidden = false
    scroller.isEnabled = false
    move(center)
    check(!scroller.hovered, "\(name): disabled scrollbar cannot hover")
    scroller.isEnabled = true
    scroller.knobProportion = 1
    move(center)
    check(!scroller.hovered, "\(name): content without overflow cannot hover")
    scroller.knobProportion = 0.25
    move(center)
    scroller.doubleValue = 0
    // Drawing must re-evaluate the moved thumb, even without pointer movement.
    let image = NSImage(size: scroller.bounds.size)
    image.lockFocus(); scroller.drawKnob(); image.unlockFocus()
    check(!scroller.hovered, "\(name): scrolling thumb away from stationary pointer clears hover")
    scroller.doubleValue = 0.5
    move(center)
    scroller.removeFromSuperview()
    check(!scroller.hovered, "\(name): removing scrollbar clears hover and detaches observers")
}
print("Scrollbar hover checks passed")

// The same native boundaries used behind SwiftUI path fields. No visible window
// or OS input injection is needed to check cursor ownership at actual hit targets.
let form = hoverWindow.contentView!
let field = NSTextField(frame: NSRect(x: 20, y: 220, width: 150, height: 24))
let boundary = EditingBoundaryView(frame: field.frame)
form.addSubview(boundary); form.addSubview(field)
boundary.isEditing = true
let secondField = NSTextField(frame: NSRect(x: 20, y: 165, width: 150, height: 24))
let secondBoundary = EditingBoundaryView(frame: secondField.frame)
form.addSubview(secondBoundary); form.addSubview(secondField)
let choose = NSButton(frame: NSRect(x: 185, y: 220, width: 90, height: 24))
form.addSubview(choose)
func cursorAt(_ point: NSPoint, type: NSEvent.EventType = .mouseMoved) -> NSCursor? {
    boundary.cursor(for: pointerEvent(point, type: type))
}
let inputPoint = NSPoint(x: 50, y: 232)
check(cursorAt(inputPoint) === NSCursor.iBeam, "cursor: path input uses I-beam")
for (name, point) in [("left", NSPoint(x: 19, y: 232)), ("right", NSPoint(x: 171, y: 232)),
                       ("top", NSPoint(x: 50, y: 245)), ("bottom", NSPoint(x: 50, y: 219))] {
    NSCursor.iBeam.set() // Model the stale cursor left by AppKit's field editor.
    cursorAt(point)?.set()
    check(NSCursor.current === NSCursor.arrow, "cursor: leaving \(name) edge restores arrow")
}
check(cursorAt(NSPoint(x: 220, y: 232)) === NSCursor.arrow, "cursor: adjacent choose button uses arrow")
choose.isEnabled = false
check(cursorAt(NSPoint(x: 220, y: 232)) === NSCursor.arrow, "cursor: disabled button still uses arrow")
check(cursorAt(NSPoint(x: 290, y: 110)) === NSCursor.arrow, "cursor: blank form area uses arrow")
check(cursorAt(NSPoint(x: 50, y: 177)) === NSCursor.iBeam, "cursor: moving directly into another path input keeps I-beam")
secondBoundary.isInputEnabled = false; secondField.isEnabled = false
check(cursorAt(NSPoint(x: 50, y: 177)) === NSCursor.arrow, "cursor: disabled path input uses arrow")
secondBoundary.isInputEnabled = true; secondField.isEnabled = true
secondBoundary.isHidden = true; secondField.isHidden = true
check(cursorAt(NSPoint(x: 50, y: 177)) === NSCursor.arrow, "cursor: hidden path input cannot claim cursor")
secondBoundary.isHidden = false; secondField.isHidden = false
check(cursorAt(NSPoint(x: 220, y: 232), type: .leftMouseDragged) == nil, "cursor: text selection dragging is left to AppKit")
check(cursorAt(NSPoint(x: 220, y: 232), type: .leftMouseUp) === NSCursor.arrow, "cursor: releasing outside input restores arrow")
check(cursorAt(inputPoint, type: .leftMouseUp) === NSCursor.iBeam, "cursor: releasing inside input keeps I-beam")
check(cursorAt(NSPoint(x: -1, y: 232)) == nil, "cursor: outside window is left to the destination application")
check(boundary.cursor(for: pointerEvent(inputPoint, in: otherWindow)) == nil, "cursor: other windows and native panels are not overridden")
let focusedBefore = hoverWindow.firstResponder
for _ in 0..<30 { _ = cursorAt(inputPoint); _ = cursorAt(NSPoint(x: 220, y: 232)) }
check(hoverWindow.firstResponder === focusedBefore, "cursor: repeated pointer crossings never change keyboard focus")

let clipped = NSScrollView(frame: NSRect(x: 20, y: 40, width: 250, height: 80))
let document = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 300))
clipped.documentView = document; form.addSubview(clipped)
let clippedInput = EditingBoundaryView(frame: NSRect(x: 0, y: 0, width: 180, height: 200))
document.addSubview(clippedInput)
let clippedPoint = clipped.contentView.convert(NSPoint(x: 20, y: 20), to: nil)
check(cursorAt(clippedPoint) === NSCursor.iBeam, "cursor: visible part of a scrolling input keeps I-beam")
check(cursorAt(NSPoint(x: 40, y: 130)) === NSCursor.arrow, "cursor: clipped input cannot extend its cursor into surrounding space")
clipped.contentView.scroll(to: NSPoint(x: 0, y: 220))
check(cursorAt(clippedPoint) === NSCursor.arrow, "cursor: scrolling an input out of view releases cursor ownership")
clipped.removeFromSuperview()
scroll.frame = NSRect(x: 20, y: 40, width: 250, height: 80)
form.addSubview(scroll); scroll.tile(); scroll.updateTextLayout()
let promptPoint = editor.convert(NSPoint(x: 20, y: 10), to: nil)
check(cursorAt(promptPoint) === NSCursor.iBeam, "cursor: native prompt editor keeps I-beam after leaving path input")
check(cursorAt(NSPoint(x: 40, y: 30)) === NSCursor.arrow, "cursor: space below prompt is arrow")
scroll.removeFromSuperview()
let selectable = NSTextView(frame: NSRect(x: 20, y: 40, width: 250, height: 80))
selectable.isEditable = false; selectable.isSelectable = true; form.addSubview(selectable)
check(cursorAt(NSPoint(x: 40, y: 60)) === NSCursor.iBeam, "cursor: selectable logs retain their native text cursor")
selectable.isSelectable = false
check(cursorAt(NSPoint(x: 40, y: 60)) === NSCursor.arrow, "cursor: nonselectable text uses arrow")
secondBoundary.removeFromSuperview(); secondField.removeFromSuperview()
check(cursorAt(NSPoint(x: 50, y: 177)) === NSCursor.arrow, "cursor: detached input no longer claims cursor")
boundary.removeFromSuperview()
check(cursorAt(inputPoint) == nil, "cursor: detached observer does not modify cursor")
print("Input cursor boundary checks passed")

// Mount the actual SwiftUI input: its padding and icon must participate before
// focus, rather than testing only the narrow native text field in isolation.
let syncWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                          styleMask: .borderless, backing: .buffered, defer: false)
func inputFixture(enabled: Bool = true) -> some View {
    PathInputField(title: "工作目录", placeholder: "路径", symbol: "folder", text: .constant("/tmp/LightX2V"))
        .disabled(!enabled)
}
let inputHost = NSHostingView(rootView: inputFixture())
inputHost.frame = NSRect(x: 30, y: 180, width: 400, height: 44)
syncWindow.contentView!.addSubview(inputHost)
inputHost.layoutSubtreeIfNeeded()
func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
}
var inputBounds = descendants(inputHost, of: EditingBoundaryView.self).first!
let nativeField = descendants(inputHost, of: NSTextField.self).first!
check(inputBounds.bounds.height >= 44 && inputBounds.bounds.height > nativeField.bounds.height,
      "input hover: actual SwiftUI surface includes vertical padding around native TextField")
let inputFrame = inputBounds.convert(inputBounds.bounds, to: nil)
let nearbyButton = NSButton(frame: NSRect(x: inputFrame.maxX + 4, y: inputFrame.minY + 10, width: 80, height: 24))
syncWindow.contentView!.addSubview(nearbyButton)
let hoverPoints: [(String, NSPoint, Bool)] = [
    ("left padding", NSPoint(x: inputFrame.minX + 1, y: inputFrame.midY), true),
    ("icon", NSPoint(x: inputFrame.minX + 16, y: inputFrame.midY), true),
    ("top padding", NSPoint(x: inputFrame.midX, y: inputFrame.maxY - 1), true),
    ("bottom padding", NSPoint(x: inputFrame.midX, y: inputFrame.minY + 1), true),
    ("right padding", NSPoint(x: inputFrame.maxX - 1, y: inputFrame.midY), true),
    ("text", NSPoint(x: inputFrame.midX, y: inputFrame.midY), true),
    ("outside left", NSPoint(x: inputFrame.minX - 1, y: inputFrame.midY), false),
    ("outside top", NSPoint(x: inputFrame.midX, y: inputFrame.maxY + 1), false),
    ("outside bottom", NSPoint(x: inputFrame.midX, y: inputFrame.minY - 1), false),
    ("gap before chooser", NSPoint(x: inputFrame.maxX + 1, y: inputFrame.midY), false),
    ("chooser", NSPoint(x: nearbyButton.frame.midX, y: nearbyButton.frame.midY), false),
    ("rounded corner", NSPoint(x: inputFrame.minX + 0.5, y: inputFrame.minY + 0.5), false)
]
for focused in [false, true] {
    inputBounds.isEditing = focused
    for (name, point, inside) in hoverPoints {
        let event = pointerEvent(point, in: syncWindow)
        inputBounds.observePointerEvent(event)
        let expected = inside ? NSCursor.iBeam : NSCursor.arrow
        check(inputBounds.hovered == inside && inputBounds.cursor(for: event) === expected,
              "input hover \(focused ? "focused" : "unfocused"): \(name) shares highlight and cursor boundary")
    }
}
let inputMiddle = pointerEvent(NSPoint(x: inputFrame.midX, y: inputFrame.midY), in: syncWindow)
inputBounds.observePointerEvent(inputMiddle)
NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: syncWindow)
check(!inputBounds.hovered, "input hover: switching windows clears highlight")
inputHost.rootView = inputFixture(enabled: false)
inputHost.layoutSubtreeIfNeeded()
inputBounds = descendants(inputHost, of: EditingBoundaryView.self).first!
inputBounds.observePointerEvent(inputMiddle)
check(!inputBounds.hovered && inputBounds.cursor(for: inputMiddle) === NSCursor.arrow,
      "input hover: disabled input has neither highlight nor I-beam")
inputHost.rootView = inputFixture()
inputHost.layoutSubtreeIfNeeded()
inputBounds = descendants(inputHost, of: EditingBoundaryView.self).first!
inputBounds.observePointerEvent(inputMiddle)
inputHost.isHidden = true
inputBounds.observePointerEvent(inputMiddle)
check(!inputBounds.hovered && inputBounds.cursor(for: inputMiddle) === NSCursor.arrow,
      "input hover: hidden input has neither highlight nor I-beam")
inputHost.isHidden = false
inputBounds.observePointerEvent(inputMiddle)
inputBounds.observePointerEvent(pointerEvent(.zero, in: otherWindow))
check(!inputBounds.hovered, "input hover: leaving for another window clears highlight")
inputBounds.observePointerEvent(inputMiddle)
inputHost.removeFromSuperview()
check(!inputBounds.hovered && inputBounds.cursor(for: inputMiddle) == nil,
      "input hover: detaching view releases both highlight and cursor")
print("Synchronized input hover checks passed")

// Completing a path, rather than each keystroke, advances the setup guide.
let commitWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 120),
                            styleMask: .borderless, backing: .buffered, defer: false)
var draftPath = ""
var pathCommits = 0
let commitHost = NSHostingView(rootView: PathInputField(
    title: "工作目录", placeholder: "路径", symbol: "folder",
    text: Binding(get: { draftPath }, set: { draftPath = $0 }),
    onCommit: { pathCommits += 1 }))
commitHost.frame = NSRect(x: 10, y: 50, width: 400, height: 44)
commitWindow.contentView!.addSubview(commitHost)
commitHost.layoutSubtreeIfNeeded()
let commitField = descendants(commitHost, of: NSTextField.self).first!
func settleInput() { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
commitWindow.makeFirstResponder(commitField)
settleInput()
let pathEditor = commitField.currentEditor() as! NSTextView
pathEditor.insertText("/tmp/", replacementRange: NSRange(location: NSNotFound, length: 0))
pathEditor.insertText("workspace", replacementRange: NSRange(location: NSNotFound, length: 0))
settleInput()
check(draftPath == "/tmp/workspace" && pathCommits == 0, "setup input: typing updates draft without advancing guide")
commitWindow.makeFirstResponder(nil)
settleInput()
check(pathCommits == 1, "setup input: leaving field commits guide exactly once")
commitWindow.makeFirstResponder(commitField)
settleInput()
(commitField.currentEditor() as! NSTextView).insertNewline(nil)
settleInput()
check(pathCommits > 1, "setup input: Return commits guide")
commitWindow.makeFirstResponder(nil)
commitHost.removeFromSuperview()
