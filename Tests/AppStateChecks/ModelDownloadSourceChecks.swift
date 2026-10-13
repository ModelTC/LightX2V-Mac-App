import AppKit
import SwiftUI
import LightX2VCore

@MainActor func modelDownloadSourceChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("LightX2V-source-" + UUID().uuidString)
    let previous = ProcessInfo.processInfo.environment["LIGHTX2V_APP_STATE_DIR"]
    setenv("LIGHTX2V_APP_STATE_DIR", root.path, 1)
    defer {
        if let previous { setenv("LIGHTX2V_APP_STATE_DIR", previous, 1) } else { unsetenv("LIGHTX2V_APP_STATE_DIR") }
        try? fm.removeItem(at: root)
    }
    let store = AppStore(); store.settings.workingDirectory = root.path
    let host = NSHostingView(rootView: ModelPreparationView().environmentObject(store).frame(width: 340).padding(16).background(Palette.canvas).environment(\.colorScheme, .light))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 372, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host; window.setContentSize(host.fittingSize); window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
    func segment(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        return view.subviews.compactMap { segment(in: $0) }.first
    }
    guard let control = segment(in: host), control.segmentCount == 2,
          control.label(forSegment: 0) == "Hugging Face", control.label(forSegment: 1) == "ModelScope" else { throw AppError.message("Shared download source control missing") }
    let originalSize = host.fittingSize
    control.selectedSegment = 1
    guard let action = control.action else { throw AppError.message("Source control action missing") }
    NSApplication.shared.sendAction(action, to: control.target, from: control)
    try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
    guard store.settings.modelDownloadSource == .modelScope, host.fittingSize == originalSize,
          AppStore().settings.modelDownloadSource == .modelScope else { throw AppError.message("Source switch changed card layout or failed to persist") }
    func capture(_ view: NSView, _ name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["LIGHTX2V_SOURCE_SNAPSHOTS"], let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }
    try capture(host, "modelscope-selected")
    store.activeModelDownload = .t2i; store.isPreparingResources = true
    var progress = ModelDownloadProgress(); progress.stage = .downloading; progress.totalFiles = 32; progress.completedFiles = 26
    progress.bytesPerSecond = 5_000_000; progress.speedUpdatedAt = Date(); store.modelDownloadProgress[.t2i] = progress
    try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
    store.setModelDownloadSource(.huggingFace)
    guard !control.isEnabled, store.settings.modelDownloadSource == .modelScope, host.fittingSize == originalSize else { throw AppError.message("Download must lock source and retain card height") }
    try capture(host, "modelscope-downloading")
    store.activeModelDownload = nil; store.isPreparingResources = false
    for source in ModelDownloadSource.allCases {
        for resource in ModelResource.allCases {
            let guideHost = NSHostingView(rootView: ModelDownloadGuide(resource: resource, source: source).background(Palette.surface).environment(\.colorScheme, .light))
            window.contentView = guideHost; window.setContentSize(guideHost.fittingSize)
            try await Task.sleep(for: .milliseconds(150)); guideHost.layoutSubtreeIfNeeded()
            guard guideHost.fittingSize.width <= 431, guideHost.fittingSize.height < 400 else { throw AppError.message("Download guide exceeds compact popover bounds") }
            try capture(guideHost, source.rawValue + "-" + resource.rawValue)
        }
    }
    print("PASS shared source control, native switching, saved preference, stable card height, source lock and six compact download guides")
}
