import AppKit
import SwiftUI
import LightX2VCore
import UniformTypeIdentifiers

enum GenerationModel: String, CaseIterable, Identifiable {
    case qwenImage21

    var id: String { rawValue }
    var title: String {
        switch self { case .qwenImage21: return "Qwen-Image-2.1" }
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
    @Published private(set) var inputImages: [InputImage] = []
    @Published private(set) var isImportingImages = false
    @Published var isComposingPrompt = false
    @Published private(set) var selectedModel: GenerationModel?
    @Published var modelPreparationExpanded = false
    @Published var generationParametersExpanded = false
    @Published var generationSize = GenerationSize()
    @Published var isRunning = false
    @Published var isChecking = false
    @Published var isStopping = false
    @Published var isPreparingWorkspace = false
    @Published var isPreparingResources = false
    var setupTask: Task<Void, Never>?
    @Published var environmentReady = false
    @Published var environmentMessage = "尚未检查运行环境"
    @Published var phase = "准备就绪"
    @Published var currentStep = 0
    @Published var activeID: UUID?
    @Published var logs = ""
    @Published var errorMessage: String?
    @Published var showSettings = false
    @Published private(set) var hasCompletedGeneralSetup = false
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
    private var stateURL: URL
    private let locatorRoot: URL
    private var canPersist = true
    private var draftImageDirectory: URL?

    var selected: Generation? { generations.first { $0.id == selectedID } }
    var busy: Bool { isRunning || isChecking || isPreparingWorkspace || isPreparingResources || isImportingImages }
    var canAddImages: Bool { selectedModel == .qwenImage21 && !needsGeneralSetup && !isPreparingWorkspace && !isImportingImages }
    var needsGeneralSetup: Bool { !hasCompletedGeneralSetup || !settings.hasGeneralPaths }
    var hasUnsavedModelSettings: Bool { modelDirectory != settings.model || modelConfig != settings.config }
    var width: Int? { generationSize.dimensions?.width }
    var height: Int? { generationSize.dimensions?.height }
    var canGenerate: Bool { selectedModel != nil && !needsGeneralSetup && !busy && !isComposingPrompt && !hasUnsavedModelSettings && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var bridgePath: String {
        (Bundle.main.url(forResource: "bridge", withExtension: "py")
         ?? Bundle.module.url(forResource: "bridge", withExtension: "py")!).path
    }

    init() {
        let fm = FileManager.default
        let root = ProcessInfo.processInfo.environment["LIGHTX2V_APP_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? WorkspaceStorage.applicationSupportRoot
        locatorRoot = root
        stateURL = root.appendingPathComponent("workspace.json")
        var data = WorkspaceData()
        var readError: String?
        do {
            stateURL = try WorkspaceStorage.stateURL(locatorRoot: root)
            if fm.fileExists(atPath: stateURL.path) { data = try JSONFile.read(WorkspaceData.self, from: stateURL) }
        } catch {
            canPersist = false
            readError = "无法读取原工作区，原文件已保留。\(error.localizedDescription)"
        }
        data.recoverInterrupted()
        settings = data.settings; generations = data.generations
        modelDirectory = data.settings.model; modelConfig = data.settings.config
        hasCompletedGeneralSetup = data.hasCompletedGeneralSetup
        errorMessage = readError
    }

    func persist() {
        guard canPersist, !isPreparingWorkspace, !settings.workingDirectory.isEmpty else { return }
        do { try JSONFile.write(WorkspaceData(settings: settings, generations: generations, hasCompletedGeneralSetup: hasCompletedGeneralSetup), to: stateURL) }
        catch { errorMessage = "无法保存应用状态：\(error.localizedDescription)" }
    }

    func newGeneration() {
        guard !isImportingImages else { return }
        selectedID = nil; prompt = ""; showLogs = false; generationSize = GenerationSize()
        clearInputImages()
    }

    func chooseInputImages() {
        guard canAddImages else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加图片"
        panel.message = "选择用于编辑的图片，建议 1–3 张，最多 8 张"
        panel.begin { [weak self] response in
            if response == .OK { self?.addInputImages(panel.urls) }
        }
    }

    func addInputImages(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importImages { urls }
    }

    func receiveImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canAddImages, !providers.isEmpty else { return false }
        importImages {
            var urls: [URL] = []
            for provider in providers {
                let url: URL = try await withCheckedThrowingContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        if let url, url.isFileURL { continuation.resume(returning: url) }
                        else { continuation.resume(throwing: AppError.message("无法读取拖入的图片，请从 Finder 拖入图片文件。")) }
                    }
                }
                urls.append(url)
            }
            return urls
        }
        return true
    }

