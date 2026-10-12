import AppKit
import LightX2VCore

/// Optional two-case MPS verification. Source/weights/runtime are read-only;
/// all preferences, snapshots and outputs go into a new isolated result folder.
@MainActor
func modelPreparationRealChecks(_ args: [String]) async throws {
    guard args.count == 7 else { throw AppError.message("Expected source, Turbo, Python, runtime, PE-T2I, PE-I2I and NEW results") }
    let fm = FileManager.default; let root = URL(fileURLWithPath: args[6])
    guard !fm.fileExists(atPath: root.path) else { throw AppError.message("Real model preparation verification needs a NEW directory") }
    let layout = WorkspaceLayout(root.appendingPathComponent("workspace 中文").path)
    var settings = AppSettings(repository: args[0], model: "", config: "", python: args[2], workingDirectory: layout.root.path)
    settings.promptEnhancement.runtimeDirectory = args[3]
    try settings.validateGeneralPaths(); try layout.prepare()
    let support = root.appendingPathComponent("support")
    try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: true), to: layout.state)
    try JSONFile.write(WorkspaceLocation(workingDirectory: layout.root.path), to: support.appendingPathComponent("workspace_location.json"))
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    let store = AppStore()
    func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1200)
        while condition() {
            guard Date() < deadline else { store.stop(); throw AppError.message("Real model verification timed out: " + store.phase) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw AppError.message(message + ": " + (store.errorMessage ?? store.selected?.error ?? store.environmentMessage) + "\n" + store.logs.suffix(2500)) }
        print("PASS " + message); fflush(stdout)
    }
    store.start(); try await wait { store.isChecking }
    try check(store.environmentReady && store.selectedModel == nil, "real startup verifies environment and keeps model selection empty")
    store.selectModel(.qwenImage21Turbo); store.modelDirectory = args[1]
    store.t2iDirectory = args[4]; store.i2iDirectory = args[5]
    try await wait { !store.enhancementResourcesReady }
    try check(store.settings.config.isEmpty, "automatic persistence resolves all real model folders without a user config")
    var report: [[String: Any]] = []
    for mode in ["t2i", "i2i"] {
        if mode == "i2i" {
            store.addInputImages([URL(fileURLWithPath: store.generations[0].request.output)])
            try await wait { store.isImportingImages }
        }
        store.prompt = mode == "t2i" ? "一只橘猫坐在窗边，柔和自然光，画面简洁。" : "将参考图中的猫改为白色，保持构图和光线。"
        print("START real " + mode + " with Prompt enhancement"); fflush(stdout)
        store.generate(); try check(store.isRunning, mode + " submitted")
        try await wait { store.isRunning }
        let job = store.generations[0]
        try check(job.status == .completed && job.enhancement?.status == .completed, mode + " enhancement and image inference completed")
        try check(job.request.config == job.directory + "/config.json", mode + " uses case-local config")
        let cfg = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: job.request.config))) as! [String: Any]
        try check(cfg["infer_steps"] as? Int == 8 && cfg["do_time_shift"] as? Bool == false, mode + " retains the Turbo schedule")
        let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: job.request.output)))
        try check(image != nil && !(job.enhancement?.prompt?.isEmpty ?? true), mode + " stores a readable image and enhanced prompt")
        report.append(["mode": mode, "config": job.request.config, "image": job.request.output, "duration": job.duration ?? 0,
                       "peModel": mode == "t2i" ? job.request.promptEnhancement!.t2iModel : job.request.promptEnhancement!.i2iModel])
    }
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("verification.json"))
}
