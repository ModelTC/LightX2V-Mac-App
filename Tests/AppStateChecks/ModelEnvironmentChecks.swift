import AppKit
import Darwin
import LightX2VCore

@MainActor
func modelEnvironmentChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("model-environment-\(UUID().uuidString)")
    let layout = WorkspaceLayout(root.appendingPathComponent("workspace").path)
    try layout.prepare()
    let previousSupport = getenv("LIGHTX2V_APP_STATE_DIR").map { String(cString: $0) }
    let support = root.appendingPathComponent("support")
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    defer {
        if let previousSupport { setenv("LIGHTX2V_APP_STATE_DIR", previousSupport, 1) }
        else { unsetenv("LIGHTX2V_APP_STATE_DIR") }
        try? fm.removeItem(at: root)
    }
    let python = root.appendingPathComponent("fixture-python")
    let versions = root.appendingPathComponent("versions.json")
    let modelRan = root.appendingPathComponent("model-check-ran")
    let script = #"""
#!/usr/bin/python3
import json, os, sys, time
from pathlib import Path
root = Path(__file__).parent
if '-c' in sys.argv:
    if (root / 'slow-probe').exists():
        (root / 'probe.pid').write_text(str(os.getpid()))
        time.sleep(30)
    print('LIGHTX2V_ENV:' + (root / 'versions.json').read_text(), flush=True)
else:
    (root / 'model-check-ran').write_text('yes')
    if (root / 'fail-model').exists():
        print(json.dumps({'type':'error', 'message':'Fixture model import failed'}), flush=True)
        sys.exit(1)
    print(json.dumps({'type':'check', 'ok':True, 'message':'Fixture model ready'}), flush=True)
"""#
    try Data(script.utf8).write(to: python)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    var settings = AppSettings.defaults
    settings.workingDirectory = layout.root.path; settings.python = python.path
    settings.repository = root.appendingPathComponent("source").path
    settings.model = root.appendingPathComponent("model").path
    settings.config = root.appendingPathComponent("config.json").path
    try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: true), to: layout.state)
    try JSONFile.write(WorkspaceLocation(workingDirectory: layout.root.path), to: support.appendingPathComponent("workspace_location.json"))
    let store = AppStore()
    store.selectModel(.qwenImage21Turbo) // Source is absent, preventing an automatic check.
    let source = URL(fileURLWithPath: settings.repository).appendingPathComponent("lightx2v")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try Data().write(to: source.appendingPathComponent("infer.py"))
    try fm.createDirectory(atPath: settings.model, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: URL(fileURLWithPath: settings.model).appendingPathComponent("model_index.json"))
    try Data("{}".utf8).write(to: URL(fileURLWithPath: settings.config))
    var minimum: [String: Any] = ["python":"3.11.17", "architecture":"arm64", "mps":true, "detail":"MPS 可用"]
    for dependency in PyTorchRequirements.dependencies { minimum[dependency.name] = dependency.minimum }
    func check(_ good: @autoclosure () -> Bool, _ message: String) throws {
        guard good() else { throw AppError.message(message) }
        print("PASS \(message)")
    }
    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppError.message("Model environment fixture timed out")
    }
    func run(_ info: [String: Any], accepted: Bool) async throws {
        try JSONSerialization.data(withJSONObject: info).write(to: versions, options: .atomic)
        try? fm.removeItem(at: modelRan)
        let searched = try await PythonEnvironmentSearch.probe(python.path, workspace: layout)
        try check(searched.isCompatible == accepted, "search fixture has expected eligibility")
        store.checkEnvironment()
        try check(store.isChecking && !store.environmentReady && !store.canGenerate, "model check stays unavailable until both phases complete")
        try await waitUntil { !store.isChecking }
        try check(store.environmentReady == accepted, "model check matches search eligibility")
        try check(fm.fileExists(atPath: modelRan.path) == accepted, "incompatible environment cannot reach the model checker")
        if !accepted { try check(store.environmentMessage == searched.compatibilityDetail, "model check displays the same rejection as search") }
    }
    for (package, old) in [("torch", "2.14.0"), ("torchvision", "0.29.0"), ("torchaudio", "2.10.9"), ("transformers", "5.18.0")] {
        var info = minimum; info[package] = old
        try await run(info, accepted: false)
        info[package] = ""
        try await run(info, accepted: false)
        print("PASS outdated and missing \(package) rejected by both entry points")
    }
    var unavailable = minimum; unavailable["mps"] = false
    try await run(unavailable, accepted: false)
    unavailable = minimum; unavailable["architecture"] = "x86_64"
    try await run(unavailable, accepted: false)
    try await run(minimum, accepted: true)
    var newer = minimum
    newer["torch"] = "2.15.0"; newer["torchvision"] = "0.30.0"; newer["torchaudio"] = "2.12.0"; newer["transformers"] = "5.20.0"
    try await run(newer, accepted: true)
    try Data().write(to: root.appendingPathComponent("fail-model"))
    store.checkEnvironment()
    try await waitUntil { !store.isChecking }
    try check(!store.environmentReady && store.environmentMessage == "Fixture model import failed", "eligible dependencies still require a successful model check")
    try fm.removeItem(at: root.appendingPathComponent("fail-model"))
    try Data().write(to: root.appendingPathComponent("slow-probe"))
    try? fm.removeItem(at: modelRan)
    store.checkEnvironment()
    let pidFile = root.appendingPathComponent("probe.pid")
    try await waitUntil { fm.fileExists(atPath: pidFile.path) }
    let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
    var terminated = false
    store.prepareToTerminate { terminated = true }
    try await waitUntil { terminated }
    try check(!store.isChecking && !store.environmentReady && store.setupTask == nil && kill(pid, 0) != 0,
              "termination cancels the shared probe and finishes app shutdown")
    try check(!fm.fileExists(atPath: modelRan.path), "cancelled probe cannot launch the model checker")
}
