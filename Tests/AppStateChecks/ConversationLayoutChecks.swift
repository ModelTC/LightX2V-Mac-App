import AppKit
import SwiftUI
import LightX2VCore

/// Exercise the real scrolling view with asynchronous image decoding. A single
/// completed turn used to alternate between its loading and image layouts.
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
    func settle(_ label: String) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        let before = host.layoutCount
        var heights: [CGFloat] = []
        var offsets: [CGFloat] = []
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            if let scroll = descendantScroll(host), let document = scroll.documentView {
                heights.append(document.frame.height)
                offsets.append(scroll.contentView.bounds.origin.y)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let layouts = host.layoutCount - before
        let spread = (heights.max() ?? 0) - (heights.min() ?? 0)
        let offsetSpread = (offsets.max() ?? 0) - (offsets.min() ?? 0)
        guard !heights.isEmpty, layouts < 20, spread < 1, offsetSpread < 1 else {
            throw AppError.message("Unstable conversation \(label): layouts=\(layouts), height=\(spread), scroll=\(offsetSpread)")
        }
        print("PASS \(label) settles: layouts=\(layouts), height spread=\(spread), scroll spread=\(offsetSpread)")
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
        // A loading/failure row is much shorter than this square preview. Check
        // that the first completed turn actually contains the decoded image.
        if index == 0, (descendantScroll(host)?.documentView?.frame.height ?? 0) < 450 {
            throw AppError.message("Completed square preview did not occupy its image layout")
        }
    }
    for size in [NSSize(width: 380, height: 350), NSSize(width: 1200, height: 900)] {
        window.setContentSize(size)
        try await settle("resize \(Int(size.width)) × \(Int(size.height))")
        guard let scroll = descendantScroll(host), let document = scroll.documentView else {
            throw AppError.message("Conversation scroll view missing")
        }
        for y in [CGFloat(0), max(0, document.frame.height - scroll.contentView.bounds.height)] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle("scroll to \(Int(y)) at \(Int(size.width)) points")
        }
    }
}

@MainActor
private final class CountingConversationHost<Content: View>: NSHostingView<Content> {
    var layoutCount = 0
    override func layout() { layoutCount += 1; super.layout() }
}

@MainActor
private func descendantScroll(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap { descendantScroll($0) }.first
}

