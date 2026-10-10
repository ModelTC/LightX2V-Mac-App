import AppKit
import SwiftUI
import LightX2VCore
import UniformTypeIdentifiers

@main
struct AppStateChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        if CommandLine.arguments.dropFirst().first == "--real" {
            try await realInferenceChecks(Array(CommandLine.arguments.dropFirst(2)))
            return
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("app-state-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
        let workspace = root.appendingPathComponent("workspace")
        let layout = WorkspaceLayout(workspace.path)
        try layout.prepare()
        var settings = AppSettings.defaults
        settings.workingDirectory = workspace.path
        settings.repository = root.appendingPathComponent("fake-source").path
        settings.python = "/usr/bin/false"
        try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: true), to: layout.state)
        try JSONFile.write(WorkspaceLocation(workingDirectory: workspace.path), to: support.appendingPathComponent("workspace_location.json"))
        let store = AppStore()
        func check(_ good: @autoclosure () -> Bool, _ message: String) throws {
            if !good() { throw AppError.message(message) }
            print("PASS \(message)")
        }
        func waitForImport() async throws {
            for _ in 0..<500 {
                if !store.isImportingImages { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw AppError.message("Import timed out")
        }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 160, bitsPerPixel: 32)!
        let original = root.appendingPathComponent("原图, 测试.png")
        try image.representation(using: .png, properties: [:])!.write(to: original)
        let preview = await LocalImagePreview.load(original.path, maximumDimension: 20)
        try check(preview?.size == NSSize(width: 20, height: 15), "background preview preserves aspect ratio and limits decode size")
        let missingPreview = await LocalImagePreview.load(root.appendingPathComponent("missing.png").path, maximumDimension: 180)
        try check(missingPreview == nil, "missing preview fails without blocking app state")
        try check(store.selectedModel == nil && !store.modelPreparationExpanded && !store.generationParametersExpanded, "launch requires model selection with folded inspector")
        store.addInputImages([original])
        try check(!store.isImportingImages && store.inputImages.isEmpty, "no model rejects attachment import")
        store.selectModel(.qwenImage21)
        // Invalid fixture source deliberately prevents starting a real environment check.
        store.errorMessage = nil
        try check(store.modelPreparationExpanded && store.generationParametersExpanded, "model selection opens preparation and parameters")
        try check(store.generationSize.automaticResolution == 1024 && store.width == nil && store.height == nil,
                  "first model selection defaults to automatic 1K without fixed dimensions")
        store.prompt = "编辑这张图"
        store.addInputImages([original])
        try check(store.isImportingImages && !store.canGenerate, "import immediately locks submission")
        store.newGeneration()
        try check(store.prompt == "编辑这张图", "new creation cannot discard a pending import")
        try await waitForImport()
        try check(store.inputImages.count == 1 && store.errorMessage == nil, "file import completes")
        let firstDraft = store.inputImages[0].path
        store.addInputImages([original]); try await waitForImport()
        try check(store.inputImages.count == 1, "repeat imports are deduplicated")
        let bad = root.appendingPathComponent("broken.png"); try Data("bad".utf8).write(to: bad)
        store.addInputImages([bad]); try await waitForImport()
        try check(store.inputImages.count == 1 && store.errorMessage != nil, "bad image preserves existing draft")
        store.errorMessage = nil
        let job = layout.outputs.appendingPathComponent("test-job")
        let saved = try InputImages.snapshot(store.inputImages, in: job)
        let request = try InferenceRequest(settings: settings, prompt: store.prompt, width: 1376, height: 768, seed: 42, output: job.appendingPathComponent("image.png").path, inputImages: saved)
        let generation = Generation(request: request)
        store.generations = [generation]; store.persist()
        store.newGeneration()
        try check(store.inputImages.isEmpty && store.prompt.isEmpty && !fm.fileExists(atPath: firstDraft), "new creation removes only draft files")
        store.reuse(generation)
        try check(store.inputImages == saved && store.prompt == request.prompt && store.width == 1376, "reuse restores reference images, prompt and dimensions")
        let automatic = try InferenceRequest(settings: settings, prompt: "auto", width: nil, height: nil, seed: 43,
                                               output: request.output, inputImages: saved, resolution: 2048)
        store.reuse(Generation(request: automatic))
        try check(store.generationSize.aspectRatio == nil && store.generationSize.resolution == .twoK && store.width == nil && store.height == nil && store.inputImages == saved,
                  "reuse restores automatic 2K with reference images and no fixed dimensions")
        store.newGeneration()
        try check(store.generationSize.aspectRatio == nil && store.generationSize.automaticResolution == 1024,
                  "new creation resets size selection to automatic 1K")
        store.reuse(generation)
        store.removeInputImage(store.inputImages[0])
        try check(store.inputImages.isEmpty && fm.fileExists(atPath: saved[0].path), "removing reused input never deletes history snapshot")
        let provider = NSItemProvider(object: original as NSURL)
        try check(store.receiveImageDrop([provider]) && store.isImportingImages, "card drop locks before asynchronous URL loading")
        try await waitForImport()
        try check(store.inputImages.count == 1, "card drop reaches common image importer")
        store.clearInputImages()
        let failure = NSItemProvider()
        failure.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(nil, AppError.message("fixture failure")); return nil
        }
        try check(store.receiveImageDrop([provider, failure]), "mixed provider batch is received")
        try await waitForImport()
        try check(store.inputImages.isEmpty && store.errorMessage != nil, "provider error is atomic and visible")
        store.errorMessage = nil
        store.addInputImages([original]); try await waitForImport()
        let exitDraft = store.inputImages[0].path
        var exitCompleted = false
        store.prepareToTerminate { exitCompleted = true }
        try check(exitCompleted && !fm.fileExists(atPath: exitDraft) && fm.fileExists(atPath: saved[0].path), "termination cleans draft and preserves history")
        let reopened = AppStore()
        try check(reopened.selectedModel == nil && reopened.inputImages.isEmpty && reopened.generations[0].request.inputImages == saved, "relaunch keeps references in history and starts with empty draft/model")
        try check(reopened.generationSize.automaticResolution == 1024 && reopened.width == nil && reopened.height == nil,
                  "relaunch defaults to automatic 1K regardless of history")
        try check(reopened.generations[0].status == .interrupted, "relaunch recovers interrupted image task")
        // A launch failure must not discard the user's prompt or attached files.
        let source = root.appendingPathComponent("fake-source/lightx2v")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("infer.py"))
        let model = root.appendingPathComponent("model")
        try fm.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: model.appendingPathComponent("model_index.json"))
        let config = root.appendingPathComponent("config.json"); try Data("{}".utf8).write(to: config)
        let invalidExecutable = root.appendingPathComponent("invalid-python")
        try Data("this is not an executable".utf8).write(to: invalidExecutable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: invalidExecutable.path)
        store.settings.model = model.path; store.modelDirectory = model.path
        store.settings.config = config.path; store.modelConfig = config.path
        store.settings.python = invalidExecutable.path; store.environmentReady = true
        store.prompt = "keep this draft"
        store.addInputImages([original]); try await waitForImport()
        store.generate()
        try check(!store.isRunning && store.prompt == "keep this draft" && store.inputImages.count == 1,
                  "process launch failure preserves prompt and images")
        try check(store.generations[0].status == .failed && store.errorMessage != nil, "failed launch has a visible history record")
        store.clearInputImages()
        try await creationChecks()
        print("App state checks passed")
    }
}
