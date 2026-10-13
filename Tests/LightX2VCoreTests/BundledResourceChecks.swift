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
    var settings = AppSettings.defaults
    settings.workingDirectory = root.path; settings.python = "/usr/bin/false"
    try expect(settings.hasGeneralPaths, "source and llama paths must no longer be required settings")
    try expect(GeneralSetupStep.allCases == [.workspace, .python], "general settings must contain only the two user paths")
    BundledInferenceResources.configure(&settings)
    try await BundledInferenceResources.prepare(in: workspace)
    for directory in ["assert", "assets", "dockerfiles", "docs", "examples", "lightx2v_ros", "lightx2v_train"] {
        try expect(!fm.fileExists(atPath: settings.repository + "/" + directory), "Pruned source folder survived packaging")
    }
    try expect(fm.fileExists(atPath: settings.repository + "/LICENSE"), "Source license must be preserved")
    try settings.validateGeneralPath(.source)
    try settings.validateGeneralPath(.llama)
    try expect(!settings.promptEnhancement.runtimeDirectory.hasSuffix("/bin"), "llama runtime must retain its original archive layout")
    for name in ["llama-completion", "llama-mtmd-cli"] {
        let result = try await SetupCommand.run(settings.promptEnhancement.runtimeDirectory + "/" + name, arguments: ["--version"], workspace: workspace)
        try expect(result.status == 0 && result.output.contains("11583"), "bundled runtime CLI cannot load its libraries")
    }
    let sentinel = URL(fileURLWithPath: settings.repository).appendingPathComponent("reuse-sentinel")
    try Data("keep".utf8).write(to: sentinel)
    try await BundledInferenceResources.prepare(in: workspace)
    let originalText = try String(contentsOf: original, encoding: .utf8)
    try expect(fm.fileExists(atPath: sentinel.path) && originalText == "preserve", "reuse overwrote existing data")
    let collision = WorkspaceLayout(root.appendingPathComponent("collision").path)
    try collision.prepare()
    let target = BundledInferenceResources.directory(in: collision)
    try fm.createDirectory(at: target, withIntermediateDirectories: true)
    let protected = target.appendingPathComponent("original")
    try Data("protected".utf8).write(to: protected)
    var rejected = false
    do { try await BundledInferenceResources.prepare(in: collision) } catch { rejected = true }
    try expect(rejected && fm.fileExists(atPath: protected.path), "unmanaged install collision was overwritten")
    print("PASS offline bundled source/runtime extraction, both b11583 CLIs, reuse and collision protection")
}
