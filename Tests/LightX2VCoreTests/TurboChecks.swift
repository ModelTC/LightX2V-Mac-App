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
    let libraries = [
        ("int8_k4096_n4096.metallib", "kernel4096", 4096, 4096, "90b1185532406e24d61c9accca512dce2727e7920cbeb8b783e31fc203616af"),
        ("int8_k4096_n12288.metallib", "kernel12288", 4096, 12288, "2d031d09d5156cb2a163ca9f74496b74afebc19d5124bba0463ca0341bd4d621"),
        ("int8_k12288_n4096.metallib", "kernelmixed", 12288, 4096, "2002388bcecae71720f99434bc775816a425bce249d3e4db3a3def969544c00b")
    ]
    var entries = ""
    for (index, library) in libraries.enumerated() {
        try Data(library.1.utf8).write(to: metal.appendingPathComponent(library.0))
        if index > 0 { entries += "," }
        entries += "{\"file\":\"\(library.0)\",\"k\":\(library.2),\"n\":\(library.3),\"size\":\(library.1.utf8.count),\"sha256\":\"\(library.4)\"}"
    }
    let manifest = """
    {"schema_version":1,"model_repo":"lightx2v/Qwen-Image-2.1-Turbo-INT8","model_revision":"b572c2d129f1f440c1643e1be730ac1336f2d5d5","required_shapes":[{"k":4096,"n":4096,"weight_count":128},{"k":4096,"n":12288,"weight_count":64},{"k":12288,"n":4096,"weight_count":32}],"libraries":[\(entries)]}
    """
    try Data(manifest.utf8).write(to: metal.appendingPathComponent("manifest.json"))
    try ModelResource.turboInt8.validate(directory: model.path)
    try expect(QwenImage21TurboInt8.suggestedConfig(repository: root.path) == nil, "INT8 config suggestion rejects a missing source config")
    try fm.removeItem(at: metal.appendingPathComponent("int8_k4096_n4096.metallib"))
    var rejected = false
    do { try ModelResource.turboInt8.validate(directory: model.path) } catch { rejected = true }
    try expect(rejected, "INT8 model rejects a missing Metal library")
    print("PASS INT8 model manifest, required Metal libraries and checksum rejection")
}
