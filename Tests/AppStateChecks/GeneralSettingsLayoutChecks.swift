import AppKit
import SwiftUI
import LightX2VCore

@MainActor
func generalSettingsLayoutChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("settings-layout-" + UUID().uuidString)
    let previous = getenv("LIGHTX2V_APP_STATE_DIR").map { String(cString: $0) }
    let support = root.appendingPathComponent("support")
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    defer {
        if let previous { setenv("LIGHTX2V_APP_STATE_DIR", previous, 1) } else { unsetenv("LIGHTX2V_APP_STATE_DIR") }
        try? fm.removeItem(at: root)
    }
    let layout = WorkspaceLayout(root.appendingPathComponent("workspace").path)
    try layout.prepare()
    var settings = AppSettings.defaults
    settings.workingDirectory = layout.root.path
    settings.repository = root.appendingPathComponent("source").path
    settings.python = "/usr/bin/false"
    settings.promptEnhancement.runtimeDirectory = try runtimeFixture(in: root)
    try fm.createDirectory(atPath: settings.repository + "/lightx2v", withIntermediateDirectories: true)
    try Data().write(to: URL(fileURLWithPath: settings.repository + "/lightx2v/infer.py"))
    func store(_ value: AppSettings, completed: Bool = true) throws -> AppStore {
        try JSONFile.write(WorkspaceData(settings: value, hasCompletedGeneralSetup: completed), to: layout.state)
        try JSONFile.write(WorkspaceLocation(workingDirectory: layout.root.path), to: support.appendingPathComponent("workspace_location.json"))
        return AppStore()
    }
    func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    func check(_ good: Bool, _ message: String) throws {
        guard good else { throw AppError.message(message) }
        print("PASS " + message)
    }
    func geometry(_ host: NSView) throws -> [String: NSRect] {
        host.layoutSubtreeIfNeeded()
        let inputs = fields(host).filter(\.isEditable).sorted { $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY }
        guard inputs.count == 2 else { throw AppError.message("Both setting paths must exist without scrolling") }
        var frames: [String: NSRect] = [:]
        for (index, input) in inputs.enumerated() {
            let frame = input.convert(input.bounds, to: host)
            guard host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), input.visibleRect.contains(input.bounds),
                  frame.width >= 100 && frame.height >= 12 else {
                throw AppError.message("Setting path clipped in default window: \(index): \(frame), \(host.bounds); input bounds \(input.bounds), visible \(input.visibleRect)")
            }
            frames["path-\(index)"] = frame
        }
        return frames
    }
    func snapshot(_ name: String, _ host: NSView) throws {
        guard let path = ProcessInfo.processInfo.environment["LIGHTX2V_SETTINGS_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 680),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.orderOut(nil); window.contentView = nil }
    for (name, value, completed) in [
        ("empty", AppSettings.defaults, false),
        ("missing-fourth", { var value = settings; value.promptEnhancement.runtimeDirectory = ""; return value }(), true),
        ("ready", settings, true)
    ] {
        let app = try store(value, completed: completed)
        let host = NSHostingView(rootView: SettingsView(settings: value).environmentObject(app).preferredColorScheme(.light))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        try await Task.sleep(for: .milliseconds(150))
        try check(host.fittingSize.height <= 680, "\(name) three-item general settings fits the default sheet: \(host.fittingSize)")
        _ = try geometry(host)
        try snapshot(name, host)
    }
    let app = try store(settings)
    let host = NSHostingView(rootView: SettingsView(settings: settings).environmentObject(app).preferredColorScheme(.light))
    window.contentView = host; window.setContentSize(host.fittingSize)
    try await Task.sleep(for: .milliseconds(200))
    let initial = try geometry(host)
    let initialSize = host.fittingSize
    func sample(_ name: String) async throws {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            guard abs(size.height - initialSize.height) < 0.5 && abs(size.width - initialSize.width) < 0.5 else {
                throw AppError.message("General settings changed fitting size during \(name): \(initialSize) -> \(size)")
            }
            let frames = try geometry(host)
            for (key, frame) in frames {
                let before = initial[key]!
                guard [frame.minX - before.minX, frame.minY - before.minY, frame.width - before.width, frame.height - before.height]
                    .allSatisfy({ abs($0) < 0.5 }) else {
                    throw AppError.message("General settings moved \(key) during \(name): \(before) -> \(frame)")
                }
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        try snapshot(name, host)
        print("PASS fixed field and window geometry during " + name)
    }
    app.isPreparingResources = true
    try await sample("bundled-preparation")
    app.isPreparingResources = false
    app.isChecking = true; app.environmentMessage = "正在检查环境依赖与 MPS…"
    try await sample("environment-checking")
    app.isChecking = false; app.environmentReady = false
    app.environmentMessage = "缺少 loguru；" + String(repeating: "依赖无法导入：详细错误信息。\n", count: 20)
    try await sample("environment-failed")
    app.environmentReady = true; app.environmentMessage = "环境依赖符合要求。"
    try await sample("environment-ready")
    app.isPreparingWorkspace = true
    try await sample("saving")
    app.isPreparingWorkspace = false; app.settings.promptEnhancement.runtimeDirectory = ""
    app.errorMessage = "保存失败：" + String(repeating: "目录没有写入权限，请重新选择工作目录。\n", count: 20)
    try await sample("save-long-error")

    let first = try store(settings, completed: false)
    let firstHost = NSHostingView(rootView: FirstLaunchSetupView().environmentObject(first).preferredColorScheme(.light))
    window.contentView = firstHost; window.setContentSize(NSSize(width: 688, height: 740))
    try await Task.sleep(for: .milliseconds(200))
    try check(firstHost.fittingSize.height <= 740, "three-item first-launch card fits a compact laptop window")
    _ = try geometry(firstHost)
    try snapshot("first-launch", firstHost)
}
