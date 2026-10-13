import AppKit
import Darwin
import SwiftUI
import LightX2VCore

@MainActor
func startupEnvironmentChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("startup-environment-\(UUID().uuidString)")
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
    let countFile = root.appendingPathComponent("probe-count")
    let script = #"""
#!/usr/bin/python3
import os, sys, time
from pathlib import Path
root = Path(__file__).parent
if '-c' not in sys.argv:
    (root / 'model-check-ran').write_text('unexpected inference import')
    sys.exit(1)
with (root / 'probe-count').open('a') as count: count.write('probe\n')
if (root / 'slow-probe').exists():
    (root / 'probe.pid').write_text(str(os.getpid()))
    time.sleep(30)
print('LIGHTX2V_ENV:' + (root / 'versions.json').read_text(), flush=True)
"""#
    try Data(script.utf8).write(to: python)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    var settings = AppSettings.defaults
    settings.workingDirectory = layout.root.path; settings.python = python.path
    settings.repository = root.appendingPathComponent("source").path
    settings.promptEnhancement.enabled = false
    settings.promptEnhancement.runtimeDirectory = try runtimeFixture(in: root)
    let source = URL(fileURLWithPath: settings.repository).appendingPathComponent("lightx2v")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("raise RuntimeError('Startup must not import inference or services')\n".utf8).write(to: source.appendingPathComponent("infer.py"))
    func savedStore(_ value: AppSettings = settings) throws -> AppStore {
        try JSONFile.write(WorkspaceData(settings: value, hasCompletedGeneralSetup: true), to: layout.state)
        try JSONFile.write(WorkspaceLocation(workingDirectory: layout.root.path), to: support.appendingPathComponent("workspace_location.json"))
        return AppStore()
    }
    var minimum: [String: Any] = ["python":"3.11.17", "architecture":"arm64", "mps":true, "detail":"MPS 可用"]
    for dependency in PyTorchRequirements.dependencies { minimum[dependency.name] = dependency.minimum ?? "0.0.1.dev1" }
    func check(_ good: @autoclosure () -> Bool, _ message: String) throws {
        guard good() else { throw AppError.message(message) }
        print("PASS \(message)")
    }
    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppError.message("Startup environment fixture timed out")
    }
    func write(_ info: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: info).write(to: versions, options: .atomic)
    }
    func count() -> Int { (try? String(contentsOf: countFile, encoding: .utf8).split(separator: "\n").count) ?? 0 }
    func snapshot<Content: View>(_ name: String, _ view: Content, size: NSSize) async throws {
        guard let destination = ProcessInfo.processInfo.environment["LIGHTX2V_SETUP_SNAPSHOTS"] else { return }
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        window.contentView = hosting; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
        }
    }

    var incomplete = settings; incomplete.python = ""
    let empty = try savedStore(incomplete)
    empty.start()
    try check(empty.needsGeneralSetup && empty.showStartupSettings && !empty.isChecking && count() == 0,
              "incomplete general settings open setup without starting a probe")
    try await snapshot("startup-incomplete", FirstLaunchSetupView().environmentObject(empty), size: NSSize(width: 900, height: 840))
    empty.closeGeneralSettings()
    try check(!empty.showStartupSettings && !empty.environmentReady && !empty.canGenerate,
              "closing incomplete setup allows the workspace but keeps generation unavailable")

    var missing = minimum; missing["loguru"] = ""
    try write(missing)
    let store = try savedStore()
    store.start()
    try check(store.isChecking && store.showStartupSettings && !store.environmentReady && store.selectedModel == nil,
              "complete settings automatically probe before model selection")
    try await waitUntil { !store.isChecking }
    try check(!store.environmentReady && store.environmentMessage == "Missing loguru" && store.showStartupSettings,
              "failed startup stays in general settings with the missing dependency")
    try await snapshot("startup-missing-dependency", FirstLaunchSetupView().environmentObject(store), size: NSSize(width: 900, height: 840))
    let initialCount = count()
    store.start()
    try check(!store.isChecking && count() == initialCount, "view reappearance does not repeat the startup check")
    store.closeGeneralSettings()
    store.selectModel(.qwenImage21Turbo)
    store.prompt = "Fixture prompt"
    try check(!store.showStartupSettings && !store.canGenerate && !store.environmentReady,
              "closing failed setup enters the workspace without marking the environment ready")
    try await snapshot("workspace-environment-unready", WorkspaceView().environmentObject(store), size: NSSize(width: 1150, height: 840))
    store.generate()
    try check(store.showSettings && !store.isRunning && !store.isChecking && count() == initialCount,
              "unready generation opens general settings without checking or loading a model")
    store.closeGeneralSettings()

    func run(_ info: [String: Any], accepted: Bool) async throws {
        try write(info)
        let searched = try await PythonEnvironmentSearch.probe(python.path, workspace: layout)
        try check(searched.isCompatible == accepted, "search fixture has expected eligibility")
        store.checkEnvironment()
        try check(store.isChecking && !store.environmentReady && !store.canGenerate, "environment check locks generation until the probe completes")
        try await waitUntil { !store.isChecking }
        try check(store.environmentReady == accepted && !fm.fileExists(atPath: modelRan.path),
                  "startup and search agree without invoking model imports")
        if !accepted { try check(store.environmentMessage == searched.compatibilityDetail, "general settings displays the same rejection as search") }
    }
    for (package, old) in [("torch", "2.14.0"), ("torchvision", "0.29.0"), ("torchaudio", "2.10.9"), ("transformers", "5.18.0"), ("diffusers", "0.40.0")] {
        var info = minimum; info[package] = old
        try await run(info, accepted: false)
        info[package] = ""
        try await run(info, accepted: false)
    }
    for dependency in PyTorchRequirements.dependencies where dependency.minimum == nil {
        var info = minimum; info[dependency.name] = ""
        try await run(info, accepted: false)
    }
    var unavailable = minimum; unavailable["mps"] = false
    try await run(unavailable, accepted: false)
    unavailable = minimum; unavailable["architecture"] = "x86_64"
    try await run(unavailable, accepted: false)
    try await run(minimum, accepted: true)
    let reopened = try savedStore()
    reopened.start()
    try await waitUntil { !reopened.isChecking }
    try check(reopened.environmentReady && !reopened.showStartupSettings && reopened.selectedModel == nil
              && reopened.settings.model.isEmpty && reopened.settings.config.isEmpty,
              "each relaunch checks dependencies and enters the workspace without model paths or selection")
    reopened.showSettings = true
    reopened.checkEnvironment()
    try await waitUntil { !reopened.isChecking }
    try check(reopened.environmentReady && reopened.showSettings && !reopened.showStartupSettings,
              "a successful manual environment check keeps the general settings sheet open")
    reopened.closeGeneralSettings()
    try check(!reopened.showSettings, "closing general settings dismisses the manually opened sheet")

    let beforeModel = count()
    reopened.selectModel(.qwenImage21Turbo)
    reopened.prompt = "Fixture prompt"
    try check(reopened.environmentReady && !reopened.canGenerate, "ready environment still requires prepared model paths before generation")
    settings.model = root.appendingPathComponent("model").path
    settings.config = root.appendingPathComponent("config.json").path
    try fm.createDirectory(atPath: settings.model, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: URL(fileURLWithPath: settings.model).appendingPathComponent("model_index.json"))
    for name in ["transformer", "text_encoder", "vae", "scheduler", "processor"] {
        try fm.createDirectory(atPath: settings.model + "/" + name, withIntermediateDirectories: true)
    }
    try Data("{}".utf8).write(to: URL(fileURLWithPath: settings.config))
    reopened.modelDirectory = settings.model
    try await waitUntil { reopened.readyModelResources.contains(.turbo) }
    try check(reopened.environmentReady && reopened.canGenerate && !reopened.isChecking && count() == beforeModel,
              "selecting and automatically saving model paths preserve the independent environment status without a check")
    try await snapshot("workspace-environment-ready", WorkspaceView().environmentObject(reopened), size: NSSize(width: 1150, height: 840))
    let beforeSave = count()
    reopened.showSettings = true
    try await reopened.applyGeneralSettings(reopened.settings)
    try check(!reopened.showSettings && reopened.environmentReady && !reopened.isChecking && count() == beforeSave,
              "saving an already verified Python environment preserves readiness without another probe")
    let secondPython = root.appendingPathComponent("fixture-python-2")
    try Data(script.utf8).write(to: secondPython)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secondPython.path)
    var changed = reopened.settings; changed.python = secondPython.path
    reopened.showSettings = true
    let saving = Task { try await reopened.applyGeneralSettings(changed) }
    try await waitUntil { reopened.isChecking }
    try check(reopened.showSettings && !reopened.environmentReady, "changed Python keeps settings open while saving checks dependencies")
    try await saving.value
    try check(!reopened.showSettings && !reopened.isChecking, "saving closes settings only after the new environment passes")
    try check(reopened.environmentReady && count() == beforeSave + 1, "saving a different Python environment performs one probe")
    missing = minimum; missing["pydantic"] = ""
    try write(missing)
    reopened.checkEnvironment()
    try await waitUntil { !reopened.isChecking }
    reopened.showSettings = true
    try await reopened.applyGeneralSettings(reopened.settings)
    try await waitUntil { !reopened.isChecking }
    try check(reopened.showSettings && !reopened.showStartupSettings && !reopened.environmentReady && reopened.environmentMessage == "Missing pydantic",
              "saving failed dependencies keeps settings open and the workspace unready")
    try write(minimum)
    reopened.showSettings = true
    try await reopened.applyGeneralSettings(reopened.settings)
    try await waitUntil { !reopened.isChecking }
    try check(!reopened.showSettings && !reopened.showStartupSettings && reopened.environmentReady,
              "saving valid settings dismisses the page and completes the dependency check")

    try write(missing)
    let retry = try savedStore()
    retry.start()
    try await waitUntil { !retry.isChecking }
    try check(retry.showStartupSettings && !retry.environmentReady, "failed startup presents general settings for repair")
    try write(minimum)
    retry.checkEnvironment()
    try await waitUntil { !retry.isChecking }
    try check(retry.showStartupSettings && retry.environmentReady,
              "manual recheck after repairing startup dependencies keeps the setup page open")
    try await snapshot("manual-check-ready-in-setup", FirstLaunchSetupView().environmentObject(retry), size: NSSize(width: 900, height: 840))
    retry.closeGeneralSettings()
    try check(!retry.showStartupSettings && retry.environmentReady, "closing repaired startup settings enters the workspace with a ready environment")

    // Losing the locator must not make an existing workspace impossible to reopen.
    var archivedSettings = settings
    archivedSettings.model = root.appendingPathComponent("saved model").path
    let output = layout.outputs.appendingPathComponent("saved.png")
    try Data([1, 2, 3]).write(to: output)
    var archivedJob = Generation(request: try InferenceRequest(settings: archivedSettings, prompt: "saved prompt", width: 1024, height: 1024, seed: 42, output: output.path))
    archivedJob.status = .completed
    try JSONFile.write(WorkspaceData(settings: archivedSettings, generations: [archivedJob], hasCompletedGeneralSetup: true), to: layout.state)
    let archivedBytes = try Data(contentsOf: layout.state)
    try fm.removeItem(at: support.appendingPathComponent("workspace_location.json"))
    let ignoredState = support.appendingPathComponent("workspace.json")
    let ignoredLocation = support.appendingPathComponent("location.json")
    try archivedBytes.write(to: ignoredState)
    let ignoredPointer = Data("invalid old location".utf8)
    try ignoredPointer.write(to: ignoredLocation)
    let countBeforeReset = count()
    let disconnected = AppStore()
    disconnected.start()
    try check(disconnected.showStartupSettings && disconnected.generations.isEmpty && disconnected.settings.workingDirectory.isEmpty && disconnected.settings.python.isEmpty && disconnected.errorMessage == nil && count() == countBeforeReset,
              "missing locator ignores old app-support state and starts empty setup without probing")
    disconnected.persist()
    let ignoredRetained = try Data(contentsOf: ignoredState)
    let pointerRetained = try Data(contentsOf: ignoredLocation)
    try check(ignoredRetained == archivedBytes && pointerRetained == ignoredPointer, "fresh setup does not write ignored old app-support files")
    try Data("invalid old workspace".utf8).write(to: ignoredState)
    let corruptOldState = AppStore()
    corruptOldState.start()
    try check(corruptOldState.needsGeneralSetup && corruptOldState.showStartupSettings && corruptOldState.errorMessage == nil && corruptOldState.generations.isEmpty,
              "corrupt old app-support state does not affect fresh startup")
    let preview = try disconnected.existingWorkspaceSettings(at: layout.root.path)
    try check(preview == archivedSettings, "selecting an existing workspace restores all configuration paths")
    var incompleteDraft = AppSettings.defaults
    incompleteDraft.workingDirectory = layout.root.path
    try await disconnected.applyGeneralSettings(incompleteDraft)
    var bundledSettings = archivedSettings
    BundledInferenceResources.configure(&bundledSettings)
    try check(disconnected.settings == bundledSettings && disconnected.generations.map(\.id) == [archivedJob.id], "saving selection reconnects settings and completed images")
    try check(disconnected.environmentReady && !disconnected.showStartupSettings, "reconnected workspace checks saved environment and enters the APP")
    let retainedBytes = try Data(contentsOf: layout.state)
    let retainedImage = try Data(contentsOf: output)
    try check(retainedBytes == archivedBytes && retainedImage == Data([1, 2, 3]), "reconnection preserves workspace JSON and output bytes")
    try await snapshot("workspace-reconnected", WorkspaceView().environmentObject(disconnected), size: NSSize(width: 1150, height: 840))
    let afterReconnect = AppStore()
    try check(afterReconnect.settings == bundledSettings && afterReconnect.generations.map(\.id) == [archivedJob.id], "relaunch follows restored locator and retains original history")

    let incompleteLayout = WorkspaceLayout(root.appendingPathComponent("incomplete saved workspace").path)
    try incompleteLayout.prepare()
    var incompleteSettings = AppSettings.defaults
    incompleteSettings.workingDirectory = incompleteLayout.root.path
    try JSONFile.write(WorkspaceData(settings: incompleteSettings, generations: [archivedJob]), to: incompleteLayout.state)
    let incompleteBytes = try Data(contentsOf: incompleteLayout.state)
    var selection = AppSettings.defaults; selection.workingDirectory = incompleteLayout.root.path
    afterReconnect.showSettings = true
    try await afterReconnect.applyGeneralSettings(selection)
    try check(afterReconnect.generations.map(\.id) == [archivedJob.id] && afterReconnect.needsGeneralSetup && afterReconnect.showSettings,
              "incomplete saved workspace restores history and stays in settings for repair")
    let incompleteRetained = try Data(contentsOf: incompleteLayout.state)
    try check(incompleteRetained == incompleteBytes, "incomplete workspace restoration preserves original bytes")

    try Data().write(to: root.appendingPathComponent("slow-probe"))
    let cancelled = try savedStore()
    cancelled.start()
    let pidFile = root.appendingPathComponent("probe.pid")
    try await waitUntil { fm.fileExists(atPath: pidFile.path) }
    let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
    cancelled.closeGeneralSettings()
    try await waitUntil { !cancelled.isChecking }
    try check(!cancelled.showStartupSettings && !cancelled.environmentReady && cancelled.setupTask == nil && kill(pid, 0) != 0,
              "closing a running startup check cancels the probe without enabling the environment")
    try fm.removeItem(at: pidFile)
    cancelled.checkEnvironment()
    try await waitUntil { fm.fileExists(atPath: pidFile.path) }
    let exitPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
    var terminated = false
    cancelled.prepareToTerminate { terminated = true }
    try await waitUntil { terminated }
    try check(!cancelled.isChecking && !cancelled.environmentReady && cancelled.setupTask == nil && kill(exitPID, 0) != 0,
              "termination cancels dependency probing and finishes app shutdown")
}
