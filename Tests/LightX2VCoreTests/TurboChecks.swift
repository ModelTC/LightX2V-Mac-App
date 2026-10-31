import Foundation
import LightX2VCore

func turboModelChecks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("turbo-paths-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("code/LightX2V-commit")
    let weights = root.appendingPathComponent("models/Qwen/" + QwenImage21Turbo.title)
    let config = source.appendingPathComponent(QwenImage21Turbo.configRelativePath)
    try expect(QwenImage21Turbo.inferenceSteps == 8 && QwenImage21Turbo.title == "Qwen-Image-2.1-Turbo", "Turbo identity or progress count changed")
    try expect(QwenImage21Turbo.suggestedConfig(repository: source.path) == nil, "missing Turbo config must not fall back to another model")
    try expect(QwenImage21Turbo.suggestedConfig(repository: "relative") == nil, "config suggestion accepted a relative source")
    try fm.createDirectory(at: weights, withIntermediateDirectories: true)
    try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: weights.appendingPathComponent("model_index.json"))
    try Data("{}".utf8).write(to: config)
    try expect(QwenImage21Turbo.suggestedConfig(repository: source.path) == config.path, "source preparation did not choose the Turbo config")
    print("PASS Turbo-only model identity, eight-step progress and preparation paths")
}

func turboInt8ModelChecks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("turbo-int8-paths-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let model = root.appendingPathComponent("Qwen-Image-2.1-Turbo-INT8")
    for name in ["transformer", "text_encoder", "vae", "scheduler", "processor"] {
        try fm.createDirectory(at: model.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try Data("{}".utf8).write(to: model.appendingPathComponent("model_index.json"))
    let metal = model.appendingPathComponent("apple_silicon_metal")
    try fm.createDirectory(at: metal, withIntermediateDirectories: true)
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/qwen-int8-metal")
    for file in try fm.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil) where file.pathExtension == "metallib" {
        try fm.copyItem(at: file, to: metal.appendingPathComponent(file.lastPathComponent))
    }
    try ModelResource.turboInt8.validate(directory: model.path)
    try expect(!fm.fileExists(atPath: metal.appendingPathComponent("manifest.json").path), "official model must work without a manifest")
    let library = metal.appendingPathComponent("int8_k4096_n4096.metallib")
    var payload = try Data(contentsOf: library)
    payload[0] ^= 1
    try payload.write(to: library)
    var corruptRejected = false
    do { try ModelResource.turboInt8.validate(directory: model.path) } catch { corruptRejected = true }
    try expect(corruptRejected, "same-size corruption must fail the bundled checksum")
    try expect(QwenImage21TurboInt8.suggestedConfig(repository: root.path) == nil, "INT8 config suggestion rejects a missing source config")
    try fm.removeItem(at: metal.appendingPathComponent("int8_k4096_n4096.metallib"))
    var rejected = false
    do { try ModelResource.turboInt8.validate(directory: model.path) } catch { rejected = true }
    try expect(rejected, "INT8 model rejects a missing Metal library")
    print("PASS manifest-free INT8 model, bundled Metal checksums and missing-library rejection")
}
