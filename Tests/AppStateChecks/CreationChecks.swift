import AppKit
import LightX2VCore

/// Exercises real AppStore submission/persistence using a fast fixture process,
/// so conversation routing does not depend on GPU inference or user settings.
@MainActor
func creationChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("creation-check-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let support = root.appendingPathComponent("support")
    let workspace = root.appendingPathComponent("workspace")
    let source = root.appendingPathComponent("source")
    let model = root.appendingPathComponent("model")
    let config = root.appendingPathComponent("config.json")
    let executable = root.appendingPathComponent("fixture-python")
    let outputFixture = root.appendingPathComponent("fixture.png")
    func png(_ width: Int, at url: URL) throws {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 32,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        image.bitmapData!.initialize(repeating: 0, count: width * 32 * 4)
        image.bitmapData![0] = 255; image.bitmapData![3] = 255
        try image.representation(using: .png, properties: [:])!.write(to: url)
    }
    func check(_ good: @autoclosure () -> Bool, _ message: String) throws {
        guard good() else { throw AppError.message(message) }
        print("PASS \(message)")
    }
    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if !predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("Creation fixture timed out")
    }
    let layout = WorkspaceLayout(workspace.path)
    try layout.prepare()
    try png(64, at: outputFixture)
    try png(66, at: root.appendingPathComponent("fixture-second.png"))
    let settings = AppSettings(repository: source.path, model: model.path, config: config.path,
                               python: executable.path, workingDirectory: workspace.path)
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: true), to: layout.state)
    try JSONFile.write(WorkspaceLocation(workingDirectory: workspace.path), to: support.appendingPathComponent("workspace_location.json"))
    let store = AppStore()
    store.selectModel(.qwenImage21) // Incomplete source prevents a real environment check.
    try fm.createDirectory(at: source.appendingPathComponent("lightx2v"), withIntermediateDirectories: true)
    try fm.createDirectory(at: model, withIntermediateDirectories: true)
    try Data().write(to: source.appendingPathComponent("lightx2v/infer.py"))
    try Data("{}".utf8).write(to: model.appendingPathComponent("model_index.json"))
    try Data("{}".utf8).write(to: config)
    let script = """
    #!/usr/bin/env python3
    import json, shutil, sys
    from pathlib import Path
    request = json.load(open(sys.argv[-1]))
    fixture = "fixture-second.png" if request["prompt"] == "Independent second scene" else "fixture.png"
    shutil.copyfile(Path(__file__).with_name(fixture), request["output"])
    print(json.dumps({"type":"done", "status":"completed", "duration":0.1}), flush=True)
    """
    try Data(script.utf8).write(to: executable)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    store.environmentReady = true; store.errorMessage = nil
    func submit(_ prompt: String) async throws -> Generation {
        store.prompt = prompt
        store.generate()
        try check(store.isRunning && store.prompt.isEmpty && store.inputImages.isEmpty, "submission clears only the submitted draft")
        try await wait({ store.isRunning })
        let job = store.generations[0]
        try check(job.status == .completed, "fixture process completes normally: \(job.error ?? store.logs)")
        return job
    }
    let first = try await submit("First scene")
    let second = try await submit("Independent second scene")
    try check(first.creationID == second.creationID && store.recentCreations.count == 1,
              "ordinary second generation stays in the same creation and sidebar entry")
    try check(store.selectedCreation.map(\.id) == [first.id, second.id] && second.request.inputImages.isEmpty,
              "conversation retains both turns without inheriting previous inputs")
    let reference = root.appendingPathComponent("external.png")
    try png(48, at: reference)
    store.addInputImages([reference]); try await wait({ store.isImportingImages })
    store.prompt = "My new reference prompt"
    store.generationSize.selectResolution(.twoK)
    store.generationSize.selectAspectRatio(.portrait916)
    let selected = store.selectedID
    store.reference(first)
    try check(store.isImportingImages && !store.canGenerate, "referencing locks submission during asynchronous import")
    try await wait({ store.isImportingImages })
    try check(store.inputImages.count == 2 && store.inputImages[1].path != first.request.output,
              "reference appends an independent draft copy of the output")
    try check(store.prompt == "My new reference prompt" && store.selectedID == selected && store.generations.count == 2,
              "reference preserves prompt, current conversation and history")
    try check(store.generationSize.resolution == .twoK && store.generationSize.aspectRatio == .portrait916,
              "reference preserves current size selection")
    store.reference(first); try await wait({ store.isImportingImages })
    try check(store.inputImages.count == 2, "repeated reference is deduplicated")
    store.removeInputImage(store.inputImages[1])
    store.reference(second); store.reference(first)
    try await wait({ store.isImportingImages })
    let widths = try store.inputImages.dropFirst().map {
        NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: $0.path)))!.pixelsWide
    }
    try check(widths == [66, 64] && store.prompt == "My new reference prompt" && store.selectedID == selected,
              "rapid multi-reference clicks append in click order without changing prompt or conversation")
    let third = try await submit("My new reference prompt")
    try check(third.creationID == first.creationID && third.request.inputImages.count == 3 && third.request.prompt != first.request.prompt,
              "referenced generation appends to the conversation with only the new prompt and selected images")
    let fourth = try await submit("Text only again")
    try check(fourth.creationID == first.creationID && fourth.request.inputImages.isEmpty && store.selectedCreation.count == 4,
              "normal generation after reference remains text-only in the same conversation")
    store.newGeneration()
    let fifth = try await submit("Explicitly new creation")
    try check(fifth.creationID != first.creationID && store.recentCreations.count == 2 && store.selectedCreation.count == 1,
              "only explicit New Creation starts a separate conversation")
    let reopened = AppStore()
    reopened.selectedID = first.id
    try check(reopened.recentCreations.count == 2 && reopened.selectedCreation.map(\.id) == [first.id, second.id, third.id, fourth.id],
              "relaunch restores conversation grouping and chronological turns")
    try check(reopened.creationTitle(fourth) == first.title, "creation title remains anchored to its first prompt")
    store.selectedID = first.id
    store.prompt = "Keep this draft"
    store.reference(first); try await wait({ store.isImportingImages })
    let draft = store.inputImages[0]
    store.removeInputImage(draft)
    try check(!fm.fileExists(atPath: draft.path) && fm.fileExists(atPath: first.request.output),
              "removing a referenced thumbnail preserves the generated output")
    var full: [URL] = []
    for index in 0..<InputImages.maximumCount {
        let file = root.appendingPathComponent("full-\(index).png")
        try png(48 + index, at: file); full.append(file)
    }
    store.addInputImages(full); try await wait({ store.isImportingImages })
    let before = store.inputImages
    store.reference(first); try await wait({ store.isImportingImages })
    try check(store.errorMessage != nil && store.inputImages == before && store.prompt == "Keep this draft" && store.selectedID == first.id,
              "full reference list reports the limit without changing the draft or conversation")
    store.errorMessage = nil
    var missing = first; missing.request.output = root.appendingPathComponent("missing.png").path
    store.reference(missing); try await wait({ store.isImportingImages })
    try check(store.errorMessage != nil && store.inputImages == before, "missing output fails atomically")
    store.clearInputImages()
    store.removeFromHistory(first)
    try check(store.generations.map(\.id) == [fifth.id] && fm.fileExists(atPath: first.request.output),
              "removing a creation removes all its history turns and preserves output files")
}
