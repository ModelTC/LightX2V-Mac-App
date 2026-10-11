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
    try expect(QwenImage21Turbo.suggestedModel(near: [source.path]) == weights.path, "Turbo weights beside the code folder were not discovered")
    try expect(QwenImage21Turbo.suggestedModel(near: [root.appendingPathComponent("new-workspace").path]) == weights.path,
               "Turbo discovery must work from a fresh workspace")
    try fm.removeItem(at: weights)
    try expect(QwenImage21Turbo.suggestedModel(near: [root.path]) == nil, "missing weights must not substitute another model")
    print("PASS Turbo-only model identity, eight-step progress and preparation paths")
}
