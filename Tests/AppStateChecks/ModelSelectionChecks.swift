import AppKit
import SwiftUI
import LightX2VCore

/// Both model titles must fit the production selector without resizing it.
/// Render the surrounding composer at narrow and full workspace widths too.
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
        let selector = NSHostingView(rootView: ModelSelector().environmentObject(store).preferredColorScheme(.light))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let initial = selector.fittingSize
        guard initial.width == 246 && initial.height == 30 else {
            throw AppError.message("Unexpected model selector size: \(initial)")
        }
        let name = "\(workspace ? "workspace" : "composer")-\(Int(width))"
        try snapshot(name + "-empty", of: host)
        for model in GenerationModel.allCases {
            store.selectModel(model)
            // Sample immediate and intermediate layouts, not only the settled frame.
            for _ in 0..<25 {
                host.layoutSubtreeIfNeeded()
                selector.layoutSubtreeIfNeeded()
                let size = selector.fittingSize
                let changes = [size.width - initial.width, size.height - initial.height]
                guard changes.allSatisfy({ abs($0) < 0.5 }) else {
                    throw AppError.message("Model selector resized after selecting \(model.title) in \(name): \(initial) -> \(size)")
                }
                try await Task.sleep(for: .milliseconds(16))
            }
            try snapshot(name + "-" + model.id, of: host)
        }
        print("PASS both model versions keep the selector size in \(name)")
    }
}