    private func importImages(_ load: @escaping () async throws -> [URL]) {
        guard canAddImages else { return }
        let directory = draftImageDirectory ?? WorkspaceLayout(settings.workingDirectory).temporary
            .appendingPathComponent("input-draft-" + UUID().uuidString)
        draftImageDirectory = directory
        let existing = inputImages
        isImportingImages = true
        Task {
            defer { isImportingImages = false; finishTerminationIfNeeded() }
            do {
                let urls = try await load()
                inputImages = try await Task.detached(priority: .userInitiated) {
                    try InputImages.importing(urls, into: directory, existing: existing)
                }.value
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func removeInputImage(_ image: InputImage) {
        guard !isImportingImages else { return }
        inputImages.removeAll { $0.id == image.id }
        let url = URL(fileURLWithPath: image.path)
        if url.deletingLastPathComponent() == draftImageDirectory { try? FileManager.default.removeItem(at: url) }
    }

    func clearInputImages() {
        inputImages = []
        if let directory = draftImageDirectory { try? FileManager.default.removeItem(at: directory) }
        draftImageDirectory = nil
    }

    func usePrompt(_ value: String) { selectedID = nil; prompt = value }

    func selectModel(_ model: GenerationModel) {
        guard !busy else { return }
        let changed = selectedModel != model
        selectedModel = model
        showInspector = true
        modelPreparationExpanded = true
        generationParametersExpanded = true
        if changed { environmentReady = false; checkEnvironment() }
    }

    func reuse(_ generation: Generation) {
        guard !isImportingImages else { return }
        clearInputImages()
        inputImages = generation.request.inputImages
        prompt = generation.request.prompt
        generationSize = GenerationSize(width: generation.request.width, height: generation.request.height,
                                        automaticResolution: generation.request.resolution)
        selectedID = nil
    }

    func applyGeneralSettings(_ value: AppSettings) async throws {
        guard !busy else { throw AppError.message("请等待当前任务结束后再保存设置。") }
        var updated = settings
        func path(_ value: String) -> String {
            (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        }
        updated.workingDirectory = path(value.workingDirectory)
        updated.repository = path(value.repository)
        updated.python = path(value.python)
        // Carry the same relative config to a newly downloaded checkout. Keep custom config choices.
        var suggested: String?
        if updated.config.isEmpty {
            suggested = updated.repository + "/configs/platforms/mps/qwen_image_21_viggle_v03.json"
        } else if updated.repository != settings.repository, !settings.repository.isEmpty,
                  updated.config.hasPrefix(settings.repository + "/") {
            suggested = updated.repository + updated.config.dropFirst(settings.repository.count)
        }
        if let suggested, FileManager.default.fileExists(atPath: suggested) { updated.config = suggested }
        try updated.validateGeneralPaths()
        let preserveModelDraft = hasUnsavedModelSettings
        isPreparingWorkspace = true
        defer { isPreparingWorkspace = false; finishTerminationIfNeeded() }
        let snapshot = WorkspaceData(settings: updated, generations: generations, hasCompletedGeneralSetup: true)
        let previous = stateURL; let locator = locatorRoot
        let saved = try await Task.detached(priority: .userInitiated) {
            try WorkspaceStorage.save(snapshot, previousState: previous, locatorRoot: locator)
        }.value
        let changedWorkspace = stateURL.standardizedFileURL.resolvingSymlinksInPath() != WorkspaceLayout(saved.settings.workingDirectory).state
        settings = saved.settings; generations = saved.generations
        if changedWorkspace { selectedID = nil; logs = ""; showLogs = false; clearInputImages() }
        if !preserveModelDraft { modelDirectory = settings.model; modelConfig = settings.config }
        stateURL = WorkspaceLayout(settings.workingDirectory).state
        canPersist = true; hasCompletedGeneralSetup = true; environmentReady = false
        errorMessage = nil; showSettings = false
        environmentMessage = "通用设置已保存，请在右侧准备并检查模型。"
    }

    func applyModelSettings() {
        guard selectedModel != nil else { return }
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
        guard selectedModel != nil else { return }
        modelPreparationExpanded = true
        modelPreparationFocus += 1
    }

    private func applySettings(_ value: AppSettings) {
        guard !busy else { return }
        guard !needsGeneralSetup else { showSettings = true; return }
        settings = value; environmentReady = false; persist(); checkEnvironment()
    }

    func checkEnvironment() {
        guard !busy else { return }
        guard selectedModel != nil else {
            environmentReady = false
            environmentMessage = "请先选择模型。"
            return
        }
        guard !needsGeneralSetup else {
            environmentMessage = "请先完成通用设置。"
            return
        }
        guard !settings.model.isEmpty, !settings.config.isEmpty else {
            environmentReady = false
            environmentMessage = "请在右侧「模型准备」中选择模型目录和 Config 配置。"
            return
        }
        do {
            try settings.validatePaths()
            let layout = WorkspaceLayout(settings.workingDirectory)
            try layout.prepare()
            let requestURL = layout.temporary.appendingPathComponent("environment-check.json")
            try JSONFile.write(["repository": settings.repository, "model": settings.model, "config": settings.config], to: requestURL)
            isChecking = true; environmentReady = false; environmentMessage = "正在检查 Python、MPS 和模型…"
            let token = UUID(); checkToken = token
            let process = ProcessRunner(); checker = process
            try process.start(python: settings.python, bridge: bridgePath, mode: "check", request: requestURL.path, workspace: settings.workingDirectory,
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
                self.environmentMessage = "环境检查超时。若 macOS 正在请求文件访问权限，请允许后重试；否则请检查 Python 环境。"
                self.checker?.stop()
            }
        } catch {
            isChecking = false; checker = nil; environmentReady = false
            environmentMessage = error.localizedDescription
        }
    }

    func generate() {
        guard !busy, !isComposingPrompt else { return }
        guard selectedModel != nil else { errorMessage = "请先选择模型。"; return }
        guard !needsGeneralSetup else { showSettings = true; return }
        guard !hasUnsavedModelSettings else {
            showModelPreparation()
            errorMessage = "请先在右侧「模型准备」中保存并检查模型设置。"
            return
        }
        do {
            try settings.validatePaths()
            guard environmentReady else { showModelPreparation(); checkEnvironment(); return }
            let seed = Int64.random(in: 0...4294967295)
            let id = UUID()
            let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
            let directory = URL(fileURLWithPath: settings.outputDirectory)
                .appendingPathComponent(formatter.string(from: Date()) + "-" + id.uuidString.prefix(8))
            var request = try InferenceRequest(settings: settings, prompt: prompt, width: width, height: height,
                                               seed: seed, output: directory.appendingPathComponent("image.png").path,
                                               inputImages: inputImages, resolution: generationSize.automaticResolution)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            request.inputImages = try InputImages.snapshot(inputImages, in: directory)
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
                try process.start(python: settings.python, bridge: bridgePath, mode: "run", request: requestURL.path, workspace: settings.workingDirectory,
                                  onEvent: { [weak self] event in self?.receive(event, for: id) },
                                  onExit: { [weak self] code in self?.exited(code, for: id) })
                // Clear only after launch succeeds; the submitted prompt remains in history.
                prompt = ""
                clearInputImages()
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
            let totalSteps = event["total"] as? Int ?? 6
            if !isStopping { phase = "正在生成 · 第 \(currentStep) / \(totalSteps) 步" }
        case "error":
            activeLog += "\n" + (event["message"] as? String ?? "未知错误") + "\n"
            if selectedID == id { logs = activeLog }
        case "done":
            receivedDone = true
            // The bridge validates PNG decoding and dimensions before completion.
            let status = GenerationStatus(rawValue: event["status"] as? String ?? "failed") ?? .failed
            let message = event["message"] as? String
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
        stop(); checker?.stop(); setupTask?.cancel(); finishTerminationIfNeeded()
    }

    func finishSetupTask() {
        setupTask = nil; isPreparingResources = false; finishTerminationIfNeeded()
    }

    private func finishTerminationIfNeeded() {
        if !busy, let completion = terminationCompletion { clearInputImages(); terminationCompletion = nil; completion() }
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
