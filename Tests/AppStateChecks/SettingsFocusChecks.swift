import AppKit
import SwiftUI
import LightX2VCore

@MainActor
func generalSettingsFocusChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("settings-focus-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let support = root.appendingPathComponent("support")
    let layout = WorkspaceLayout(root.appendingPathComponent("workspace").path)
    try layout.prepare()
    var settings = AppSettings.defaults
    settings.workingDirectory = layout.root.path
    settings.repository = root.appendingPathComponent("source").path
    try fm.createDirectory(atPath: settings.repository + "/lightx2v", withIntermediateDirectories: true)
    try Data().write(to: URL(fileURLWithPath: settings.repository + "/lightx2v/infer.py"))
    settings.python = "/usr/bin/false"
    settings.promptEnhancement.runtimeDirectory = try runtimeFixture(in: root)
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: true), to: layout.state)
    try JSONFile.write(WorkspaceLocation(workingDirectory: layout.root.path), to: support.appendingPathComponent("workspace_location.json"))
    let store = AppStore()
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 768, height: 680),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.orderOut(nil); window.contentView = nil }
    window.contentView = NSHostingView(rootView: SettingsPresentationFixture(store: store))
    window.makeKeyAndOrderFront(nil)

    func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    func boundaries(_ view: NSView) -> [EditingBoundaryView] {
        (view as? EditingBoundaryView).map { [$0] } ?? view.subviews.flatMap(boundaries)
    }
    func check(_ good: Bool, _ message: String) throws {
        guard good else { throw AppError.message(message) }
        print("PASS \(message)")
    }
    for opening in 1...2 {
        store.showSettings = true
        try await Task.sleep(for: .milliseconds(700))
        guard let sheet = window.attachedSheet, let content = sheet.contentView else {
            throw AppError.message("General settings sheet did not open")
        }
        let inputs = fields(content).filter(\.isEditable)
        try check(inputs.count == 4 && inputs.allSatisfy { $0.currentEditor() == nil },
                  "settings opening \(opening) leaves every path unselected")
        try check(inputs.allSatisfy { content.bounds.contains($0.convert($0.bounds, to: content)) },
                  "default compact settings sheet shows all four paths without scrolling")
        let runtimeField = inputs.first { $0.stringValue == settings.promptEnhancement.runtimeDirectory }!
        let runtimeFrame = runtimeField.convert(runtimeField.bounds, to: content)
        let runtimeBoundary = boundaries(content).first {
            $0.convert($0.bounds, to: content).contains(NSPoint(x: runtimeFrame.midX, y: runtimeFrame.midY))
        }!
        runtimeBoundary.requestInputFocus(opening)
        try await Task.sleep(for: .milliseconds(150))
        try check(runtimeField.currentEditor() != nil && inputs.filter { $0 !== runtimeField }.allSatisfy { $0.currentEditor() == nil },
                  "missing-setting focus request selects only the fourth path")
        let workspaceField = inputs.first { $0.stringValue == settings.workingDirectory }!
        sheet.makeFirstResponder(workspaceField)
        try await Task.sleep(for: .milliseconds(100))
        try check(workspaceField.currentEditor() != nil, "workspace path still accepts explicit focus")
        // Initial focus is evaluated only on presentation, not after editing starts.
        try await Task.sleep(for: .milliseconds(250))
        try check(workspaceField.currentEditor() != nil, "settings does not steal focus from an active editor")
        sheet.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(100))
        try check(workspaceField.currentEditor() == nil, "outside click can end path editing")
        sheet.selectNextKeyView(nil)
        for _ in 0..<5 where !inputs.contains(where: { $0.currentEditor() != nil }) {
            try await Task.sleep(for: .milliseconds(50))
            sheet.selectNextKeyView(nil)
        }
        try check(inputs.contains { $0.currentEditor() != nil }, "settings paths remain accessible with Tab navigation")
        store.showSettings = false
        try await Task.sleep(for: .milliseconds(450))
    }

    // Saving dismisses the real sheet before a delayed dependency probe finishes.
    // Its onDisappear must not cancel that probe as if the user clicked Close.
    let python = root.appendingPathComponent("fixture-python")
    var versions: [String: Any] = ["python": "3.11.17", "architecture": "arm64", "mps": true, "detail": "MPS 可用"]
    for dependency in PyTorchRequirements.dependencies { versions[dependency.name] = dependency.minimum ?? "0.0.1.dev1" }
    let result = String(data: try JSONSerialization.data(withJSONObject: versions), encoding: .utf8)!
    try Data(("#!/usr/bin/python3\nimport time\ntime.sleep(0.7)\nprint('LIGHTX2V_ENV:' + " + String(reflecting: result) + ", flush=True)\n").utf8).write(to: python)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    var updated = settings; updated.python = python.path
    store.showSettings = true
    try await Task.sleep(for: .milliseconds(700))
    try await store.applyGeneralSettings(updated)
    try check(!store.showSettings && !store.showStartupSettings && store.isChecking,
              "successful save dismisses settings and starts the background dependency check")
    for _ in 0..<300 where store.isChecking || window.attachedSheet != nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    try check(window.attachedSheet == nil && store.environmentReady && store.setupTask == nil,
              "dependency check survives the settings sheet disappearing after save")

    store.showSettings = true
    try await Task.sleep(for: .milliseconds(700))
    var invalid = updated; invalid.python = root.appendingPathComponent("missing-python").path
    var rejected = false
    do { try await store.applyGeneralSettings(invalid) } catch { rejected = true }
    try check(rejected && store.showSettings && window.attachedSheet != nil && store.settings.python == updated.python,
              "failed save keeps the settings sheet and previously saved paths")
    store.closeGeneralSettings()
    try await Task.sleep(for: .milliseconds(450))

    // The same view is also the first-launch setup card, outside a sheet.
    try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: false), to: layout.state)
    let firstLaunch = AppStore()
    window.contentView = NSHostingView(rootView: SettingsView(settings: settings).environmentObject(firstLaunch))
    window.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(500))
    try check(fields(window.contentView!).filter(\.isEditable).allSatisfy { $0.currentEditor() == nil },
              "first launch does not automatically select the workspace path")
}

private struct SettingsPresentationFixture: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Text("Main window").frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $store.showSettings) {
                SettingsView(settings: store.settings).environmentObject(store)
            }
    }
}
