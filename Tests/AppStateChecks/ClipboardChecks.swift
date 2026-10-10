import AppKit
import LightX2VCore

@MainActor
func clipboardChecks(store: AppStore, root: URL, original: URL) async throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally(); store.clearInputImages() }
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw AppError.message(message) }
        print("PASS \(message)")
    }
    func settle() async throws {
        for _ in 0..<500 {
            if !store.isImportingImages { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("Clipboard import timed out")
    }
    let png = try Data(contentsOf: original)
    board.setData(png, forType: .png)
    let emptyModel = AppStore()
    try check(emptyModel.receiveImagePaste(board) && emptyModel.selectedModel == nil && emptyModel.inputImages.isEmpty,
              "clipboard: no model consumes image paste without selecting a model or importing")
    store.prompt = "Keep clipboard draft"
    let selectedID = store.selectedID
    try check(store.receiveImagePaste(board) && store.isImportingImages, "clipboard: image paste immediately locks submission")
    // Clipboard changes after Paste must not change the image captured by it.
    board.clearContents(); board.setString("later clipboard text", forType: .string)
    try await settle()
    try check(store.inputImages.count == 1 && store.prompt == "Keep clipboard draft" && store.selectedID == selectedID,
              "clipboard: captured PNG preserves prompt and current conversation")
    let pasted = store.inputImages[0]
    let image = NSImage(contentsOfFile: pasted.path)
    try check(image?.size == NSSize(width: 40, height: 30), "clipboard: full image dimensions survive normalization")
    board.clearContents(); board.writeObjects([NSImage(contentsOf: original)!])
    try check(store.receiveImagePaste(board) && store.receiveImagePaste(board), "clipboard: repeated TIFF pastes queue while importing")
    try await settle()
    try check(store.inputImages.count == 3 && Set(store.inputImages.map(\.id)).count == 3,
              "clipboard: duplicate pastes retain independent removable identities")
    let portrait = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 48, bitsPerSample: 8,
                                    samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 72, bitsPerPixel: 24)!
    let secondFile = root.appendingPathComponent("clipboard-second.jpg")
    let jpeg = portrait.representation(using: .jpeg, properties: [:])!
    try jpeg.write(to: secondFile)
    board.clearContents(); board.writeObjects([original as NSURL, secondFile as NSURL])
    try check(store.receiveImagePaste(board), "clipboard: Finder file copies are accepted")
    try await settle()
    try check(store.inputImages.count == 5 && store.inputImages.suffix(2).map { NSImage(contentsOfFile: $0.path)?.size }
              == [NSSize(width: 40, height: 30), NSSize(width: 24, height: 48)],
              "clipboard: multiple Finder images retain clipboard order")
    board.clearContents(); board.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
    _ = store.receiveImagePaste(board); try await settle()
    try check(store.inputImages.count == 6 && NSImage(contentsOfFile: store.inputImages.last!.path)?.size == NSSize(width: 24, height: 48),
              "clipboard: external JPEG image data imports at its original pixel dimensions")
    let before = store.inputImages
    let invalid = NSPasteboardItem(); invalid.setData(png, forType: .png)
    let broken = NSPasteboardItem(); broken.setData(Data("broken".utf8), forType: .png)
    board.clearContents(); board.writeObjects([invalid, broken])
    _ = store.receiveImagePaste(board); try await settle()
    try check(store.inputImages == before && store.errorMessage != nil, "clipboard: broken image batch fails atomically without losing draft")
    store.errorMessage = nil
    board.clearContents(); board.writeObjects(Array(repeating: original as NSURL, count: 4))
    _ = store.receiveImagePaste(board); try await settle()
    try check(store.inputImages == before && store.errorMessage != nil, "clipboard: exceeding reference limit preserves all existing images")
    let staging = try FileManager.default.contentsOfDirectory(at: WorkspaceLayout(store.settings.workingDirectory).temporary,
                                                              includingPropertiesForKeys: nil)
    try check(!staging.contains { $0.lastPathComponent.hasPrefix("clipboard-") }, "clipboard: import staging is cleaned after success and failure")
    let snapshot = try InputImages.snapshot(store.inputImages, in: root.appendingPathComponent("clipboard-job"))
    store.removeInputImage(pasted)
    try check(!FileManager.default.fileExists(atPath: pasted.path) && snapshot.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) },
              "clipboard: removing a pasted draft leaves submitted snapshots intact")
    board.clearContents(); board.setString("text only", forType: .string)
    try check(!store.receiveImagePaste(board) && store.prompt == "Keep clipboard draft", "clipboard: plain text delegates to native editor")
    store.errorMessage = nil
}
