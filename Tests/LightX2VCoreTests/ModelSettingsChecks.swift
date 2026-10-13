import Foundation
import LightX2VCore

func modelSettingsChecks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("model-settings-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    var settings = AppSettings.defaults
    settings.python = "/selected/python"
    settings.workingDirectory = root.path
    settings.qwenImage21Turbo.modelDirectory = root.appendingPathComponent("Turbo").path
    settings.qwenImage21Turbo.modelDownloadSource = .modelScope
    for (mode, resource) in [(PromptEnhancementMode.t2i, ModelResource.t2i), (.i2i, .i2i)] {
        let folder = resource.destination(in: WorkspaceLayout(root.path))
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = mode == .t2i ? "Qwen-Image-2.1-PE-T2I" : "Qwen-Image-2.1-PE-I2I"
        try Data("fixture".utf8).write(to: folder.appendingPathComponent(name + "-Q8_0.gguf"))
        try Data("system prompt".utf8).write(to: folder.appendingPathComponent("system_prompt.txt"))
        if mode == .i2i { try Data("projector".utf8).write(to: folder.appendingPathComponent("mmproj-" + name + "-BF16.gguf")) }
        if mode == .t2i { settings.promptEnhancement.t2iDirectory = folder.path }
        else { settings.promptEnhancement.i2iDirectory = folder.path }
    }
    BundledInferenceResources.configure(&settings)
    var jobs: [Generation] = []
    for mode in [PromptEnhancementMode.t2i, .i2i] {
        var run = settings
        run.config = root.appendingPathComponent(mode.rawValue + "/config.json").path
        run.promptEnhancement = try run.promptEnhancement.resolvedResources(for: mode)
        let request = try InferenceRequest(settings: run, prompt: "Retain the prompt", width: nil, height: nil, seed: 42,
                                           output: root.appendingPathComponent(mode.rawValue + "/image.png").path, resolution: 1024)
        let requestURL = root.appendingPathComponent(mode.rawValue + "/request.json")
        try JSONFile.write(request, to: requestURL)
        let savedRequest = try JSONFile.read(InferenceRequest.self, from: requestURL)
        let pe = savedRequest.promptEnhancement!
        try expect((mode == .t2i ? pe.t2iSystemPrompt : pe.i2iSystemPrompt).hasSuffix("/system_prompt.txt"), "request lost its selected system prompt")
        try expect((mode == .t2i ? pe.t2iModel : pe.i2iModel).hasSuffix("-Q8_0.gguf"), "request lost its selected GGUF model")
        if mode == .i2i { try expect(pe.visionProjector.hasSuffix("-BF16.gguf"), "I2I request lost its projector") }
        jobs.append(Generation(request: request))
    }
    let stateURL = root.appendingPathComponent("workspace.json")
    try JSONFile.write(WorkspaceData(settings: settings, generations: jobs, hasCompletedGeneralSetup: true), to: stateURL)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
    let general = json["settings"] as! [String: Any]
    try expect(Set(general.keys) == ["python", "workingDirectory", "Qwen-Image-2.1-Turbo"], "settings are not model-scoped")
    let model = general["Qwen-Image-2.1-Turbo"] as! [String: Any]
    try expect(Set(model.keys) == ["modelDirectory", "modelDownloadSource", "promptEnhancement"], "model settings contain derived paths")
    let pe = model["promptEnhancement"] as! [String: Any]
    try expect(Set(pe.keys) == ["enabled", "t2iDirectory", "i2iDirectory"], "PE settings contain resolved file paths")
    let forbidden = ["runtimeDirectory", "t2iModel", "i2iModel", "t2iSystemPrompt", "i2iSystemPrompt", "visionProjector"]
    let text = try String(contentsOf: stateURL, encoding: .utf8)
    try expect(forbidden.allSatisfy { !text.contains("\"" + $0 + "\"") }, "workspace history duplicates PE file paths")
    let restored = try JSONFile.read(WorkspaceData.self, from: stateURL)
    try expect(restored.settings == settings && restored.generations.map(\.id) == jobs.map(\.id), "current schema lost settings/history")
    try expect(restored.generations.map(\.creationID) == jobs.map(\.creationID), "current schema lost creation identities")
    try expect(restored.generations.allSatisfy { $0.request.promptEnhancement?.runtimeDirectory == "" }, "history loaded derived runtime paths")
    let old = Data(#"{"repository":"/old/source","model":"/old/model","config":"/old/config","python":"/old/python","workingDirectory":"/old/workspace","promptEnhancement":{}}"#.utf8)
    var rejected = false
    do { _ = try JSONDecoder().decode(AppSettings.self, from: old) } catch { rejected = true }
    try expect(rejected, "flat model settings were accepted")
    var invalid = general
    var invalidModel = model
    invalidModel["promptEnhancement"] = ["enabled": true, "t2iModel": "/old/model.gguf"]
    invalid["Qwen-Image-2.1-Turbo"] = invalidModel
    rejected = false
    do { _ = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: invalid)) } catch { rejected = true }
    try expect(rejected, "old PE file configuration was accepted")
    print("PASS strict model-scoped settings, compact PE history, derived runtime restoration and exact T2I/I2I request snapshots")
}
