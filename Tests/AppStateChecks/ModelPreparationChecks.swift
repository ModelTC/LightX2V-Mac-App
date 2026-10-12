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
    store.modelDirectory = main.path
    try check(store.settings.model == main.path && store.settings.promptEnhancement.t2iDirectory.isEmpty, "main model automatically saves while both PE directories are empty")
    store.setPromptEnhancementEnabled(false)
    try check(store.settings.model == main.path && store.settings.config.isEmpty, "disabling enhancement saves the main model without PE paths or source config")
    store.modelDirectory = "  " + main.path + "\n"
    try check(store.settings.model == main.path && store.modelDirectory.hasPrefix("  ") && AppStore().modelDirectory == main.path,
              "manual path normalization persists without rewriting text under the cursor")
    store.modelDirectory = main.path
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
    store.setPromptEnhancementEnabled(true)
    for _ in 0..<200 where !store.enhancementResourcesReady { try await Task.sleep(for: .milliseconds(10)) }
    try check(store.enhancementResourcesReady, "automatic persistence resolves both PE folders and their system prompts")
    store.prompt = "resolved resources"; store.generate()
    try check(store.isRunning, "resolved folder settings can submit enhancement")
    while store.isRunning { try await Task.sleep(for: .milliseconds(10)) }
    let next = store.generations[0]
    try check(next.request.promptEnhancement?.t2iSystemPrompt == store.t2iDirectory + "/system_prompt.txt" && next.request.config != first.request.config,
              "each request snapshots resolved PE files and an independent config")
    let reopened = AppStore()
    try check(reopened.selectedModel == nil && reopened.t2iDirectory == store.t2iDirectory && reopened.i2iDirectory == store.i2iDirectory,
              "relaunch remembers all model folders while leaving model selection empty")
    let bin = root.appendingPathComponent("fake-python/bin")
    try file(bin.appendingPathComponent("python"), "#!/bin/sh\nexit 0\n")
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("python").path)
    let hf = bin.appendingPathComponent("hf")
    try file(hf, """
    #!/bin/sh
    mkdir -p "$4"
    case "$2" in
      Qwen/*) mkdir -p "$4"/transformer "$4"/text_encoder "$4"/vae "$4"/scheduler "$4"/processor; printf '{}' > "$4"/model_index.json ;;
      *PE-T2I*) printf weight > "$4"/Qwen-Image-2.1-PE-T2I-Q8_0.gguf; printf system > "$4"/system_prompt.txt ;;
    esac
    """)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hf.path)
    store.settings.python = bin.appendingPathComponent("python").path
    store.downloadModel(.turbo)
    for _ in 0..<500 where store.isPreparingResources { try await Task.sleep(for: .milliseconds(10)) }
    try check(!store.isPreparingResources && !store.modelDownloadErrors.contains(.turbo)
              && store.settings.model == ModelResource.turbo.destination(in: layout).path
              && AppStore().modelDirectory == store.settings.model,
              "automatic download completion persists owner-qualified destination without a view or save button")
    let peDirectory = ModelResource.t2i.destination(in: layout)
    try fm.removeItem(at: peDirectory.appendingPathComponent("Qwen-Image-2.1-PE-T2I-Q8_0.gguf"))
    store.refreshModelResources()
    store.setPromptEnhancementEnabled(false); store.setPromptEnhancementEnabled(true)
    for _ in 0..<200 where store.modelResourceMessages[.t2i] == nil { try await Task.sleep(for: .milliseconds(10)) }
    try check(!store.enhancementResourcesReady, "incomplete already-selected PE download destination is unavailable")
    store.downloadModel(.t2i)
    for _ in 0..<500 where store.isPreparingResources || !store.enhancementResourcesReady { try await Task.sleep(for: .milliseconds(10)) }
    try check(!store.isPreparingResources && store.enhancementResourcesReady && store.t2iDirectory == peDirectory.path,
              "downloading into an unchanged PE path refreshes availability and persists it")
    store.environmentReady = true
    store.t2iDirectory = root.appendingPathComponent("missing-PE").path
    try check(store.settings.promptEnhancement.t2iDirectory == store.t2iDirectory && store.settings.promptEnhancement.t2iModel.isEmpty,
              "invalid PE directory saves immediately and clears exact-file cache")
    try check(!store.enhancementResourcesReady && !store.readyModelResources.contains(.t2i), "changed paths immediately revoke readiness")
    store.t2iDirectory = ""
    store.modelDirectory = ""
    let cleared = AppStore()
    try check(cleared.modelDirectory.isEmpty && cleared.t2iDirectory.isEmpty && cleared.i2iDirectory == store.i2iDirectory,
              "clearing individual paths persists across relaunch without losing other paths")
    store.modelDirectory = root.appendingPathComponent("invalid-Turbo").path
    store.setPromptEnhancementEnabled(false); store.prompt = "invalid path"
    try check(!store.canGenerate && AppStore().modelDirectory == store.modelDirectory,
              "invalid main directory saves but immediately disables submission")
    store.modelDirectory = main.path
    store.setPromptEnhancementEnabled(true)
    store.environmentReady = true
    store.prompt = "missing resources"
    store.generate()
    try check(!store.isRunning && store.errorMessage != nil, "missing current-mode PE files block generation")
    store.setPromptEnhancementEnabled(false)
    try fm.removeItem(at: main.appendingPathComponent("model_index.json"))
    store.generate()
    try check(!store.isRunning && store.errorMessage != nil, "missing Turbo files block generation even with enhancement disabled")
    try check(store.environmentReady && !store.isChecking, "automatic model persistence never checks Python environment")
    try file(main.appendingPathComponent("model_index.json"), "{}")
    store.t2iDirectory = peDirectory.path
    store.setPromptEnhancementEnabled(true); store.refreshModelResources()
    for _ in 0..<200 where !store.enhancementResourcesReady || store.readyModelResources.count != 3 { try await Task.sleep(for: .milliseconds(10)) }
    try check(store.readyModelResources.count == 3 && store.canGenerate, "restored model files permit generation without another save or environment check")
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
