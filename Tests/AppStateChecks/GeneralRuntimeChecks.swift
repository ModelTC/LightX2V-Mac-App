import Foundation
import LightX2VCore

func runtimeFixture(in root: URL) throws -> String {
    let bin = root.appendingPathComponent("fixture-bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in ["llama-completion", "llama-mtmd-cli"] {
        let file = bin.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    return bin.path
}

@MainActor
func generalRuntimeChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("general-runtime-" + UUID().uuidString)
    let previous = getenv("LIGHTX2V_APP_STATE_DIR").map { String(cString: $0) }
    setenv("LIGHTX2V_APP_STATE_DIR", root.appendingPathComponent("support").path, 1)
    defer {
        if let previous { setenv("LIGHTX2V_APP_STATE_DIR", previous, 1) } else { unsetenv("LIGHTX2V_APP_STATE_DIR") }
        try? fm.removeItem(at: root)
    }
    let store = AppStore()
    var settings = AppSettings.defaults
    settings.repository = root.appendingPathComponent("source").path
    settings.python = "/usr/bin/false"; settings.workingDirectory = root.appendingPathComponent("workspace").path
    settings.promptEnhancement.runtimeDirectory = try runtimeFixture(in: root)
    try fm.createDirectory(atPath: settings.repository + "/lightx2v", withIntermediateDirectories: true)
    try Data().write(to: URL(fileURLWithPath: settings.repository + "/lightx2v/infer.py"))
    store.settings.promptEnhancement.t2iDirectory = "/existing/PE-T2I"
    try await store.applyGeneralSettings(settings)
    while store.isChecking { try await Task.sleep(for: .milliseconds(20)) }
    guard !store.needsGeneralSetup,
          store.settings.promptEnhancement.runtimeDirectory == BundledInferenceResources.directory(in: WorkspaceLayout(settings.workingDirectory)).appendingPathComponent("llama-b11583").path,
          store.settings.promptEnhancement.t2iDirectory == "/existing/PE-T2I" else {
        throw AppError.message("General settings did not save the shared runtime independently of PE models")
    }
    var enhancement = store.settings.promptEnhancement
    enhancement.runtimeDirectory = "/stale/hidden-runtime"; enhancement.t2iDirectory = "/new/PE-T2I"
    store.applyEnhancementSettings(enhancement)
    let reopened = AppStore()
    guard reopened.settings.promptEnhancement.runtimeDirectory == store.settings.promptEnhancement.runtimeDirectory,
          reopened.settings.promptEnhancement.t2iDirectory == "/new/PE-T2I" else {
        throw AppError.message("PE model edits overwrote the runtime owned by general settings")
    }
    print("PASS general settings owns the persisted runtime and PE model edits preserve it")
}
