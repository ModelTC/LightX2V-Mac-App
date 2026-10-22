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
        var job = Generation(request: request)
        job.python = settings.python
        job.enhancement?.mode = mode
        job.enhancement?.thinking = "Original thinking 中文 🐈"
        job.enhancement?.prompt = "Enhanced prompt " + mode.rawValue
        job.enhancement?.status = .completed
        job.actualWidth = 1184; job.actualHeight = 896
        job.status = .completed; job.finishedAt = Date(); job.duration = 1.25
        jobs.append(job)
        try JSONFile.write(GenerationRequestDocument(job), to: requestURL)
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: requestURL)) as! [String: Any]
        let documentSnapshot = document["generation"] as! [String: Any]
        let documentPE = documentSnapshot["promptEnhancement"] as! [String: Any]
        try expect(documentPE["output"] as? String == job.enhancement?.prompt, "request snapshot lost PE output")
        let documentRequest = try JSONFile.read(InferenceRequest.self, from: requestURL)
        try expect(documentRequest.prompt == request.prompt, "request snapshot changed the original inference prompt")
    }
    let stateURL = root.appendingPathComponent("workspace.json")
    try JSONFile.write(WorkspaceData(settings: settings, generations: jobs, hasCompletedGeneralSetup: true), to: stateURL)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
    let general = json["settings"] as! [String: Any]
    try expect(Set(general.keys) == ["python", "workingDirectory", "Qwen-Image-2.1-Turbo", "Qwen-Image-2.1-Turbo-INT8"], "settings are not model-scoped")
    let model = general["Qwen-Image-2.1-Turbo"] as! [String: Any]
    try expect(Set(model.keys) == ["modelDirectory", "modelDownloadSource", "promptEnhancement"], "model settings contain derived paths")
    let pe = model["promptEnhancement"] as! [String: Any]
    try expect(Set(pe.keys) == ["enabled", "t2iDirectory", "i2iDirectory"], "PE settings contain resolved file paths")
    let int8Model = general["Qwen-Image-2.1-Turbo-INT8"] as! [String: Any]
    try expect(Set(int8Model.keys) == ["modelDirectory", "modelDownloadSource", "promptEnhancement"], "INT8 model settings are persisted separately")
    let records = json["generations"] as! [[String: Any]]
    for (index, mode) in [PromptEnhancementMode.t2i, .i2i].enumerated() {
        let record = records[index]
        let modelSnapshot = record["model"] as! [String: Any]
        let params = record["parameters"] as! [String: Any]
        let enhanced = record["promptEnhancement"] as! [String: Any]
        try expect(modelSnapshot["name"] as? String == QwenImage21Turbo.title && modelSnapshot["directory"] as? String == settings.model, "history lost model identity/path")
        try expect(enhanced["output"] as? String == jobs[index].enhancement?.prompt && enhanced["thinking"] as? String == jobs[index].enhancement?.thinking, "history lost PE thinking/output")
        try expect(enhanced["modelFile"] as? String == (mode == .t2i ? jobs[index].request.promptEnhancement?.t2iModel : jobs[index].request.promptEnhancement?.i2iModel), "history lost exact GGUF path")
        try expect(enhanced["systemPromptFile"] as? String == (mode == .t2i ? jobs[index].request.promptEnhancement?.t2iSystemPrompt : jobs[index].request.promptEnhancement?.i2iSystemPrompt), "history lost exact system prompt path")
        try expect(params["aspectRatio"] as? String == "adaptive" && params["width"] as? Int == 1184 && params["height"] as? Int == 896 && params["steps"] as? Int == 8, "history lost actual adaptive dimensions/steps")
        if mode == .i2i { try expect(enhanced["visionProjectorFile"] as? String == jobs[index].request.promptEnhancement?.visionProjector, "history lost I2I projector") }
        let snapshotURL = root.appendingPathComponent(mode.rawValue + "/generation.json")
        try JSONFile.write(jobs[index], to: snapshotURL)
        let lines = try String(contentsOf: snapshotURL, encoding: .utf8).components(separatedBy: "\n")
        let keys = lines.filter { $0.hasPrefix("  \"") }.map { $0.components(separatedBy: "\"")[1] }
        try expect(keys == ["id", "creationID", "createdAt", "status", "model", "parameters", "prompt", "promptEnhancement", "inputImages", "outputImages", "execution"], "generation fields are not ordered for readability")
        func fields(in section: String) -> [String] {
            let start = lines.firstIndex { $0.hasPrefix("  \"" + section + "\": {") }!
            let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("  }") }!
            return lines[(start + 1)..<end].filter { $0.hasPrefix("    \"") }.map { $0.components(separatedBy: "\"")[1] }
        }
        try expect(fields(in: "model") == ["name", "directory", "configFile"], "model field order changed")
        try expect(fields(in: "parameters") == ["resolution", "aspectRatio", "width", "height", "steps", "seed"], "parameter field order changed")
        let expectedPE = ["enabled", "mode", "status", "modelName", "directory", "modelFile", "systemPromptFile"] + (mode == .i2i ? ["visionProjectorFile"] : []) + ["runtimeDirectory", "thinking", "output"]
        try expect(fields(in: "promptEnhancement") == expectedPE, "PE field order changed")
        try expect(fields(in: "execution") == ["directory", "sourceDirectory", "python", "requestFile", "logFile", "startedAt", "finishedAt", "durationSeconds"], "execution field order changed")

    }
    let restored = try JSONFile.read(WorkspaceData.self, from: stateURL)
    try expect(restored.settings == settings && restored.generations.map(\.id) == jobs.map(\.id), "current schema lost settings/history")
    try expect(restored.generations.map(\.creationID) == jobs.map(\.creationID), "current schema lost creation identities")
    for (original, restored) in zip(jobs, restored.generations) {
        try expect(restored.enhancement == original.enhancement && restored.python == original.python, "snapshot restoration lost enhancement/execution data")
        try expect(restored.request.resolution == 1024 && restored.request.width == nil && restored.actualWidth == 1184, "adaptive restoration changed requested versus actual dimensions")
    }
    var disabled = settings; disabled.promptEnhancement.enabled = false
    var noPE = Generation(request: try InferenceRequest(settings: disabled, prompt: "Original", width: 512, height: 512, seed: 1, output: root.appendingPathComponent("no-pe/image.png").path))
    noPE.status = .failed; noPE.error = "Failure retained"
    let noPEURL = root.appendingPathComponent("no-pe/generation.json")
    try JSONFile.write(noPE, to: noPEURL)
    let noPERecord = try JSONSerialization.jsonObject(with: Data(contentsOf: noPEURL)) as! [String: Any]
    try expect((noPERecord["promptEnhancement"] as! [String: Any]).count == 1, "disabled PE saved empty fields")
    let loadedNoPE = try JSONFile.read(Generation.self, from: noPEURL)
    try expect(loadedNoPE.request.promptEnhancement == nil && loadedNoPE.error == noPE.error && loadedNoPE.request.width == 512, "failed/disabled PE snapshot lost information")
    var rejectedRecord = false
    do { _ = try JSONDecoder().decode(Generation.self, from: Data("{\"id\":\"\(UUID().uuidString)\",\"request\":{}}".utf8)) } catch { rejectedRecord = true }
    try expect(rejectedRecord, "legacy generation record accepted")
    let old = Data(#"{"repository":"/old/source","model":"/old/model","config":"/old/config","python":"/old/python","workingDirectory":"/old/workspace","promptEnhancement":{}}"#.utf8)
    var rejected = false
    do { _ = try JSONDecoder().decode(AppSettings.self, from: old) } catch { rejected = true }
    try expect(rejected, "flat model settings were accepted")
    var legacyScoped = general
    legacyScoped.removeValue(forKey: "Qwen-Image-2.1-Turbo-INT8")
    let legacySettings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacyScoped))
    try expect(legacySettings.qwenImage21TurboInt8.modelDirectory.isEmpty, "old model-scoped settings did not default the INT8 profile")
    var invalid = general
    var invalidModel = model
    invalidModel["promptEnhancement"] = ["enabled": true, "t2iModel": "/old/model.gguf"]
    invalid["Qwen-Image-2.1-Turbo"] = invalidModel
    rejected = false
    do { _ = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: invalid)) } catch { rejected = true }
    try expect(rejected, "old PE file configuration was accepted")
    print("PASS readable complete generation snapshots, exact PE files/output, adaptive dimensions, disabled PE, round-trip and strict schema")
}
