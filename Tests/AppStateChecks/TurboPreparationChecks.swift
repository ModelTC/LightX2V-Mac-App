import AppKit
import SwiftUI
import LightX2VCore

@MainActor
func turboPreparationChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("turbo-setup-" + UUID().uuidString)
    let support = root.appendingPathComponent("support")
    let previousSupport = getenv("LIGHTX2V_APP_STATE_DIR").map { String(cString: $0) }
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    defer {
        if let previousSupport { setenv("LIGHTX2V_APP_STATE_DIR", previousSupport, 1) }
        else { unsetenv("LIGHTX2V_APP_STATE_DIR") }
        try? fm.removeItem(at: root)
    }
    let source = root.appendingPathComponent("code/LightX2V-commit")
    let config = source.appendingPathComponent(QwenImage21Turbo.configRelativePath)
    let weights = root.appendingPathComponent("models/Qwen/" + QwenImage21Turbo.title)
    for directory in [source.appendingPathComponent("lightx2v"), config.deletingLastPathComponent(), weights] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data().write(to: source.appendingPathComponent("lightx2v/infer.py"))
    try Data("{}".utf8).write(to: config)
    try fm.createDirectory(at: weights.appendingPathComponent("transformer"), withIntermediateDirectories: true)
    try fm.createDirectory(at: weights.appendingPathComponent("text_encoder"), withIntermediateDirectories: true)
    try fm.createDirectory(at: weights.appendingPathComponent("vae"), withIntermediateDirectories: true)
    try fm.createDirectory(at: weights.appendingPathComponent("scheduler"), withIntermediateDirectories: true)
    try fm.createDirectory(at: weights.appendingPathComponent("processor"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: weights.appendingPathComponent("model_index.json"))
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw AppError.message(message) }
        print("PASS \(message)")
    }
    func capture(_ store: AppStore, _ name: String) async throws {
        guard let folder = ProcessInfo.processInfo.environment["LIGHTX2V_MODEL_SNAPSHOTS"] else { return }
        let host = NSHostingView(rootView: ModelPreparationView().environmentObject(store).preferredColorScheme(.light).frame(width: 340).padding(16))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 372, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded()
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AppError.message("Model paths UI snapshot unavailable") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }
    let store = AppStore()
    try check(store.needsGeneralSetup && store.modelDirectory.isEmpty,
              "first launch has no model paths or general setup")
    var settings = AppSettings(repository: source.path, model: "", config: "", python: "/usr/bin/false",
                               workingDirectory: root.appendingPathComponent("workspace").path)
    settings.promptEnhancement.runtimeDirectory = try runtimeFixture(in: root)
    let layout = WorkspaceLayout(settings.workingDirectory)
    for resource in [ModelResource.t2i, .i2i] {
        let directory = resource.destination(in: layout)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = resource == .t2i ? "Qwen-Image-2.1-PE-T2I" : "Qwen-Image-2.1-PE-I2I"
        for file in [name + "-Q8_0.gguf", "system_prompt.txt"] {
            try Data("fixture".utf8).write(to: directory.appendingPathComponent(file))
        }
        if resource == .i2i { try Data("fixture".utf8).write(to: directory.appendingPathComponent("mmproj-" + name + "-BF16.gguf")) }
        try resource.validate(directory: directory.path)
    }
    try await store.applyGeneralSettings(settings)
    while store.isChecking { try await Task.sleep(for: .milliseconds(10)) }
    try check(!store.needsGeneralSetup && store.selectedModel == nil && store.settings.config.isEmpty,
              "saving first setup leaves configuration APP-managed and still requires model selection")
    store.selectModel(.qwenImage21Turbo)
    try check(store.modelDirectory.isEmpty && store.t2iDirectory.isEmpty && store.i2iDirectory.isEmpty,
              "first selection keeps all three paths empty despite nearby Turbo weights and complete cached PE folders")
    store.selectModel(.qwenImage21Turbo)
    store.setPromptEnhancementEnabled(false); store.setPromptEnhancementEnabled(true)
    try check(store.settings.model.isEmpty && store.settings.promptEnhancement.t2iDirectory.isEmpty && store.settings.promptEnhancement.i2iDirectory.isEmpty,
              "repeated selection and PE toggling do not discover or persist model folders")
    try await capture(store, "new-workspace-empty")
    store.modelDirectory = weights.path
    store.t2iDirectory = ModelResource.t2i.destination(in: layout).path
    store.i2iDirectory = ModelResource.i2i.destination(in: layout).path
    store.setPromptEnhancementEnabled(false)
    while store.isChecking { try await Task.sleep(for: .milliseconds(10)) }
    try check(store.settings.model == weights.path && !store.environmentReady,
              "preparation saves Turbo paths without treating an invalid Python as ready")
    let custom = root.appendingPathComponent("custom-weights")
    try fm.copyItem(at: weights, to: custom)
    store.modelDirectory = custom.path
    store.selectModel(.qwenImage21Turbo)
    try check(store.modelDirectory.hasSuffix("custom-weights"), "model selection preserves an explicit model path")
    let reopened = AppStore()
    try check(!reopened.needsGeneralSetup && reopened.selectedModel == nil && reopened.modelDirectory == root.appendingPathComponent("custom-weights").path
              && !reopened.modelPreparationExpanded,
              "relaunch remembers the prepared paths without selecting or expanding the model")
    try check(reopened.t2iDirectory == store.t2iDirectory && reopened.i2iDirectory == store.i2iDirectory,
              "relaunch restores both explicitly saved PE model folders")
    reopened.selectModel(.qwenImage21Turbo)
    reopened.setPromptEnhancementEnabled(true)
    try await capture(reopened, "saved-workspace-restored")
    let savedBytes = try Data(contentsOf: layout.state)
    try fm.removeItem(at: support.appendingPathComponent("workspace_location.json"))
    let disconnected = AppStore()
    try check(disconnected.modelDirectory.isEmpty && disconnected.t2iDirectory.isEmpty && disconnected.i2iDirectory.isEmpty,
              "missing locator leaves all model paths empty even with existing folders nearby")
    var selection = AppSettings.defaults; selection.workingDirectory = layout.root.path
    try await disconnected.applyGeneralSettings(selection)
    disconnected.selectModel(.qwenImage21Turbo)
    try check(disconnected.modelDirectory == custom.path && disconnected.t2iDirectory == store.t2iDirectory && disconnected.i2iDirectory == store.i2iDirectory,
              "explicit workspace reconnection restores all saved model paths")
    let retained = try Data(contentsOf: layout.state)
    try check(retained == savedBytes, "workspace reconnection preserves saved model configuration bytes")
    disconnected.modelDirectory = ""; disconnected.t2iDirectory = ""; disconnected.i2iDirectory = ""
    disconnected.selectModel(.qwenImage21Turbo)
    let cleared = AppStore()
    cleared.selectModel(.qwenImage21Turbo)
    try check(cleared.modelDirectory.isEmpty && cleared.t2iDirectory.isEmpty && cleared.i2iDirectory.isEmpty,
              "cleared paths remain empty after selection and relaunch despite cached model files")
}
