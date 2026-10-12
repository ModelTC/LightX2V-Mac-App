import AppKit
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
    let store = AppStore()
    try check(store.needsGeneralSetup && store.modelDirectory.isEmpty,
              "first launch has no model paths or general setup")
    var settings = AppSettings(repository: source.path, model: "", config: "", python: "/usr/bin/false",
                               workingDirectory: root.appendingPathComponent("workspace").path)
    settings.promptEnhancement.runtimeDirectory = try runtimeFixture(in: root)
    try await store.applyGeneralSettings(settings)
    while store.isChecking { try await Task.sleep(for: .milliseconds(10)) }
    try check(!store.needsGeneralSetup && store.selectedModel == nil && store.settings.config.isEmpty,
              "saving first setup leaves configuration APP-managed and still requires model selection")
    store.selectModel(.qwenImage21Turbo)
    try check(store.modelDirectory == weights.path && store.settings.model == weights.path,
              "selecting Turbo automatically persists nearby weights")
    store.setPromptEnhancementEnabled(false)
    while store.isChecking { try await Task.sleep(for: .milliseconds(10)) }
    try check(store.settings.model == weights.path && !store.environmentReady,
              "preparation saves Turbo paths without treating an invalid Python as ready")
    store.modelDirectory = root.appendingPathComponent("custom-weights").path
    store.selectModel(.qwenImage21Turbo)
    try check(store.modelDirectory.hasSuffix("custom-weights"), "model selection preserves an explicit model path")
    let reopened = AppStore()
    try check(!reopened.needsGeneralSetup && reopened.selectedModel == nil && reopened.modelDirectory == root.appendingPathComponent("custom-weights").path
              && !reopened.modelPreparationExpanded,
              "relaunch remembers the prepared paths without selecting or expanding the model")
}
