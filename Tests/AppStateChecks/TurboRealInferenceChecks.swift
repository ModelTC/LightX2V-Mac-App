import AppKit
import Combine
import LightX2VCore

/// Optional real MPS integration. All state, inputs and outputs use a NEW results
/// directory; the user's normal workspace and App Support locator are untouched.
/// --turbo-real <source> <Turbo weights> <python> <new results> <boat> <cat>
@MainActor
func turboRealInferenceChecks(_ arguments: [String]) async throws {
    guard arguments.count == 6 else { throw AppError.message("Expected source, Turbo weights, Python, new results directory, boat and cat") }
    let fm = FileManager.default
    let root = URL(fileURLWithPath: arguments[3])
    guard !fm.fileExists(atPath: root.path) else { throw AppError.message("Turbo integration needs a NEW results directory") }
    let layout = WorkspaceLayout(root.appendingPathComponent("workspace, 中文").path)
    let support = root.appendingPathComponent("support")
    var settings = AppSettings(repository: arguments[0], model: arguments[1],
                               config: arguments[0] + "/" + QwenImage21Turbo.configRelativePath,
                               python: arguments[2], workingDirectory: layout.root.path)
    settings.promptEnhancement.discover(near: [settings.model, settings.repository])
    try settings.promptEnhancement.validate(for: .t2i)
    try settings.promptEnhancement.validate(for: .i2i)
    settings.promptEnhancement.enabled = false
    try layout.prepare()
    try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: true), to: layout.state)
    try JSONFile.write(WorkspaceLocation(workingDirectory: layout.root.path), to: support.appendingPathComponent("workspace_location.json"))
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    let store = AppStore()
    func require(_ value: Bool, _ message: String) throws {
        guard value else { throw AppError.message(message + ": " + (store.selected?.error ?? store.errorMessage ?? store.environmentMessage) + "\n" + store.logs.suffix(3000)) }
        print("PASS \(message)"); fflush(stdout)
    }
    func wait(_ predicate: () -> Bool, seconds: Double = 1200) async throws {
        let end = Date().addingTimeInterval(seconds)
        while predicate() {
            guard Date() < end else { store.stop(); throw AppError.message("Turbo integration timed out: " + store.phase) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    func bitmap(_ path: String) throws -> NSBitmapImageRep {
        guard let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))) else {
            throw AppError.message("Unreadable result: " + path)
        }
        return image
    }
    func dimensions(resolution: Int, ratio: Double) -> (Int, Int) {
        let width = sqrt(Double(resolution * resolution) * ratio)
        return (max(32, Int((width / 32).rounded(.toNearestOrEven)) * 32),
                max(32, Int((width / ratio / 32).rounded(.toNearestOrEven)) * 32))
    }
    func expectedDimensions(_ job: Generation) throws -> (Int, Int) {
        if let width = job.request.width, let height = job.request.height { return (width, height) }
        let resolution = job.request.resolution!
        if let ratio = job.enhancement?.whRatio, !ratio.isEmpty {
            let parts = ratio.split(separator: ":").compactMap { Double($0) }
            try require(parts.count == 2, "enhancement ratio is numeric")
            return dimensions(resolution: resolution, ratio: parts[0] / parts[1])
        }
        var reference = job.request.inputImages.last
        if let follow = job.enhancement?.ratioFollow, !follow.isEmpty {
            let index = Int(follow.filter(\.isNumber))!
            reference = job.request.inputImages[index - 1]
        }
        if let reference {
            let image = try bitmap(reference.path)
            return dimensions(resolution: resolution, ratio: Double(image.pixelsWide) / Double(image.pixelsHigh))
        }
        return (resolution, resolution)
    }
    var report: [[String: Any]] = []
    func submit(_ name: String, prompt: String, resolution: ImageResolution = .oneK,
                ratio: ImageAspectRatio? = nil, images: [URL] = [], enhancement: Bool = false,
                useDraftReferences: Bool = false) async throws -> Generation {
        print("START \(name)"); fflush(stdout)
        store.setPromptEnhancementEnabled(enhancement)
        store.generationSize = GenerationSize()
        store.generationSize.selectResolution(resolution)
        store.generationSize.selectAspectRatio(ratio)
        if !useDraftReferences {
            store.clearInputImages()
            if !images.isEmpty { store.addInputImages(images); try await wait({ store.isImportingImages }) }
        }
        let inputCount = store.inputImages.count
        store.prompt = prompt
        var steps: [Int] = []
        let stepObserver = store.$currentStep.sink { if $0 > 0 { steps.append($0) } }
        store.generate()
        try require(store.isRunning && store.prompt.isEmpty && store.inputImages.isEmpty, name + " submits and clears draft")
        try await wait({ store.isRunning })
        stepObserver.cancel()
        let job = store.generations[0]
        try require(job.status == .completed, name + " completes")
        try require(Array(steps.suffix(8)) == Array(1...8), name + " reports all eight steps")
        let image = try bitmap(job.request.output)
        let expected = try expectedDimensions(job)
        try require((image.pixelsWide, image.pixelsHigh) == expected, name + " output is \(expected.0) × \(expected.1)")
        try require(job.request.inputImages.count == inputCount, name + " preserves reference count")
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: job.directory + "/config.json"))) as! [String: Any]
        try require(config["infer_steps"] as? Int == 8 && config["do_time_shift"] as? Bool == false,
                    name + " uses the Turbo schedule without time shifting")
        if enhancement {
            try require(job.enhancement?.status == .completed && !(job.enhancement?.thinking.isEmpty ?? true) && !(job.enhancement?.prompt?.isEmpty ?? true),
                        name + " persists real thinking and enhanced prompt")
            try require(store.promptStream(for: job).text == job.enhancement?.prompt, name + " reconciles streamed prompt")
        } else { try require(job.enhancement == nil, name + " skips enhancement") }
        try require(store.recentCreations.count == 1, name + " stays in the current creation")
        let row: [String: Any] = ["case": name, "image": job.request.output, "width": image.pixelsWide, "height": image.pixelsHigh,
                                  "steps": Array(steps.suffix(8)), "references": inputCount, "enhancement": enhancement,
                                  "duration": job.duration ?? 0, "creationID": job.creationID.uuidString]
        report.append(row)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: root.appendingPathComponent("verification.json"), options: .atomic)
        return job
    }
    try require(store.selectedModel == nil && store.generations.isEmpty, "fresh workspace starts without model or history")
    store.selectModel(.qwenImage21Turbo)
    try await wait({ store.isChecking }, seconds: 110)
    try require(store.environmentReady, "real Turbo dependency and MPS model check")
    let boat = URL(fileURLWithPath: arguments[4]), cat = URL(fileURLWithPath: arguments[5])
    let capybara = "A capybara wearing a wizard hat sits at a desk, reading a book by candlelight. Oil painting style, delicate brushwork, warm tones."
    let yacht = "Create a photorealistic photograph of the motor yacht from the input sketch, sailing on open sea, captured in full side profile with the camera at water level. Preserve the hull, mast, wheelhouse, windows, portholes, lifeboats, and railings from the sketch. Paint the hull black, the superstructures and mast white, and the funnel yellow. Place the entire yacht on a calm deep-blue sea under a clear sky with soft clouds, lit by sunlight from the front left."
    _ = try await submit("t2i-1k-adaptive", prompt: capybara)
    let boatJob = try await submit("i2i-1k-square", prompt: yacht, ratio: .square, images: [boat])
    _ = try await submit("i2i-multi-1k-landscape", prompt: "Create a cinematic photograph of the yacht in reference image 1 floating on the turquoise sea in reference image 2. Keep the yacht's proportions and include the animal from image 2 in the foreground, with warm natural sunlight.",
                         ratio: .landscape169, images: [boat, cat])
    _ = try await submit("t2i-2k-portrait", prompt: "An elegant editorial photograph of a glass house in a misty green forest, warm morning light, intricate moss and leaves, vertical architectural composition.",
                         resolution: .twoK, ratio: .portrait34)
    _ = try await submit("pe-t2i-1k-adaptive", prompt: "A quiet seaside cafe at sunrise, panoramic cinematic composition, soft golden light", enhancement: true)
    store.reference(boatJob); store.reference(boatJob)
    try await wait({ store.isImportingImages })
    try require(store.inputImages.count == 2 && store.prompt.isEmpty, "two identical history references append without restoring prompt")
    let bytes = try store.inputImages.map { try Data(contentsOf: URL(fileURLWithPath: $0.path)) }
    try require(bytes[0] == bytes[1] && store.inputImages[0].id != store.inputImages[1].id, "duplicate references retain independent identities")
    _ = try await submit("pe-i2i-1k-duplicate-references", prompt: "Show the same yacht in these two references at sunset on calm sea. Keep its structure and paint colors, with warm reflections and soft orange clouds.",
                         enhancement: true, useDraftReferences: true)
    _ = try await submit("i2i-2k-adaptive", prompt: "Transform the cat in the reference image into a photorealistic cream-colored dog with a natural canine muzzle, nose, and ears. Preserve the original close-up selfie composition, head position, body pose, and extended front leg. Keep the amber sunglasses and their reflections, fitting them naturally to the dog's face, and retain the collar and wet fur appearance. Preserve the turquoise water, yellow kayak, distant beach, cliffs, vegetation, and sky. Match the original sunlight, warm backlighting, shadows, shallow depth of field, and perspective. Change only the animal's species, with realistic canine anatomy and detailed fur that blends seamlessly into the scene.",
                         resolution: .twoK, images: [cat])
    store.prompt = "A blue ceramic cup on a wooden table"; store.generate()
    try require(store.isRunning, "cancellation case starts")
    try await wait({ store.isRunning && store.currentStep < 1 }, seconds: 180)
    store.stop()
    try await wait({ store.isRunning }, seconds: 20)
    try require(store.generations[0].status == .cancelled, "stop terminates real Turbo denoising")
    try require(!fm.fileExists(atPath: store.generations[0].request.output), "cancelled run has no completed image")
    store.persist()
    let reopened = AppStore()
    try require(reopened.selectedModel == nil && !reopened.canReferenceImages && !reopened.modelPreparationExpanded,
                "relaunch still requires model selection")
    try require(reopened.generations.count == 8 && reopened.generations.filter { $0.status == .completed }.count == 7 && reopened.recentCreations.count == 1,
                "all seven completed runs and one cancellation survive relaunch in the same creation")
    try require(Set(reopened.generations.map { $0.request.seed }).count == 8, "each real generation uses a different random seed")
    let refs = reopened.generations.first { $0.enhancement?.mode == .i2i }!.request.inputImages
    try require(refs.count == 2 && refs[0].id != refs[1].id, "relaunch preserves duplicate reference snapshots")
    print("All real Turbo cases passed. Results: \(root.path)"); fflush(stdout)
}
