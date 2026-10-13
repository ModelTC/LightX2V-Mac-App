import AppKit
import LightX2VCore

@MainActor
func modelDownloadStateChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("model-transfer-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let layout = WorkspaceLayout(root.appendingPathComponent("workspace 中文").path)
    try layout.prepare()
    let bin = root.appendingPathComponent("bin")
    try fm.createDirectory(at: bin, withIntermediateDirectories: true)
    let python = bin.appendingPathComponent("python")
    try Data(#"""
#!/usr/bin/python3
import pathlib, sys
control = pathlib.Path(sys.argv[-1]).parents[2] / 'behavior'
if control.exists() and control.read_text() == 'unknown': sys.exit(1)
print('LIGHTX2V_DOWNLOAD_METADATA:{"totalBytes":1000000000,"revision":null}')
"""#.utf8).write(to: python)
    let hf = bin.appendingPathComponent("hf")
    try Data(#"""
#!/usr/bin/python3
import pathlib, sys, time
p = pathlib.Path(sys.argv[4]); p.mkdir(parents=True, exist_ok=True)
(p / 'partial').write_text('retained')
control = p.parents[2] / 'behavior'
behavior = control.read_text() if control.exists() else 'normal'
if behavior != 'unknown': print('Fetching 32 files: 25%|██| 8/32 [00:01]', end='\r', flush=True)
print('Downloading bytes: | 10.0MB 2.50MB/s', end='\r', flush=True)
print('Reconstructing (incomplete total...): 50%|██| 250MB / 500MB 99MB/s', end='\r', flush=True)
time.sleep(0.7 if behavior == 'normal' else 20 if behavior in ['cancel','unknown'] else 0.2)
if behavior == 'fail': print('network failure', flush=True); sys.exit(3)
if sys.argv[2].startswith('Qwen/'):
    (p / 'model_index.json').write_text('{}')
    for name in ['transformer','text_encoder','vae','scheduler','processor']: (p / name).mkdir(exist_ok=True)
else:
    mode = 'I2I' if 'I2I' in sys.argv[2] else 'T2I'
    (p / ('Qwen-Image-2.1-PE-' + mode + '-Q8_0.gguf')).write_text('weight')
    (p / 'system_prompt.txt').write_text('system')
    if mode == 'I2I': (p / 'mmproj-Qwen-Image-2.1-PE-I2I-BF16.gguf').write_text('projector')
print('Fetching 32 files: 100%|██| 32/32 [00:02]', flush=True)
"""#.utf8).write(to: hf)
    for executable in [python, hf] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path) }
    var settings = AppSettings.defaults
    settings.workingDirectory = layout.root.path; settings.python = python.path
    settings.repository = root.appendingPathComponent("source").path
    try fm.createDirectory(atPath: settings.repository + "/lightx2v", withIntermediateDirectories: true)
    try Data().write(to: URL(fileURLWithPath: settings.repository + "/lightx2v/infer.py"))
    settings.promptEnhancement.runtimeDirectory = try runtimeFixture(in: root)
    let support = root.appendingPathComponent("support")
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: true), to: layout.state)
    try JSONFile.write(WorkspaceLocation(workingDirectory: layout.root.path), to: support.appendingPathComponent("workspace_location.json"))
    let store = AppStore()
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw AppError.message(message) }; print("PASS " + message)
    }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw AppError.message("Model transfer fixture timed out")
    }
    let control = layout.root.appendingPathComponent("behavior")
    for resource in ModelResource.allCases {
        store.downloadModel(resource)
        try check(store.modelDownloadProgress[resource]?.stage == .preparing, resource.title + " immediately presents preparation state")
        try await wait { store.modelDownloadProgress[resource]?.percentage == "25%" }
        try check(store.modelDownloadProgress[resource]?.bytesPerSecond == 2_500_000 && store.activeModelDownload == resource,
                  resource.title + " publishes completed-file counts and actual network speed independently of disk speed")
        try await wait { !store.isPreparingResources }
        try check(store.modelDownloadProgress[resource] == nil && store.activeModelDownload == nil && !store.modelDownloadErrors.contains(resource)
                  && store.resourceDirectory(resource) == resource.destination(in: layout).path,
                  resource.title + " clears transfer state and saves its prepared directory")
    }
    try Data("cancel".utf8).write(to: control)
    store.downloadModel(.t2i)
    try await wait { store.modelDownloadProgress[.t2i]?.percentage == "25%" }
    store.setupTask?.cancel(); try await wait { !store.isPreparingResources }
    try check(store.modelDownloadProgress[.t2i] == nil && !store.modelDownloadErrors.contains(.t2i)
              && store.modelDownloadMessages[.t2i]?.contains("Stopped") == true
              && fm.fileExists(atPath: ModelResource.t2i.destination(in: layout).path + "/partial"), "stopping clears telemetry and retains downloaded files")
    try Data("normal".utf8).write(to: control)
    store.downloadModel(.t2i)
    try check(store.modelDownloadProgress[.t2i]?.completedBytes == 0 && store.modelDownloadProgress[.t2i]?.bytesPerSecond == nil,
              "retry begins a fresh session without stale percentage or speed")
    try await wait { !store.isPreparingResources }
    try check(!store.modelDownloadErrors.contains(.t2i), "retry succeeds after process-group cancellation")
    try Data("fail".utf8).write(to: control)
    store.downloadModel(.i2i); try await wait { !store.isPreparingResources }
    try check(store.modelDownloadErrors.contains(.i2i) && store.modelDownloadProgress[.i2i] == nil, "failed transfer restores the error icon without stale telemetry")
    try Data("unknown".utf8).write(to: control)
    store.downloadModel(.turbo)
    try await wait { store.modelDownloadProgress[.turbo]?.bytesPerSecond != nil }
    try check(store.modelDownloadProgress[.turbo]?.fraction == nil && store.modelDownloadProgress[.turbo]?.completedBytes == 250_000_000,
              "missing HF file counter preserves actual speed with an indeterminate bar")
    store.setupTask?.cancel(); try await wait { !store.isPreparingResources }
}
