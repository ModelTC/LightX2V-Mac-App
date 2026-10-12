import AppKit
import SwiftUI
import LightX2VCore

@MainActor
func generationLogChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("generation-logs-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    func file(_ name: String, _ text: String = "", executable: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }
    func check(_ good: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try good() else { throw AppError.message(message) }
        print("PASS \(message)")
    }
    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<800 {
            if !predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("Generation log fixture timed out")
    }
    let script = """
    #!/usr/bin/env python3
    import json, shutil, sys, time
    from pathlib import Path
    def emit(kind, **fields): print(json.dumps(dict(type=kind, **fields)), flush=True)
    request = json.load(open(sys.argv[-1])); name = request['prompt']
    emit('log', message='LOG_START_' + name)
    if name == 'EARLY_FAILURE':
        emit('done', status='failed', message='Failed before inference started'); sys.exit(1)
    if name == 'UNEXPECTED_EXIT':
        print('Native stderr diagnostic', file=sys.stderr, flush=True); sys.exit(7)
    if name == 'LIVE':
        for index in range(100):
            emit('log', message='LIVE_' + str(index)); time.sleep(.03)
    if name == 'STOP':
        time.sleep(60)
    if name == 'LONG':
        emit('log', message='FULL_LOG_BEGIN\\n' + '日志 🐈\\n' * 20000 + 'FULL_LOG_END')
    shutil.copyfile(Path(__file__).with_name('fixture.png'), request['output'])
    emit('done', status='completed', duration=.1)
    """
    let python = try file("fixture-python", script, executable: true)
    _ = try file("source/lightx2v/infer.py")
    _ = try file("model/model_index.json", "{}")
    for name in ["transformer", "text_encoder", "vae", "scheduler", "processor"] {
        try fm.createDirectory(at: root.appendingPathComponent("model/" + name), withIntermediateDirectories: true)
    }
    let config = try file("config.json", "{}")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
    bitmap.bitmapData!.initialize(repeating: 127, count: 32 * 32 * 4)
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("fixture.png"))
    let support = root.appendingPathComponent("support")
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    let layout = WorkspaceLayout(root.appendingPathComponent("workspace").path); try layout.prepare()
    var settings = AppSettings(repository: root.appendingPathComponent("source").path,
                               model: root.appendingPathComponent("model").path,
                               config: config.path, python: python.path, workingDirectory: layout.root.path)
    settings.promptEnhancement.enabled = false
    settings.promptEnhancement.runtimeDirectory = try runtimeFixture(in: root)
    try JSONFile.write(WorkspaceData(settings: settings, hasCompletedGeneralSetup: true), to: layout.state)
    try JSONFile.write(WorkspaceLocation(workingDirectory: layout.root.path), to: support.appendingPathComponent("workspace_location.json"))
    let store = AppStore(); store.selectModel(.qwenImage21Turbo)
    try await wait({ store.isChecking }); store.environmentReady = true
    func submit(_ prompt: String) async throws -> Generation {
        store.prompt = prompt; store.generate()
        try check(store.isRunning, "log fixture submits \(prompt)")
        try await wait({ store.isRunning })
        return store.generations[0]
    }
    func completeLog(_ job: Generation) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: job.directory).appendingPathComponent("run.log"), encoding: .utf8)
    }
    let first = try await submit("FIRST")
    let firstLog = try completeLog(first)
    let second = try await submit("SECOND")
    let secondLog = try completeLog(second)
    try check(first.creationID == second.creationID && first.directory != second.directory
              && firstLog.contains("LOG_START_FIRST") && secondLog.contains("LOG_START_SECOND")
              && !firstLog.contains("LOG_START_SECOND") && !secondLog.contains("LOG_START_FIRST"),
              "continuous turns retain independent complete log files")
    store.prompt = "Keep this draft"
    store.generationSize.selectResolution(.twoK)
    store.openLog(for: first)
    try await wait({ store.logs == "正在读取日志…" })
    try check(store.showLogs && store.logGeneration?.id == first.id && store.selectedID == second.id
              && store.logs == firstLog && store.prompt == "Keep this draft" && store.generationSize.resolution == .twoK,
              "opening an earlier turn reads its own log without changing conversation or draft")
    store.selectLog(second.id)
    try await wait({ store.logs == "正在读取日志…" })
    try check(store.logs == secondLog, "task selector switches between logs in the same conversation")

    store.prompt = "LIVE"; store.generate()
    let live = store.generations[0]
    try await wait({ !store.logs.contains("LIVE_0") })
    store.openLog(for: first)
    try await wait({ store.logs == "正在读取日志…" })
    let historicalLog = store.logs
    try await Task.sleep(for: .milliseconds(200))
    try check(store.isRunning && store.logs == historicalLog && store.logGenerationID == first.id,
              "new live output cannot overwrite the earlier turn being inspected")
    store.selectLog(live.id)
    try await wait({ !store.logs.contains("LIVE_5") })
    try check(store.logGenerationID == live.id && store.logs.contains("LOG_START_LIVE") && !store.logs.contains("LOG_START_FIRST"),
              "returning to the active turn restores its accumulated live log")
    try await wait({ store.isRunning })
    try check(try completeLog(live).contains("LIVE_99"), "live log remains complete after task exit")

    let failed = try await submit("EARLY_FAILURE")
    try check(failed.status == .failed && (try completeLog(failed)).contains("Failed before inference started")
              && !fm.fileExists(atPath: failed.directory + "/inference.log"),
              "failure before inference still has a persistent task log")
    let exited = try await submit("UNEXPECTED_EXIT")
    let exitLog = try completeLog(exited)
    try check(exited.status == .failed && exitLog.contains("Native stderr diagnostic") && exitLog.contains("7"),
              "unexpected process exit retains stderr and the failure reason")
    store.prompt = "STOP"; store.generate()
    let stopped = store.generations[0]
    try await wait({ !store.logs.contains("LOG_START_STOP") })
    store.stop(); try await wait({ store.isRunning })
    try check(store.generations[0].status == .cancelled && (try completeLog(stopped)).contains("生成已停止"),
              "stopping a task flushes its log and cancellation reason")
    let long = try await submit("LONG")
    let full = try completeLog(long)
    try check(full.utf8.count > GenerationLog.previewBytes && full.contains("FULL_LOG_BEGIN") && full.contains("FULL_LOG_END")
              && store.logs.utf8.count <= GenerationLog.previewBytes && !store.logs.contains("FULL_LOG_BEGIN")
              && store.logs.contains("FULL_LOG_END") && !store.logs.contains("\u{fffd}"),
              "Chinese and emoji logs are complete on disk and bounded without broken UTF-8 in the UI")

    let reopened = AppStore(); reopened.selectedID = long.id
    try await wait({ reopened.logs == "正在读取日志…" })
    try check(reopened.logs.utf8.count <= GenerationLog.previewBytes && reopened.logs.contains("FULL_LOG_END")
              && !reopened.logs.contains("FULL_LOG_BEGIN") && !reopened.logs.contains("\u{fffd}"),
              "reopened long logs read only the tail and keep valid UTF-8")
    reopened.openLog(for: first)
    try await wait({ reopened.logs == "正在读取日志…" })
    try check(reopened.logs == firstLog && reopened.selectedCreation.count == 7,
              "relaunch restores every turn and reads earlier logs independently")
    reopened.openLog(for: failed)
    try await wait({ reopened.logs == "正在读取日志…" })
    try check(reopened.logs.contains("Failed before inference started"), "early failure log is readable after relaunch")

    // Old task files remain available through the same per-turn selector.
    var legacy = first; legacy.id = UUID()
    legacy.request.output = root.appendingPathComponent("existing-task/image.png").path
    _ = try file("existing-task/inference.log", "Existing inference log\n")
    reopened.generations.append(legacy)
    reopened.openLog(for: legacy)
    try await wait({ reopened.logs == "正在读取日志…" })
    try check(reopened.logs == "Existing inference log\n", "existing inference logs remain readable")
    var enhancementFailure = legacy; enhancementFailure.id = UUID(); enhancementFailure.status = .failed
    enhancementFailure.error = "Existing enhancement failure"
    enhancementFailure.request.output = root.appendingPathComponent("existing-enhancement/image.png").path
    _ = try file("existing-enhancement/enhancement/llama.log", "Enhancement diagnostic\n")
    reopened.generations.append(enhancementFailure)
    reopened.openLog(for: enhancementFailure)
    try await wait({ reopened.logs == "正在读取日志…" })
    try check(reopened.logs.contains("Enhancement diagnostic") && reopened.logs.contains("Existing enhancement failure"),
              "existing early enhancement failures show diagnostics and their saved error")
    var missing = enhancementFailure; missing.id = UUID()
    missing.request.output = root.appendingPathComponent("no-log/image.png").path
    reopened.generations.append(missing); reopened.openLog(for: missing)
    try await wait({ reopened.logs == "正在读取日志…" })
    try check(reopened.logs == missing.error, "a task without log files still shows its saved failure")

    store.newGeneration()
    let independent = try await submit("NEW_CREATION")
    store.selectLog(first.id)
    try check(store.logGenerationID == independent.id, "the task selector cannot leak logs from another creation")
    store.selectedID = second.id
    try await wait({ store.logs == "正在读取日志…" })
    try check(store.logGenerationID == second.id && store.logs == secondLog,
              "switching conversations resets the log selection to that conversation")
    try Data("invalid executable".utf8).write(to: python)
    store.prompt = "LAUNCH_FAILURE"; store.generate()
    let launchFailed = store.generations[0]
    try check(!store.isRunning && launchFailed.status == .failed && store.prompt == "LAUNCH_FAILURE"
              && (try completeLog(launchFailed)).contains(launchFailed.error ?? "missing error"),
              "native launch failure preserves the draft and writes its error to the new task log")
    try check(try completeLog(first) == firstLog && (try completeLog(second)) == secondLog,
              "later failures and cancellations never modify earlier logs")

    if let snapshots = ProcessInfo.processInfo.environment["LIGHTX2V_LOG_SNAPSHOTS"] {
        try fm.createDirectory(atPath: snapshots, withIntermediateDirectories: true)
        reopened.openLog(for: failed)
        try await wait({ reopened.logs == "正在读取日志…" })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 205),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        for width in [650, 1000] {
            let host = NSHostingView(rootView: LogPanel().environmentObject(reopened).environment(\.colorScheme, .light))
            window.contentView = host; window.setContentSize(NSSize(width: width, height: 205))
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AppError.message("Log snapshot failed") }
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: snapshots).appendingPathComponent("logs-\(width).png"))
        }
    }
}
