import AppKit
import SwiftUI
import LightX2VCore

@MainActor func imageResolutionChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightX2V-512-" + UUID().uuidString)
    let previous = ProcessInfo.processInfo.environment["LIGHTX2V_APP_STATE_DIR"]
    setenv("LIGHTX2V_APP_STATE_DIR", root.path, 1)
    defer {
        if let previous { setenv("LIGHTX2V_APP_STATE_DIR", previous, 1) } else { unsetenv("LIGHTX2V_APP_STATE_DIR") }
        try? FileManager.default.removeItem(at: root)
    }
    let store = AppStore()
    let host = NSHostingView(rootView: GenerationParametersView().environmentObject(store).padding(16).frame(width: 340, height: 480, alignment: .top).background(Palette.canvas).environment(\.colorScheme, .light))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    func segment(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        return view.subviews.compactMap { segment(in: $0) }.first
    }
    guard let control = segment(in: host), control.segmentCount == 3, control.label(forSegment: 0) == "512",
          store.generationSize.resolution == .oneK else { throw AppError.message("Resolution control must show 512, 1K and 2K with 1K selected by default") }
    store.generationSize.selectAspectRatio(.landscape169)
    control.selectedSegment = 0
    guard let action = control.action else { throw AppError.message("Resolution control action missing") }
    NSApplication.shared.sendAction(action, to: control.target, from: control)
    try await Task.sleep(for: .milliseconds(200))
    guard store.generationSize.resolution == .fiveTwelve,
          store.generationSize.dimensions == ImageDimensions(width: 672, height: 384) else { throw AppError.message("Clicking 512 did not retain the selected aspect ratio") }
    host.layoutSubtreeIfNeeded()
    if let destination = ProcessInfo.processInfo.environment["LIGHTX2V_RESOLUTION_SNAPSHOT"],
       let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
    }
    print("PASS native 512 / 1K / 2K control, default 1K, clicking 512 and preserved aspect ratio")
}
