import AppKit
import SwiftUI
import LightX2VCore

/// Exercise the real scrolling view with asynchronous image decoding, reopening
/// history and resizing before any user scroll.
@MainActor
func conversationLayoutChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("conversation-layout-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let support = root.appendingPathComponent("support")
    let layout = WorkspaceLayout(root.appendingPathComponent("workspace").path)
    try layout.prepare()
    var settings = AppSettings.defaults
    settings.workingDirectory = layout.root.path
    settings.repository = root.appendingPathComponent("fake-source").path
    settings.python = "/usr/bin/false"
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: true), to: layout.state)
    try JSONFile.write(WorkspaceLocation(workingDirectory: layout.root.path), to: support.appendingPathComponent("workspace_location.json"))
    let store = AppStore()
    func fixture(_ name: String, width: Int, height: Int) throws -> URL {
        let url = root.appendingPathComponent(name + ".png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        bitmap.bitmapData!.initialize(repeating: 127, count: width * height * 4)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }
    let square = try fixture("square", width: 2048, height: 2048)
    let landscape = try fixture("landscape", width: 2752, height: 1536)
    let portrait = try fixture("portrait", width: 1536, height: 2752)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 998, height: 650),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil }
    let host = CountingConversationHost(rootView: GenerationView().environmentObject(store))
    window.contentView = host
    func settle(_ label: String, in view: NSView = host) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        let before = (view as? LayoutCounting)?.layoutCount ?? 0
        var heights: [CGFloat] = []
        var offsets: [CGFloat] = []
        for _ in 0..<40 {
            view.layoutSubtreeIfNeeded()
            if let scroll = descendantScroll(view), let document = scroll.documentView {
                heights.append(document.frame.height)
                offsets.append(scroll.contentView.bounds.origin.y)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let layouts = ((view as? LayoutCounting)?.layoutCount ?? 0) - before
        let spread = (heights.max() ?? 0) - (heights.min() ?? 0)
        let offsetSpread = (offsets.max() ?? 0) - (offsets.min() ?? 0)
        guard !heights.isEmpty, layouts < 20, spread < 1, offsetSpread < 1 else {
            throw AppError.message("Unstable conversation \(label): layouts=\(layouts), height=\(spread), scroll=\(offsetSpread)")
        }
        print("PASS \(label) settles: layouts=\(layouts), height spread=\(spread), scroll spread=\(offsetSpread)")
    }
    func checkBottom(_ label: String, in view: NSView = host) throws {
        guard let scroll = descendantScroll(view), let document = scroll.documentView else {
            throw AppError.message("Conversation scroll view missing")
        }
        let gap = document.frame.height - scroll.contentView.bounds.maxY
        guard gap <= 2 else { throw AppError.message("\(label) left \(gap) points below the viewport") }
        print("PASS \(label) keeps the image actions visible at the bottom")
    }
    let creationID = UUID()
    func job(_ url: URL, references: Bool = false) throws -> Generation {
        let inputs = references ? [InputImage(path: square.path, name: "reference.png")] : []
        let prompt = references ? String(repeating: "Preserve the original composition and natural sunlight. ", count: 12)
                                : "A capybara wearing a wizard hat, oil painting"
        let request = try InferenceRequest(settings: settings, prompt: prompt, width: nil, height: nil,
                                           seed: 1, output: url.path, inputImages: inputs, resolution: 2048)
        return Generation(creationID: creationID, request: request)
    }
    for (index, url) in [square, landscape, portrait].enumerated() {
        let turn = try job(url, references: index == 2)
        store.generations.insert(turn, at: 0); store.selectedID = turn.id
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        store.generations[0].status = .completed; store.generations[0].duration = 96
        try await settle("running to completed turn \(index + 1)")
        try checkBottom("completed turn \(index + 1)")
        // A loading/failure row is much shorter than this square preview. Check
        // that the first completed turn actually contains the decoded image.
        if index == 0, (descendantScroll(host)?.documentView?.frame.height ?? 0) < 450 {
            throw AppError.message("Completed square preview did not occupy its image layout")
        }
    }
    for size in [NSSize(width: 380, height: 350), NSSize(width: 1200, height: 900)] {
        window.setContentSize(size)
        try await settle("resize \(Int(size.width)) × \(Int(size.height))")
        host.rootView = GenerationView().environmentObject(store)
        try await settle("reopen completed history at \(Int(size.width)) points before scrolling")
        try checkBottom("reopened history at \(Int(size.width)) points")
        guard let scroll = descendantScroll(host), let document = scroll.documentView else {
            throw AppError.message("Conversation scroll view missing")
        }
        window.setContentSize(NSSize(width: size.width, height: size.height - 84))
        try await settle("composer gains reference strip")
        try checkBottom("reference strip growth")
        window.setContentSize(size)
        try await settle("composer loses reference strip")
        try checkBottom("reference strip removal")
        for y in [CGFloat(0), max(0, document.frame.height - scroll.contentView.bounds.height)] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            try await settle("scroll to \(Int(y)) at \(Int(size.width)) points")
            if y == 0 {
                window.setContentSize(NSSize(width: size.width, height: size.height - 84))
                try await settle("resize while reading older replies")
                guard scroll.contentView.bounds.origin.y < 2 else {
                    throw AppError.message("Resizing pulled the reader away from older replies")
                }
                print("PASS reading position survives composer growth")
                window.setContentSize(size)
                try await settle("restore while reading older replies")
            }
        }
    }
    if let scroll = descendantScroll(host) {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    }
    try await settle("read old replies before sending again")
    let next = try job(square)
    store.generations.insert(next, at: 0); store.selectedID = next.id
    try await settle("append a new turn from older history")
    try checkBottom("new turn")
    store.generations[0].status = .completed
    try await settle("new turn completes after scrolling to latest")
    try checkBottom("new turn image decode")

    // The complete workspace adds nested scroll views and SwiftUI focus updates.
    // Exercise the real composer, not only a manually resized conversation host.
    store.selectedID = nil
    let workspaceHost = CountingConversationHost(rootView: WorkspaceView().environmentObject(store))
    window.contentView = workspaceHost
    window.setContentSize(NSSize(width: 1200, height: 900))
    workspaceHost.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    store.selectedID = next.id
    try await settle("open multi-turn history in the whole workspace", in: workspaceHost)
    try checkBottom("whole workspace history", in: workspaceHost)
    store.selectModel(.qwenImage21)
    store.errorMessage = nil
    try await settle("model selection in completed history", in: workspaceHost)
    let contentHeight = descendantScroll(workspaceHost)!.documentView!.frame.height
    store.reference(store.generations[0])
    guard store.isImportingImages && !store.configurationBusy else {
        throw AppError.message("Reference import should not dim configuration controls")
    }
    try await settle("reference grows the actual composer", in: workspaceHost)
    try checkBottom("reference in actual composer", in: workspaceHost)
    guard descendantScroll(workspaceHost)!.documentView!.frame.height == contentHeight else {
        throw AppError.message("Attaching a reference resized existing conversation images")
    }
    print("PASS reference import keeps configuration appearance and preview sizes stable")
    store.removeInputImage(store.inputImages[0])
    try await settle("remove reference from actual composer", in: workspaceHost)
    try checkBottom("reference removal in actual composer", in: workspaceHost)
    let pasteboard = NSPasteboard(name: .init("conversation-paste-" + UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    pasteboard.setData(try Data(contentsOf: portrait), forType: .png)
    guard store.receiveImagePaste(pasteboard) else { throw AppError.message("Image paste not consumed") }
    try await settle("paste grows the actual composer", in: workspaceHost)
    try checkBottom("paste in actual composer", in: workspaceHost)
    store.prompt = String(repeating: "A natural scene with soft sunlight.\n", count: 20)
    try await settle("long prompt reaches maximum composer height", in: workspaceHost)
    try checkBottom("long prompt in actual composer", in: workspaceHost)
    store.prompt = ""
    store.clearInputImages()
    try await settle("clear composer after pasting", in: workspaceHost)
    try checkBottom("cleared composer", in: workspaceHost)
}

@MainActor
private protocol LayoutCounting: AnyObject { var layoutCount: Int { get } }

@MainActor
private final class CountingConversationHost<Content: View>: NSHostingView<Content>, LayoutCounting {
    var layoutCount = 0
    override func layout() { layoutCount += 1; super.layout() }
}

@MainActor
private func descendantScroll(_ view: NSView) -> NSScrollView? {
    if let anchor = view as? ConversationScrollAnchor.AnchorView { return anchor.enclosingScrollView }
    return view.subviews.lazy.compactMap { descendantScroll($0) }.first
}

