import AppKit
import SwiftUI
import LightX2VCore

@MainActor
func unifiedModelPreparationChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("unified-models-" + UUID().uuidString)
    let previous = getenv("LIGHTX2V_APP_STATE_DIR").map { String(cString: $0) }
    let support = root.appendingPathComponent("support")
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    defer {
        if let previous { setenv("LIGHTX2V_APP_STATE_DIR", previous, 1) } else { unsetenv("LIGHTX2V_APP_STATE_DIR") }
        try? fm.removeItem(at: root)
    }
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AppError.message(message) }; print("PASS " + message)
    }
    func file(_ path: URL, _ text: String = "fixture") throws {
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: path)
    }
    let layout = WorkspaceLayout(root.appendingPathComponent("workspace").path)
    var settings = AppSettings.defaults
    settings.workingDirectory = layout.root.path; settings.python = "/usr/bin/false"
    settings.repository = root.appendingPathComponent("source").path
    settings.config = "/missing/source/config.json"
    settings.promptEnhancement.runtimeDirectory = try runtimeFixture(in: root)
    try file(URL(fileURLWithPath: settings.repository + "/lightx2v/infer.py"))
    try layout.prepare()
    try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: true), to: layout.state)
    try JSONFile.write(WorkspaceLocation(workingDirectory: layout.root.path), to: support.appendingPathComponent("workspace_location.json"))
    let store = AppStore(); store.selectModel(.qwenImage21Turbo)
    let main = root.appendingPathComponent("Turbo")
    try file(main.appendingPathComponent("model_index.json"), "{}")
    for name in ["transformer", "text_encoder", "vae", "scheduler", "processor"] { try fm.createDirectory(at: main.appendingPathComponent(name), withIntermediateDirectories: true) }
    store.modelDirectory = main.path; store.applyModelSettings()
    try check(store.settings.model.isEmpty && store.errorMessage != nil, "enabled enhancement requires both repository directories at model save")
    store.setPromptEnhancementEnabled(false); store.applyModelSettings()
    try check(store.settings.model == main.path && store.settings.config.isEmpty && !store.hasUnsavedModelSettings, "disabling enhancement saves the main model without PE paths or source config")
    store.environmentReady = true; store.prompt = "config snapshot"; store.generate()
    try check(store.isRunning && store.generations.count == 1, "APP config permits submission without any source config file")
    while store.isRunning { try await Task.sleep(for: .milliseconds(10)) }
    let first = store.generations[0]
    try check(first.request.config == first.directory + "/config.json" && first.request.promptEnhancement == nil, "request references its own case config and disabled enhancement is absent")
    let cfg = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: first.request.config))) as! [String: Any]
    try check(cfg["infer_steps"] as? Int == 8 && cfg["attn_type"] as? String == "torch_sdpa_mps", "case config is written before the child process runs")
    for resource in [ModelResource.t2i, .i2i] {
        let directory = resource.destination(in: layout)
        let mode = resource == .t2i ? "T2I" : "I2I"
        try file(directory.appendingPathComponent("Qwen-Image-2.1-PE-" + mode + "-Q8_0.gguf"))
        try file(directory.appendingPathComponent("system_prompt.txt"))
        if resource == .i2i { try file(directory.appendingPathComponent("mmproj-Qwen-Image-2.1-PE-I2I-BF16.gguf")) }
        if resource == .t2i { store.t2iDirectory = directory.path } else { store.i2iDirectory = directory.path }
    }
    store.setPromptEnhancementEnabled(true); store.applyModelSettings()
    for _ in 0..<200 where !store.enhancementResourcesReady { try await Task.sleep(for: .milliseconds(10)) }
    try check(!store.hasUnsavedModelSettings && store.enhancementResourcesReady, "one save resolves both PE folders and their system prompts")
    store.prompt = "resolved resources"; store.generate()
    try check(store.isRunning, "resolved folder settings can submit enhancement")
    while store.isRunning { try await Task.sleep(for: .milliseconds(10)) }
    let next = store.generations[0]
    try check(next.request.promptEnhancement?.t2iSystemPrompt == store.t2iDirectory + "/system_prompt.txt" && next.request.config != first.request.config,
              "each request snapshots resolved PE files and an independent config")
    let reopened = AppStore()
    try check(reopened.selectedModel == nil && reopened.t2iDirectory == store.t2iDirectory && reopened.i2iDirectory == store.i2iDirectory,
              "relaunch remembers all model folders while leaving model selection empty")
    let host = NSHostingView(rootView: ModelPreparationView().environmentObject(store).preferredColorScheme(.light).frame(width: 280))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.contentView = nil }
    func settle() async throws -> CGFloat { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded(); return host.fittingSize.height }
    let height = try await settle()
    try check(height <= 410, "three model cards no longer reserve separate status rows")
    for scenario in ["ready", "download", "failed", "off"] {
        if scenario == "download" { store.activeModelDownload = .t2i; store.isPreparingResources = true; store.modelDownloadMessages[.t2i] = "Fetching 12 files: 25% · 1.2 / 7.8 GB" }
        if scenario == "failed" { store.activeModelDownload = nil; store.isPreparingResources = false; store.modelDownloadErrors.insert(.t2i); store.modelDownloadMessages[.t2i] = String(repeating: "下载失败请重试 ", count: 60) }
        if scenario == "off" { store.setPromptEnhancementEnabled(false) }
        let measured = try await settle()
        try check(abs(measured - height) < 1, "inline model panel keeps its geometry for " + scenario)
        if let output = ProcessInfo.processInfo.environment["LIGHTX2V_MODEL_SNAPSHOTS"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            try fm.createDirectory(atPath: output, withIntermediateDirectories: true)
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output + "/models-" + scenario + ".png"))
        }
    }
}
