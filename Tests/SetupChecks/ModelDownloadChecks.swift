import Foundation
import LightX2VCore

private final class ModelDownloadUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ text: String) { lock.lock(); values.append(text); lock.unlock() }
    var hasProgress: Bool { lock.lock(); defer { lock.unlock() }; return values.contains { $0.contains("25%") } }
}

extension SetupChecks {
    static func modelDownloadChecks(_ root: URL) async throws {
        let fm = FileManager.default
        let bin = root.appendingPathComponent("HF env 中文/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let script = #"""
#!/usr/bin/python3
import json, os, pathlib, sys, time
args = sys.argv[1:]
assert args[0] == 'download' and args[2] == '--local-dir', args
path = pathlib.Path(args[3]); path.mkdir(parents=True, exist_ok=True)
(path / 'arguments.json').write_text(json.dumps(args))
assert os.environ['HF_HOME'].startswith(str(path.parents[1]))
print('Fetching files: 25%', end='\r', flush=True)
if 'failure' in str(path): print('network unavailable', flush=True); sys.exit(3)
if 'cancel' in str(path) and not (path / 'partial').exists():
    (path / 'partial').write_text('resume')
    time.sleep(20)
repo = args[1]
if repo.startswith('Qwen/'):
    (path / 'model_index.json').write_text('{}')
    for name in ['transformer','text_encoder','vae','scheduler','processor']: (path / name).mkdir(exist_ok=True)
else:
    mode = 'I2I' if 'I2I' in repo else 'T2I'
    (path / ('Qwen-Image-2.1-PE-' + mode + '-Q8_0.gguf')).write_text('weight')
    (path / 'system_prompt.txt').write_text('system')
    if mode == 'I2I': (path / 'mmproj-Qwen-Image-2.1-PE-I2I-BF16.gguf').write_text('projector')
print('Fetching files: 100%', flush=True)
"""#
        let hf = bin.appendingPathComponent("hf")
        try Data(script.utf8).write(to: hf); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hf.path)
        let workspace = WorkspaceLayout(root.appendingPathComponent("models space 中文 ' $(literal)").path)
        for resource in ModelResource.allCases {
            let updates = ModelDownloadUpdates()
            let directory = try await HuggingFaceModelDownloader.download(resource, python: python.path, workspace: workspace) { updates.append($0) }
            try expect(directory == resource.destination(in: workspace).path && updates.hasProgress, "HF download lost local-dir or carriage-return progress")
            let args = try JSONFile.read([String].self, from: URL(fileURLWithPath: directory + "/arguments.json"))
            try expect(args == ["download", resource.repository, "--local-dir", directory], "HF arguments were interpreted as shell code")
        }
        var pe = PromptEnhancementSettings()
        pe.t2iDirectory = ModelResource.t2i.destination(in: workspace).path
        pe.i2iDirectory = ModelResource.i2i.destination(in: workspace).path
        let files = try pe.resolvedResources()
        try expect(files.t2iSystemPrompt == pe.t2iDirectory + "/system_prompt.txt" && files.visionProjector.hasSuffix("BF16.gguf"), "PE repository folders did not resolve official files")
        try rejects { _ = try ModelResource.enhancementFiles(in: pe.i2iDirectory, mode: .t2i) }
        try fm.removeItem(atPath: pe.i2iDirectory + "/system_prompt.txt")
        _ = try pe.resolvedResources(for: .t2i)
        try rejects { _ = try pe.resolvedResources(for: .i2i) }
        let failed = WorkspaceLayout(root.appendingPathComponent("download-failure").path)
        var rejected = false
        do { _ = try await HuggingFaceModelDownloader.download(.t2i, python: python.path, workspace: failed) { _ in } } catch { rejected = true }
        try expect(rejected, "failed hf was accepted as a prepared model")
        let cancelled = WorkspaceLayout(root.appendingPathComponent("download-cancel").path)
        let updates = ModelDownloadUpdates()
        let task = Task { try await HuggingFaceModelDownloader.download(.t2i, python: python.path, workspace: cancelled) { updates.append($0) } }
        for _ in 0..<200 where !updates.hasProgress { try await Task.sleep(for: .milliseconds(10)) }
        try expect(updates.hasProgress, "HF cancellation fixture did not launch")
        task.cancel()
        var stopped = false
        do { _ = try await task.value } catch { stopped = true }
        try expect(stopped, "HF subprocess ignored cancellation")
        _ = try await HuggingFaceModelDownloader.download(.t2i, python: python.path, workspace: cancelled) { _ in }
        try rejects { _ = try HuggingFaceModelDownloader.executable(python: root.appendingPathComponent("missing/python").path) }
        let config = try QwenImage21Turbo.writeConfig(in: root.appendingPathComponent("case"))
        let cfg = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: config))) as! [String: Any]
        try expect(cfg["infer_steps"] as? Int == 8 && cfg["attn_type"] as? String == "torch_sdpa_mps", "APP config is not the validated eight-step MPS config")
        print("PASS HF arguments, three model folders, official PE file resolution, streaming progress, failure, cancellation, retry and bundled case config")
    }
}
