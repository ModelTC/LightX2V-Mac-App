import Foundation
import LightX2VCore

func enhancementChecks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("pe-resources-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    func file(_ relative: String, executable: Bool = false) throws -> String {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url.path
    }
    let source = try file("code/LightX2V-commit/lightx2v/infer.py")
    let model = try file("models/Qwen/Qwen-Image-2.1-merged/model_index.json")
    let binary = try file(".qwen-image-pe-t2i/build/bin/llama-completion", executable: true)
    _ = try file(".qwen-image-pe-t2i/build/bin/llama-mtmd-cli", executable: true)
    for mode in ["T2I", "I2I"] {
        let name = "Qwen-Image-2.1-PE-" + mode
        _ = try file("models/Qwen/\(name)/system_prompt.txt")
        _ = try file("models/Qwen/\(name)-GGUF/\(name)-Q8_0.gguf")
    }
    let projector = try file("models/Qwen/Qwen-Image-2.1-PE-I2I-GGUF/mmproj-Qwen-Image-2.1-PE-I2I-F16.gguf")
    var settings = AppSettings.defaults
    try expect(settings.promptEnhancement.enabled, "new configuration enables prompt enhancement by default")
    let defaultRequest = try InferenceRequest(settings: settings, prompt: "Original 中文", width: 512, height: 512, seed: 42, output: "/tmp/image.png")
    try expect(defaultRequest.promptEnhancement?.enabled == true && Generation(request: defaultRequest).enhancement?.mode == .t2i,
               "default submission includes enhancement before image inference")
    settings.promptEnhancement.enabled = false
    let off = try InferenceRequest(settings: settings, prompt: "Original 中文", width: 512, height: 512, seed: 42, output: "/tmp/image.png")
    let offJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(off)) as! [String: Any]
    try expect(offJSON["promptEnhancement"] == nil && !settings.promptEnhancement.enabled, "off requests must preserve the existing protocol")
    let disabled = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    try expect(!disabled.promptEnhancement.enabled, "an explicitly disabled enhancement stays disabled after restoring settings")
    settings.promptEnhancement.discover(near: [URL(fileURLWithPath: model).deletingLastPathComponent().path, source])
    try expect(settings.promptEnhancement.runtimeDirectory == URL(fileURLWithPath: binary).deletingLastPathComponent().path, "nested source/model should discover script resource layout")
    try settings.promptEnhancement.validate(for: .t2i)
    try settings.promptEnhancement.validate(for: .i2i)
    let explicit = try file("custom.gguf")
    settings.promptEnhancement.t2iModel = explicit
    settings.promptEnhancement.discover(near: [root.path])
    try expect(settings.promptEnhancement.t2iModel == explicit, "discovery must not replace explicit custom paths")
    try fm.removeItem(atPath: projector)
    try settings.promptEnhancement.validate(for: .t2i)
    var rejected = false
    do { try settings.promptEnhancement.validate(for: .i2i) } catch { rejected = true }
    try expect(rejected, "reference enhancement requires a vision projector independently of text enhancement")
    settings.promptEnhancement.enabled = true
    let request = try InferenceRequest(settings: settings, prompt: "Original 中文", width: nil, height: nil, seed: 42, output: "/tmp/image.png", resolution: 1024)
    var job = Generation(request: request)
    job.enhancement?.thinking = "思考 🐈"
    job.enhancement?.prompt = "Enhanced prompt"
    job.enhancement?.status = .completed
    let decoded = try JSONDecoder().decode(Generation.self, from: JSONEncoder().encode(job))
    try expect(decoded.request.prompt == "Original 中文" && decoded.enhancement == job.enhancement && decoded.title == "Original 中文", "original title and both enhancement outputs must round-trip")
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    try expect(restored.promptEnhancement == settings.promptEnhancement, "enhancement preference/resources must persist")
    var workspace = WorkspaceData(generations: [Generation(request: request), job])
    workspace.recoverInterrupted()
    try expect(workspace.generations[0].enhancement?.status == .interrupted && workspace.generations[1].enhancement?.status == .completed, "crash recovery preserves a completed enhancement and interrupts pending thinking")
    print("PASS enhancement configuration discovery, validation, request snapshots, persistence and recovery")
}
