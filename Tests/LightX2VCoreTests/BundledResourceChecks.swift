import Foundation
import LightX2VCore

func bundledResourceChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("bundled-resources-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let workspace = WorkspaceLayout(root.path)
    try workspace.prepare()
    let original = workspace.code.appendingPathComponent("user-source.txt")
    try Data("preserve".utf8).write(to: original)
    let previousDirectories = [
        "bundled-LightX2V-0.6.0-minimal-v1-llama-b11583",
        "bundled-LightX2V-19c19614-minimal-v1-llama-b11583",
        "bundled-LightX2V-0.6.1-minimal-v1-llama-b11583"
    ].map { workspace.runtimes.appendingPathComponent($0) }
    for directory in previousDirectories {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("previous runtime".utf8).write(to: directory.appendingPathComponent("preserve-sentinel"))
    }
    var settings = AppSettings.defaults
    settings.workingDirectory = root.path; settings.python = "/usr/bin/false"
    try expect(settings.hasGeneralPaths, "source and llama paths must no longer be required settings")
    try expect(GeneralSetupStep.allCases == [.workspace, .python], "general settings must contain only the two user paths")
    BundledInferenceResources.configure(&settings)
    let expectedRoot = workspace.runtimes.appendingPathComponent("bundled-LightX2V-0.6.1-minimal-v2-llama-b11583")
    try expect(BundledInferenceResources.sourceRevision == "0.6.1", "bundled source must use the 0.6.1 release")
    try expect(settings.repository == expectedRoot.appendingPathComponent("LightX2V-0.6.1").path, "source must use the 0.6.1 installation")
    for directory in previousDirectories {
        var previousSettings = settings
        previousSettings.repository = directory.appendingPathComponent("old-source").path
        previousSettings.promptEnhancement.runtimeDirectory = directory.appendingPathComponent("llama-b11583").path
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(previousSettings))
        try expect(restored.repository == settings.repository, "decoded settings reused the previous source")
        try expect(restored.promptEnhancement.runtimeDirectory == expectedRoot.appendingPathComponent("llama-b11583").path, "decoded settings reused the previous runtime")
        try expect(restored.python == settings.python && restored.workingDirectory == settings.workingDirectory, "engine upgrade changed user paths")
    }
    try await BundledInferenceResources.prepare(in: workspace)
    let prunedDirectories = ["assert", "assets", "dockerfiles", "docs", "examples", "lightx2v_rl", "lightx2v_ros", "lightx2v_train"]
    for directory in prunedDirectories {
        try expect(!fm.fileExists(atPath: settings.repository + "/" + directory), "Pruned source folder survived packaging")
    }
    try expect(fm.fileExists(atPath: settings.repository + "/LICENSE"), "Source license must be preserved")
    try expect(fm.fileExists(atPath: settings.repository + "/lightx2v_kernel/apple/python/lightx2v_kernel_apple/int8_gemm/gemm.py"), "upstream Apple INT8 kernel package must be bundled")
    try expect(!fm.fileExists(atPath: settings.repository + "/lightx2v/models/runners/qwen_image_21/int8_metal_binding.py"), "App must not depend on the optional Engine PR")
    try settings.validateGeneralPath(.source)
    try settings.validateGeneralPath(.llama)
    try expect(!settings.promptEnhancement.runtimeDirectory.hasSuffix("/bin"), "llama runtime must retain its original archive layout")
    for name in ["llama-completion", "llama-mtmd-cli"] {
        let result = try await SetupCommand.run(settings.promptEnhancement.runtimeDirectory + "/" + name, arguments: ["--version"], workspace: workspace)
        try expect(result.status == 0 && result.output.contains("11583"), "bundled runtime CLI cannot load its libraries")
    }
    let sentinel = URL(fileURLWithPath: settings.repository).appendingPathComponent("reuse-sentinel")
    try Data("keep".utf8).write(to: sentinel)
    for name in prunedDirectories {
        let directory = URL(fileURLWithPath: settings.repository).appendingPathComponent(name)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old source cache".utf8).write(to: directory.appendingPathComponent("sentinel"))
    }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await BundledInferenceResources.prepare(in: workspace)
    }
    var stopped = false
    do { try await cancelled.value } catch is CancellationError { stopped = true }
    try expect(stopped && prunedDirectories.allSatisfy { fm.fileExists(atPath: settings.repository + "/" + $0 + "/sentinel") }, "cancelled bundled cache reuse changed installed files")
    try await BundledInferenceResources.prepare(in: workspace)
    for name in prunedDirectories {
        try expect(!fm.fileExists(atPath: settings.repository + "/" + name), "bundled source cache retained pruned directory " + name)
    }
    let originalText = try String(contentsOf: original, encoding: .utf8)
    try expect(fm.fileExists(atPath: sentinel.path) && originalText == "preserve", "reuse overwrote existing data")
    for directory in previousDirectories {
        let previousText = try String(contentsOf: directory.appendingPathComponent("preserve-sentinel"), encoding: .utf8)
        try expect(previousText == "previous runtime", "engine upgrade changed the previous runtime")
    }
    let collision = WorkspaceLayout(root.appendingPathComponent("collision").path)
    try collision.prepare()
    let target = BundledInferenceResources.directory(in: collision)
    try fm.createDirectory(at: target, withIntermediateDirectories: true)
    let protected = target.appendingPathComponent("original")
    try Data("protected".utf8).write(to: protected)
    var rejected = false
    do { try await BundledInferenceResources.prepare(in: collision) } catch { rejected = true }
    try expect(rejected && fm.fileExists(atPath: protected.path), "unmanaged install collision was overwritten")
    print("PASS offline 0.6.1 extraction with RL pruning, settings upgrade, previous runtime preservation, both b11583 CLIs, reuse and collision protection")
}
