import AppKit
import LightX2VCore

/// Optional manual integration: --real <source> <model> <python> <results> <image1> <image2>
/// Uses a new isolated workspace; never touches the user's App Support locator.
@MainActor
func realInferenceChecks(_ arguments: [String]) async throws {
    guard arguments.count == 6 else { throw AppError.message("Expected source, model, python, results, image1 and image2") }
    let root = URL(fileURLWithPath: arguments[3])
    let fm = FileManager.default
    guard !fm.fileExists(atPath: root.path) else { throw AppError.message("Choose a new test results folder") }
    let settings = AppSettings(repository: arguments[0], model: arguments[1],
                               config: arguments[0] + "/configs/platforms/mps/qwen_image_21_viggle_v03.json",
                               python: arguments[2], workingDirectory: root.appendingPathComponent("workspace, 中文").path)
    let support = root.appendingPathComponent("support")
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    let layout = WorkspaceLayout(settings.workingDirectory)
    try layout.prepare()
    try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: true), to: layout.state)
    try JSONFile.write(WorkspaceLocation(workingDirectory: settings.workingDirectory), to: support.appendingPathComponent("workspace_location.json"))
    let store = AppStore()
    func require(_ value: Bool, _ message: String) throws {
        guard value else { throw AppError.message(message + ": " + (store.errorMessage ?? store.environmentMessage)) }
        print("PASS \(message)"); fflush(stdout)
    }
    func wait(_ predicate: () -> Bool, seconds: Double = 600) async throws {
        let end = Date().addingTimeInterval(seconds)
        while predicate() {
            guard Date() < end else { store.stop(); throw AppError.message("real integration timed out") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    store.selectModel(.qwenImage21)
    try await wait({ store.isChecking }, seconds: 110)
    try require(store.environmentReady, "real MPS environment check")
    let files = arguments[4...5].map { URL(fileURLWithPath: $0) }
    store.addInputImages(files)
    try await wait({ store.isImportingImages })
    try require(store.inputImages.count == 2, "multi-image draft import")
    store.prompt = "Put the red circle from image 1 on the left and the blue square from image 2 on the right. Combine them on a plain light background."
    store.generationSize.selectAspectRatio(.landscape169)
    store.generate()
    try require(store.isRunning && store.prompt.isEmpty && store.inputImages.isEmpty, "submission starts and clears draft")
    try await wait({ store.isRunning })
    let completed = store.generations[0]
    try require(completed.status == .completed, "AppStore multi-image inference completed")
    let output = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: completed.request.output)))!
    try require(output.pixelsWide == 1376 && output.pixelsHigh == 768, "landscape dimensions and H/W mapping")
    try require(completed.request.inputImages.count == 2 && store.currentStep == 6, "input snapshots and all six progress events")
    store.reuse(completed)
    try require(store.inputImages == completed.request.inputImages, "completed history reuse restores inputs")
    store.generate()
    try require(store.isRunning, "reused task launches")
    try await wait({ store.currentStep == 0 && store.isRunning }, seconds: 90)
    store.stop()
    try await wait({ store.isRunning }, seconds: 20)
    try require(store.generations[0].status == .cancelled, "real inference cancellation")
    try require(store.generations[0].request.seed != completed.request.seed, "new generation receives a new random seed")
    store.reuse(completed)
    let first = store.inputImages[0]
    store.removeInputImage(first)
    store.removeInputImage(store.inputImages[0])
    try require(store.inputImages.isEmpty && fm.fileExists(atPath: first.path), "clearing references restores text-only mode without deleting history")
    store.persist()
    let reopened = AppStore()
    try require(reopened.selectedModel == nil && reopened.generations.count == 2 && reopened.generations[1].request.inputImages == completed.request.inputImages, "real completed and cancelled jobs survive relaunch")
    try JSONFile.write(["completed": completed.request.output, "state": layout.state.path], to: root.appendingPathComponent("verification.json"))
    print("Real AppStore inference checks passed")
}
