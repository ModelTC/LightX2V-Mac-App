import Foundation
import LightX2VCore

private final class ModelDownloadUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var snapshots: [ModelDownloadProgress] = []
    func append(_ text: String) { lock.lock(); values.append(text); lock.unlock() }
    func append(_ progress: ModelDownloadProgress) { lock.lock(); snapshots.append(progress); lock.unlock() }
    var hasProgress: Bool { lock.lock(); defer { lock.unlock() }; return values.contains { $0.contains("25%") } }
    var hasBytesAndSpeed: Bool { lock.lock(); defer { lock.unlock() }; return snapshots.contains { $0.fileCountText == "8/32" && $0.percentage == "25%" && $0.bytesPerSecond == 2_500_000 } }
    var checked: Bool { lock.lock(); defer { lock.unlock() }; return snapshots.last?.stage == .checking }
}

extension SetupChecks {
    static func modelDownloadChecks(_ root: URL) async throws {
        let fm = FileManager.default
        let bin = root.appendingPathComponent("HF env 中文/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: python)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let previousHome = getenv("HF_HOME").map { String(cString: $0) }
        let terminalCache = root.appendingPathComponent("terminal-hf-cache")
        setenv("HF_HOME", terminalCache.path, 1)
        defer {
            if let previousHome { setenv("HF_HOME", previousHome, 1) } else { unsetenv("HF_HOME") }
        }
        let script = #"""
#!/usr/bin/python3
import json, os, pathlib, sys, time
args = sys.argv[1:]
assert args[0] == 'download' and args[2] == '--local-dir', args
path = pathlib.Path(args[3]); path.mkdir(parents=True, exist_ok=True)
(path / 'arguments.json').write_text(json.dumps(args))
assert pathlib.Path(os.environ['HF_HOME']).name == 'terminal-hf-cache', 'terminal HF cache was overridden'
assert os.environ['HF_HUB_DISABLE_PROGRESS_BARS'] == '0'
assert os.environ['TQDM_POSITION'] == '-1'
assert args[4:] == []
print('Fetching 32 files: 25%|██| 8/32 [00:01<00:03]', end='\r', flush=True)
print('Downloading bytes: | 10.0MB 2.50MB/s', end='\r', flush=True)
print('Reconstructing (incomplete total...): 50%|██| 250MB / 500MB 99MB/s', end='\r', flush=True)
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
print('Fetching 32 files: 100%|██| 32/32 [00:02<00:00]', flush=True)
"""#
        let hf = bin.appendingPathComponent("hf")
        try Data(script.utf8).write(to: hf); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hf.path)
        let workspace = WorkspaceLayout(root.appendingPathComponent("models space 中文 ' $(literal)").path)
        for resource in ModelResource.allCases {
            try expect(resource.relativeCommand == "hf download " + resource.repository + " --local-dir './models/" + resource.repository + "'", "guide command must be relative and include repository owner")
            try expect(resource.destination(in: workspace).path == workspace.root.path + "/models/" + resource.repository, "automatic download must include repository owner")
            let updates = ModelDownloadUpdates()
            let directory = try await ModelDownloader.download(resource, python: python.path, workspace: workspace, onProgress: { updates.append($0) }) { updates.append($0) }
            try expect(directory == resource.destination(in: workspace).path && updates.hasProgress && updates.hasBytesAndSpeed && updates.checked, "HF download lost local-dir, byte/speed progress or checking phase")
            let args = try JSONFile.read([String].self, from: URL(fileURLWithPath: directory + "/arguments.json"))
            try expect(args == ["download", resource.repository, "--local-dir", directory], "selected hf arguments must stay literal through the login shell")
        }
        let modelscope = bin.appendingPathComponent("modelscope")
        let msScript = script
            .replacingOccurrences(of: "assert args[0] == 'download' and args[2] == '--local-dir', args", with: "assert args[0] == 'download' and args[1] == '--model' and args[3] == '--local_dir', args")
            .replacingOccurrences(of: "pathlib.Path(args[3])", with: "pathlib.Path(args[4])")
            .replacingOccurrences(of: "assert os.environ['HF_HUB_DISABLE_PROGRESS_BARS'] == '0'", with: "assert os.environ['PYTHONUNBUFFERED'] == '1'")
            .replacingOccurrences(of: "assert args[4:] == []", with: "assert args[5:] == []")
            .replacingOccurrences(of: "repo = args[1]", with: "repo = args[2]")
            .replacingOccurrences(of: "Fetching 32 files:", with: "Downloading:")
            .replacingOccurrences(of: "Downloading bytes: | 10.0MB 2.50MB/s", with: "Downloading [weights.gguf]: 25%|██| 10.0MB/40.0MB [00:01<00:03, 2.50MB/s]")
            .replacingOccurrences(of: "print('network unavailable', flush=True); sys.exit(3)", with: "print('Failed to download weights.gguf: network unavailable', flush=True); sys.exit(0)")
        try Data(msScript.utf8).write(to: modelscope)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: modelscope.path)
        for resource in ModelResource.allCases {
            let expected = "modelscope download --model '" + resource.repository + "' --local_dir './models/" + resource.repository + "'"
            try expect(resource.relativeCommand(source: .modelScope) == expected, "ModelScope guide must match the supplied command")
            try expect(resource.url(source: .modelScope).absoluteString == "https://modelscope.cn/models/" + resource.repository, "ModelScope guide link points to the wrong source")
            let updates = ModelDownloadUpdates()
            let directory = try await ModelDownloader.download(resource, python: python.path, workspace: workspace, source: .modelScope, onProgress: { updates.append($0) }) { updates.append($0) }
            let args = try JSONFile.read([String].self, from: URL(fileURLWithPath: directory + "/arguments.json"))
            try expect(args == ["download", "--model", resource.repository, "--local_dir", directory] && updates.hasBytesAndSpeed && updates.checked, "ModelScope lost literal arguments, file counts, speed or final validation")
        }
        do {
            _ = try await ModelDownloader.download(.t2i, python: python.path, workspace: WorkspaceLayout(root.appendingPathComponent("ms-download-failure").path), source: .modelScope) { _ in }
            throw Failure(message: "ModelScope file failure with zero exit status was accepted")
        } catch let error as AppError {
            try expect(error.localizedDescription.contains("ModelScope download failed"), "ModelScope file failures must be reported even with zero exit status")
        }
        let msCancelled = WorkspaceLayout(root.appendingPathComponent("ms-download-cancel").path)
        let msUpdates = ModelDownloadUpdates()
        let msTask = Task { try await ModelDownloader.download(.t2i, python: python.path, workspace: msCancelled, source: .modelScope) { msUpdates.append($0) } }
        for _ in 0..<200 where !msUpdates.hasProgress { try await Task.sleep(for: .milliseconds(10)) }
        try expect(msUpdates.hasProgress, "ModelScope cancellation fixture did not launch")
        msTask.cancel()
        do { _ = try await msTask.value; throw Failure(message: "ModelScope cancellation ignored") } catch is CancellationError {} catch let error as Failure { throw error } catch {}
        _ = try await ModelDownloader.download(.t2i, python: python.path, workspace: msCancelled, source: .modelScope) { _ in }
        var savedSettings = AppSettings.defaults; savedSettings.modelDownloadSource = .modelScope
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(savedSettings))
        try expect(decoded.modelDownloadSource == .modelScope, "download source preference was not persisted")
        print("PASS ModelScope selected-environment CLI, all three commands, owner folders, progress, cancellation, retry and zero-exit file failures")
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
        do { _ = try await ModelDownloader.download(.t2i, python: python.path, workspace: failed) { _ in } } catch { rejected = true }
        try expect(rejected, "failed hf was accepted as a prepared model")
        let cancelled = WorkspaceLayout(root.appendingPathComponent("download-cancel").path)
        let updates = ModelDownloadUpdates()
        let task = Task { try await ModelDownloader.download(.t2i, python: python.path, workspace: cancelled) { updates.append($0) } }
        for _ in 0..<200 where !updates.hasProgress { try await Task.sleep(for: .milliseconds(10)) }
        try expect(updates.hasProgress, "HF cancellation fixture did not launch")
        task.cancel()
        var stopped = false
        do { _ = try await task.value } catch { stopped = true }
        try expect(stopped, "HF subprocess ignored cancellation")
        _ = try await ModelDownloader.download(.t2i, python: python.path, workspace: cancelled) { _ in }
        try rejects { _ = try ModelDownloader.executable(python: root.appendingPathComponent("missing/python").path) }
        let config = try QwenImage21Turbo.writeConfig(in: root.appendingPathComponent("case"))
        let cfg = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: config))) as! [String: Any]
        try expect(cfg["infer_steps"] as? Int == 8 && cfg["attn_type"] as? String == "torch_sdpa_mps", "APP config is not the validated eight-step MPS config")
        print("PASS selected-environment hf, terminal cache inheritance, literal shell arguments, three model folders, file-count progress, cancellation, retry and case config")
    }
}
