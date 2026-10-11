import AppKit
import LightX2VCore

@MainActor
func enhancementStateChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("pe-state-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    func file(_ name: String, text: String = "fixture", executable: Bool = false) throws -> String {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url.path
    }
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw AppError.message(message) }
        print("PASS \(message)")
    }
    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if !predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("Enhancement state fixture timed out")
    }
    let script = """
    #!/usr/bin/env python3
    import json, shutil, sys, time
    from pathlib import Path
    def emit(kind, **fields): print(json.dumps(dict(type=kind,**fields)),flush=True)
    if sys.argv[-2]=='check':
        emit('check',ok=True,message='fixture ready'); sys.exit(0)
    request=json.load(open(sys.argv[-1])); source=request['prompt']
    if request.get('promptEnhancement'):
        emit('enhancement_phase',phase='thinking',mode='i2i' if request.get('inputImages') else 't2i')
        emit('enhancement_thinking',delta='思考 🐈'); time.sleep(.1)
        if source=='STOP_ENHANCEMENT': time.sleep(60)
        if source=='FAIL_ENHANCEMENT':
            emit('done',status='failed',message='fixture enhancement failed'); sys.exit(1)
        emit('enhancement_phase',phase='rewriting'); time.sleep(.1)
        emit('enhancement_result',prompt='Enhanced '+source,whRatio='3:2',ratioFollow='',duration=.2)
        time.sleep(.2)
    shutil.copyfile(Path(__file__).with_name('fixture.png'),request['output'])
    emit('done',status='completed',duration=.4)
    """
    let python = try file("fixture-python", text: script, executable: true)
    _ = try file("source/lightx2v/infer.py")
    _ = try file("model/model_index.json", text: "{}")
    let config = try file("config.json", text: "{}")
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
    try image.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("fixture.png"))
    var settings = AppSettings(repository: root.appendingPathComponent("source").path, model: root.appendingPathComponent("model").path, config: config, python: python, workingDirectory: root.appendingPathComponent("workspace").path)
    settings.promptEnhancement.runtimeDirectory = root.appendingPathComponent("bin").path
    _ = try file("bin/llama-completion", executable: true)
    _ = try file("bin/llama-mtmd-cli", executable: true)
    settings.promptEnhancement.t2iModel = try file("t2i.gguf")
    settings.promptEnhancement.t2iSystemPrompt = try file("t2i.txt")
    settings.promptEnhancement.i2iModel = try file("i2i.gguf")
    settings.promptEnhancement.i2iSystemPrompt = try file("i2i.txt")
    settings.promptEnhancement.visionProjector = try file("mmproj.gguf")
    let support = root.appendingPathComponent("support")
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    let layout = WorkspaceLayout(settings.workingDirectory); try layout.prepare()
    try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: true), to: layout.state)
    try JSONFile.write(WorkspaceLocation(workingDirectory: settings.workingDirectory), to: support.appendingPathComponent("workspace_location.json"))
    let store = AppStore(); store.selectModel(.qwenImage21)
    try await wait({ store.isChecking }); store.environmentReady = true
    store.setPromptEnhancementEnabled(true)
    try await wait({ !store.enhancementResourcesReady })
    try check(store.settings.promptEnhancement.enabled && store.enhancementResourcesReady, "enhancement switch persists and detects text resources")
    store.prompt = "Original input"; store.generate()
    try check(store.isRunning && store.prompt.isEmpty && store.selected?.enhancement?.mode == .t2i, "text submission starts enhancement and clears only draft")
    try await wait({ store.selected?.enhancement?.prompt == nil && store.isRunning })
    let enhanced = store.selected!
    try check(enhanced.request.prompt == "Original input" && enhanced.enhancement?.prompt == "Enhanced Original input" && enhanced.enhancement?.thinking == "思考 🐈" && enhanced.status == .running,
              "first reply finishes with original prompt intact before second image reply")
    store.setPromptEnhancementEnabled(false)
    try check(store.settings.promptEnhancement.enabled, "enhancement cannot change midway through a run")
    try await wait({ store.isRunning })
    let first = store.generations[0]
    store.reference(first); store.reference(first)
    try await wait({ store.isImportingImages })
    store.prompt = "Reference input"; store.generate()
    try check(store.selected?.enhancement?.mode == .i2i && store.selected?.request.inputImages.count == 2 && store.enhancementMode == .i2i, "reference enhancement accepts ordered duplicate images and keeps its mode after draft clears")
    try await wait({ store.isRunning })
    try check(store.recentCreations.count == 1 && store.selectedCreation.count == 2, "both enhanced turns remain in the same creation")
    let reopened = AppStore(); reopened.selectedID = first.id
    try check(reopened.settings.promptEnhancement.enabled && reopened.selected?.enhancement?.thinking == "思考 🐈" && reopened.selected?.enhancement?.prompt == "Enhanced Original input", "relaunch restores enhancement switch, thinking and final reply")
    try check(reopened.selectedModel == nil && !reopened.canReferenceImages, "enhancement does not bypass manual model selection")
    store.prompt = "FAIL_ENHANCEMENT"; store.generate(); try await wait({ store.isRunning })
    try check(store.selected?.status == .failed && store.selected?.enhancement?.status == .failed && !fm.fileExists(atPath: store.selected!.request.output), "enhancement failure has no image or silent fallback")
    store.prompt = "STOP_ENHANCEMENT"; store.generate()
    try await wait({ store.selected.map { store.thinkingStream(for: $0).text.isEmpty } == true })
    store.stop(); try await wait({ store.isRunning })
    try check(store.selected?.status == .cancelled && store.selected?.enhancement?.status == .cancelled && store.selected?.enhancement?.thinking == "思考 🐈", "stop during thinking preserves partial reply and cancels image generation")
    store.setPromptEnhancementEnabled(false); store.prompt = "Off input"; store.generate(); try await wait({ store.isRunning })
    try check(store.selected?.status == .completed && store.selected?.enhancement == nil && store.selected?.request.promptEnhancement == nil, "switch off returns to the original generation flow")
    store.setPromptEnhancementEnabled(true)
    store.settings.promptEnhancement.t2iModel = "/missing/model.gguf"
    store.prompt = "Keep draft"; let count = store.generations.count; store.generate()
    try check(store.showEnhancementSettings && !store.isRunning && store.prompt == "Keep draft" && store.generations.count == count, "missing resources opens configuration and preserves unsubmitted draft")
}
