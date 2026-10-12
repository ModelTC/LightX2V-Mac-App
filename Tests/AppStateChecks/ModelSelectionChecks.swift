import AppKit
import SwiftUI
import LightX2VCore

/// Measure the production native menu throughout first selection. Reserving an
/// outer frame alone is insufficient if the native menu itself still moves.
@MainActor
func modelSelectionLayoutChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("model-selection-" + UUID().uuidString)
    let previousSupport = getenv("LIGHTX2V_APP_STATE_DIR").map { String(cString: $0) }
    setenv("LIGHTX2V_APP_STATE_DIR", root.appendingPathComponent("support").path, 1)
    defer {
        if let previousSupport { setenv("LIGHTX2V_APP_STATE_DIR", previousSupport, 1) }
        else { unsetenv("LIGHTX2V_APP_STATE_DIR") }
        try? fm.removeItem(at: root)
    }
    let layout = WorkspaceLayout(root.appendingPathComponent("workspace").path)
    try layout.prepare()
    var settings = AppSettings.defaults
    settings.promptEnhancement.enabled = false
    settings.workingDirectory = layout.root.path
    settings.repository = root.appendingPathComponent("source").path
    settings.python = "/usr/bin/false"
    settings.promptEnhancement.runtimeDirectory = try runtimeFixture(in: root)
    try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: true), to: layout.state)
    try JSONFile.write(WorkspaceLocation(workingDirectory: layout.root.path),
                       to: root.appendingPathComponent("support/workspace_location.json"))
    func nativeMenu(in view: NSView) -> NSPopUpButton? {
        if let menu = view as? NSPopUpButton,
           menu.title == "选择模型" || menu.title == QwenImage21Turbo.title { return menu }
        return view.subviews.lazy.compactMap { nativeMenu(in: $0) }.first
    }
    func snapshot(_ name: String, of host: NSView) throws {
        guard let directory = ProcessInfo.processInfo.environment["LIGHTX2V_MODEL_SNAPSHOTS"] else { return }
        let url = URL(fileURLWithPath: directory)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw AppError.message("Model selection snapshot unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url.appendingPathComponent(name + ".png"))
    }
    for (width, height, workspace): (CGFloat, CGFloat, Bool) in [
        (380, 180, false), (568, 180, false), (850, 180, false),
        (1200, 900, true), (1440, 900, true)
    ] {
        let store = AppStore()
        let content = workspace ? AnyView(WorkspaceView()) : AnyView(ComposerView())
        let host = NSHostingView(rootView: content.environmentObject(store).preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        guard let menu = nativeMenu(in: host) else { throw AppError.message("Model menu missing") }
        let initial = menu.convert(menu.bounds, to: host)
        let name = "\(workspace ? "workspace" : "composer")-\(Int(width))"
        try snapshot(name + "-empty", of: host)
        store.selectModel(.qwenImage21Turbo)
        // Sample immediate and intermediate layouts, not only the settled frame.
        for _ in 0..<25 {
            host.layoutSubtreeIfNeeded()
            guard let current = nativeMenu(in: host) else { throw AppError.message("Model menu disappeared") }
            let frame = current.convert(current.bounds, to: host)
            let changes = [frame.minX - initial.minX, frame.minY - initial.minY,
                           frame.width - initial.width, frame.height - initial.height]
            guard changes.allSatisfy({ abs($0) < 0.5 }) else {
                throw AppError.message("Model menu moved after first selection in \(name): \(initial) -> \(frame)")
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        try snapshot(name + "-selected", of: host)
        print("PASS first model selection keeps the native menu position and size in \(name)")
    }
}
