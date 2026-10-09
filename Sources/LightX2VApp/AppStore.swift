import AppKit
import SwiftUI
import LightX2VCore

enum GenerationModel: String, CaseIterable, Identifiable {
    case qwenImage21

    var id: String { rawValue }
    var title: String {
        switch self { case .qwenImage21: return "Qwen-Image-2.1" }
    }
    var detail: String {
        switch self { case .qwenImage21: return "Viggle v0.3 · BF16" }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var settings: AppSettings
    @Published var modelDirectory: String
    @Published var modelConfig: String
    @Published var generations: [Generation]
    @Published var selectedID: UUID? { didSet { loadSelectedLog() } }
    @Published var prompt = ""
    @Published var selectedModel: GenerationModel = .qwenImage21
    @Published var generationSize = GenerationSize()
    @Published var seedText = "42"
    @Published var randomSeed = false
    @Published var search = ""
    @Published var isRunning = false
    @Published var isChecking = false
    @Published var isStopping = false
    @Published var environmentReady = false
    @Published var environmentMessage = "尚未检查运行环境"
    @Published var phase = "准备就绪"
    @Published var currentStep = 0
    @Published var totalSteps = 6
    @Published var activeID: UUID?
    @Published var logs = ""
    @Published var errorMessage: String?
    @Published var showSettings = false
    @Published var showLogs = false
    @Published var showInspector = true
    @Published var modelPreparationFocus = 0
    private var runner: ProcessRunner?
    private var checker: ProcessRunner?
    private var activeLog = ""
    private var startedAt: Date?
    private var receivedDone = false
    private var checkToken = UUID()
    private var terminationCompletion: (() -> Void)?
    private let stateURL: URL

    var selected: Generation? { generations.first { $0.id == selectedID } }
    var busy: Bool { isRunning || isChecking }
    var hasUnsavedModelSettings: Bool { modelDirectory != settings.model || modelConfig != settings.config }
    var width: Int {
        get { generationSize.dimensions.width }
        set { generationSize.setDimensions(width: newValue, height: height) }
    }
    var height: Int {
        get { generationSize.dimensions.height }
        set { generationSize.setDimensions(width: width, height: newValue) }
    }
    var canGenerate: Bool { !busy && !hasUnsavedModelSettings && generationSize.dimensions.isValid && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var filteredGenerations: [Generation] {
        search.isEmpty ? generations : generations.filter { $0.request.prompt.localizedCaseInsensitiveContains(search) }
    }
    var bridgePath: String {
        (Bundle.main.url(forResource: "bridge", withExtension: "py")
         ?? Bundle.module.url(forResource: "bridge", withExtension: "py")!).path
    }

    init() {
        let fm = FileManager.default
        let root = ProcessInfo.processInfo.environment["LIGHTX2V_APP_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LightX2V APP")
        stateURL = root.appendingPathComponent("workspace.json")
        var data = WorkspaceData()
        var readError: String?
        if fm.fileExists(atPath: stateURL.path) {
            do { data = try JSONFile.read(WorkspaceData.self, from: stateURL) }
            catch {
                // Preserve malformed history before creating a clean workspace.
                let backup = root.appendingPathComponent("workspace-backup-\(Int(Date().timeIntervalSince1970)).json")
                do { try fm.copyItem(at: stateURL, to: backup) }
                catch { readError = "历史文件无法读取或备份：\(error.localizedDescription)" }
                if readError == nil { readError = "历史文件无法读取，原文件已备份到 \(backup.path)。" }
            }
        }
        data.recoverInterrupted()
        settings = data.settings; generations = data.generations
        modelDirectory = data.settings.model; modelConfig = data.settings.config
        errorMessage = readError
    }

    func persist() {
        do { try JSONFile.write(WorkspaceData(settings: settings, generations: generations), to: stateURL) }
        catch { errorMessage = "无法保存应用状态：\(error.localizedDescription)" }
    }

    func newGeneration() { selectedID = nil; prompt = ""; showLogs = false; generationSize = GenerationSize() }

    func usePrompt(_ value: String) { selectedID = nil; prompt = value }

    func reuse(_ generation: Generation) {
        prompt = generation.request.prompt
        generationSize = GenerationSize(width: generation.request.width, height: generation.request.height)
        seedText = String(generation.request.seed); randomSeed = false
        selectedID = nil
    }

    func applyGeneralSettings(_ value: AppSettings) {
        var updated = settings
        updated.repository = value.repository
        updated.python = value.python
        updated.outputDirectory = value.outputDirectory
        applySettings(updated)
    }

    func applyModelSettings() {
        var updated = settings
        updated.model = modelDirectory
        updated.config = modelConfig
        applySettings(updated)
    }

    func discardModelSettings() {
        guard !busy else { return }
        modelDirectory = settings.model; modelConfig = settings.config
    }

    func showModelPreparation() {
        showInspector = true
        modelPreparationFocus += 1
    }

    private func applySettings(_ value: AppSettings) {
        guard !busy else { return }
        settings = value; environmentReady = false; persist(); checkEnvironment()
    }

    func checkEnvironment() {
        guard !busy else { return }
        do {
            try settings.validatePaths()
            let requestURL = stateURL.deletingLastPathComponent().appendingPathComponent("environment-check.json")
            try JSONFile.write(["repository": settings.repository, "model": settings.model, "config": settings.config], to: requestURL)
            isChecking = true; environmentReady = false; environmentMessage = "正在检查 Python、MPS 和模型…"
            let token = UUID(); checkToken = token
            let process = ProcessRunner(); checker = process
            try process.start(python: settings.python, bridge: bridgePath, mode: "check", request: requestURL.path,
                              onEvent: { [weak self] event in
                guard let self, self.checkToken == token else { return }
                if event["type"] as? String == "check" {
                    self.environmentReady = event["ok"] as? Bool ?? false
                    self.environmentMessage = event["message"] as? String ?? "检查完成"
                } else if event["type"] as? String == "error" {
                    self.environmentMessage = event["message"] as? String ?? "环境检查失败"
                }
            }, onExit: { [weak self] code in
                guard let self, self.checkToken == token else { return }
                self.isChecking = false; self.checker = nil
                if code != 0 || !self.environmentReady {
                    self.environmentReady = false
                    if self.environmentMessage.hasPrefix("正在") { self.environmentMessage = "环境检查未完成（退出码 \(code)），请检查 Python 路径。" }
                }
                self.finishTerminationIfNeeded()
            })
            DispatchQueue.main.asyncAfter(deadline: .now() + 100) { [weak self] in
                guard let self, self.isChecking, self.checkToken == token else { return }
                self.environmentMessage = "环境检查超时，请检查 Python 环境。"
                self.checker?.stop()
            }
        } catch {
            isChecking = false; checker = nil; environmentReady = false
            environmentMessage = error.localizedDescription
        }
    }

    func generate() {
        guard !busy else { return }
        guard !hasUnsavedModelSettings else {
            showModelPreparation()
            errorMessage = "请先在右侧「模型准备」中保存并检查模型设置。"
            return
        }
        do {
            try settings.validatePaths()
            guard environmentReady else { showModelPreparation(); checkEnvironment(); return }
            let seed: Int64
            if randomSeed { seed = Int64.random(in: 0...4294967295) }
            else {
                guard let value = Int64(seedText.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw AppError.message("种子必须为整数。") }
                seed = value
            }
            let id = UUID()
            let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
            let directory = URL(fileURLWithPath: settings.outputDirectory)
                .appendingPathComponent(formatter.string(from: Date()) + "-" + id.uuidString.prefix(8))
            let request = try InferenceRequest(settings: settings, prompt: prompt, width: width, height: height,
                                               seed: seed, output: directory.appendingPathComponent("image.png").path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let requestURL = directory.appendingPathComponent("request.json")
            try JSONFile.write(request, to: requestURL)
            let generation = Generation(id: id, request: request)
            try JSONFile.write(generation, to: directory.appendingPathComponent("generation.json"))
            generations.insert(generation, at: 0)
            activeID = id; selectedID = id; activeLog = ""; logs = ""
            startedAt = Date(); phase = "正在启动推理"; currentStep = 0
            isRunning = true; isStopping = false; receivedDone = false
            persist()
            let process = ProcessRunner(); runner = process
            do {
                try process.start(python: settings.python, bridge: bridgePath, mode: "run", request: requestURL.path,
                                  onEvent: { [weak self] event in self?.receive(event, for: id) },
                                  onExit: { [weak self] code in self?.exited(code, for: id) })
            } catch {
                markFinished(id, status: .failed, message: error.localizedDescription)
                isRunning = false; runner = nil; activeID = nil
                throw error
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func receive(_ event: [String: Any], for id: UUID) {
        guard activeID == id else { return }
        switch event["type"] as? String {
        case "log":
            activeLog += (event["message"] as? String ?? "") + "\n"
            if activeLog.utf8.count > 90000 { activeLog = String(activeLog.suffix(60000)) }
            if selectedID == id { logs = activeLog }
        case "status": if !isStopping { phase = event["message"] as? String ?? phase }
        case "step":
            currentStep = event["step"] as? Int ?? 0
            totalSteps = event["total"] as? Int ?? 6
            if !isStopping { phase = "正在生成 · 第 \(currentStep) / \(totalSteps) 步" }
        case "error":
            activeLog += "\n" + (event["message"] as? String ?? "未知错误") + "\n"
            if selectedID == id { logs = activeLog }
        case "done":
            receivedDone = true
            var status = GenerationStatus(rawValue: event["status"] as? String ?? "failed") ?? .failed
            var message = event["message"] as? String
            if status == .completed, let job = generations.first(where: { $0.id == id }), NSImage(contentsOfFile: job.request.output) == nil {
                status = .failed; message = "推理已退出，但输出图片无法读取。"
            }
            markFinished(id, status: status, message: message, duration: event["duration"] as? Double)
        default: break
        }
    }

    private func markFinished(_ id: UUID, status: GenerationStatus, message: String?, duration: Double? = nil) {
        guard let index = generations.firstIndex(where: { $0.id == id }) else { return }
        generations[index].status = status
        generations[index].error = message
        generations[index].duration = duration ?? startedAt.map { Date().timeIntervalSince($0) }
        phase = status.label
        do { try JSONFile.write(generations[index], to: URL(fileURLWithPath: generations[index].directory).appendingPathComponent("generation.json")) }
        catch { errorMessage = "无法保存任务记录：\(error.localizedDescription)" }
        persist()
    }

    private func exited(_ code: Int32, for id: UUID) {
        guard activeID == id else { return }
        if !receivedDone {
            markFinished(id, status: isStopping ? .cancelled : .failed,
                         message: isStopping ? "生成已停止" : "推理进程意外退出（\(code)）。请查看运行日志。")
        }
        isRunning = false; isStopping = false; runner = nil; activeID = nil
        finishTerminationIfNeeded()
    }

    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true; phase = "正在停止并释放内存…"; runner?.stop()
    }

    func prepareToTerminate(_ completion: @escaping () -> Void) {
        terminationCompletion = completion
        stop(); checker?.stop(); finishTerminationIfNeeded()
    }

    private func finishTerminationIfNeeded() {
        if !busy, let completion = terminationCompletion { terminationCompletion = nil; completion() }
    }

    func elapsed(_ generation: Generation, now: Date = Date()) -> String {
        let seconds = Int(generation.duration ?? now.timeIntervalSince(generation.createdAt))
        return seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分 \(seconds % 60) 秒"
    }

    private func loadSelectedLog() {
        guard let job = selected else { logs = ""; return }
        if job.id == activeID { logs = activeLog; return }
        logs = "正在读取日志…"
        let id = job.id
        let url = URL(fileURLWithPath: job.directory).appendingPathComponent("inference.log")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var value = "没有可用日志。"
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                let count = (try? handle.seekToEnd()) ?? 0
                try? handle.seek(toOffset: count > 90000 ? count - 90000 : 0)
                if let data = try? handle.readToEnd() { value = String(decoding: data, as: UTF8.self) }
            }
            let text = value
            DispatchQueue.main.async { if self?.selectedID == id { self?.logs = text } }
        }
    }

    func reveal(_ job: Generation) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.status == .completed ? job.request.output : job.directory)]) }

    func export(_ job: Generation) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "LightX2V-\(job.request.seed).png"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do { try Data(contentsOf: URL(fileURLWithPath: job.request.output)).write(to: url, options: .atomic) }
            catch { self?.errorMessage = "导出失败：\(error.localizedDescription)" }
        }
    }

    func copyImage(_ job: Generation) {
        guard let image = NSImage(contentsOfFile: job.request.output) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
    }

    func removeFromHistory(_ job: Generation) {
        guard job.status != .running else { return }
        generations.removeAll { $0.id == job.id }
        if selectedID == job.id { selectedID = nil }
        persist()
    }
}
