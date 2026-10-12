import AppKit
import SwiftUI
import LightX2VCore
import UniformTypeIdentifiers

enum GenerationModel: String, CaseIterable, Identifiable {
    case qwenImage21Turbo

    var id: String { rawValue }
    var title: String {
        switch self { case .qwenImage21Turbo: return QwenImage21Turbo.title }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            if oldValue.promptEnhancement != settings.promptEnhancement { refreshEnhancementResources() }
        }
    }
    @Published var modelDirectory: String
    @Published var modelConfig: String
    @Published var generations: [Generation]
    @Published var selectedID: UUID? {
        didSet { logGenerationID = selectedID; loadSelectedLog() }
    }
    @Published private(set) var logGenerationID: UUID?
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
    @Published var showStartupSettings = true
    @Published var showEnhancementSettings = false
    @Published private(set) var hasCompletedGeneralSetup = false
    @Published var showLogs = false
    @Published var showInspector = true
    @Published var modelPreparationFocus = 0
    private var runner: ProcessRunner?
    private var activeLog = ""
    private var activeLogFile: GenerationLog?
    private var startedAt: Date?
    private var receivedDone = false
    private var didStart = false
    private var terminationCompletion: (() -> Void)?
    private var stateURL: URL
    private let locatorRoot: URL
    private var canPersist = true
    private var draftImageDirectory: URL?
    private var draftCreationID = UUID()
    private var pendingImageImports: [[ImagePasteboard.Source]] = []
    private var thinkingStreams: [UUID: EnhancementTextStream] = [:]
    private var promptStreams: [UUID: EnhancementTextStream] = [:]
    private var enhancementResourceTask: Task<Void, Never>?
    @Published private var enhancementAvailability: [PromptEnhancementMode: Bool] = [:]

    var enhancementMode: PromptEnhancementMode {
        if isRunning, let job = generations.first(where: { $0.id == activeID }), let reply = job.enhancement { return reply.mode }
        return inputImages.isEmpty ? .t2i : .i2i
    }
    var enhancementResourcesReady: Bool { enhancementAvailability[enhancementMode] == true }

    // SwiftUI rendering must not perform filesystem reads against large model
    // files. Check both modes once per configuration, away from the main thread.
    private func refreshEnhancementResources(presentIfMissing: Bool = false) {
        enhancementResourceTask?.cancel()
        let value = settings.promptEnhancement
        let mode = enhancementMode
        enhancementResourceTask = Task { [weak self] in
            let availability = await Task.detached(priority: .utility) {
                [PromptEnhancementMode.t2i: (try? value.validate(for: .t2i)) != nil,
                 PromptEnhancementMode.i2i: (try? value.validate(for: .i2i)) != nil]
            }.value
            guard !Task.isCancelled, let self, self.settings.promptEnhancement == value else { return }
            self.enhancementAvailability = availability
            if presentIfMissing && value.enabled && availability[mode] != true { self.showEnhancementSettings = true }
        }
    }

    func setPromptEnhancementEnabled(_ enabled: Bool) {
        guard !configurationBusy else { return }
        var value = settings.promptEnhancement
        if enabled { value.discover(near: [settings.model, settings.repository, settings.workingDirectory]) }
        value.enabled = enabled
        settings.promptEnhancement = value
        persist()
        if enabled { refreshEnhancementResources(presentIfMissing: true) }
    }

    func applyEnhancementSettings(_ value: PromptEnhancementSettings) {
        guard !configurationBusy else { return }
        settings.promptEnhancement = value
        persist(); showEnhancementSettings = false
    }

    func thinkingStream(for job: Generation) -> EnhancementTextStream {
        if let stream = thinkingStreams[job.id] { return stream }
        let stream = EnhancementTextStream(text: job.enhancement?.thinking ?? "")
        thinkingStreams[job.id] = stream
        return stream
    }

    func promptStream(for job: Generation) -> EnhancementTextStream {
        if let stream = promptStreams[job.id] { return stream }
        let stream = EnhancementTextStream(text: job.enhancement?.prompt ?? "")
        promptStreams[job.id] = stream
        return stream
    }

    var selected: Generation? { generations.first { $0.id == selectedID } }
    var logGeneration: Generation? { selectedCreation.first { $0.id == logGenerationID } }
    var selectedCreation: [Generation] {
        guard let selected else { return [] }
        return generations.reversed().filter { $0.creationID == selected.creationID }
    }
    var recentCreations: [Generation] {
        var seen = Set<UUID>()
        return generations.filter { seen.insert($0.creationID).inserted }
    }
    func creationTitle(_ job: Generation) -> String {
        generations.last(where: { $0.creationID == job.creationID })?.title ?? job.title
    }
    var configurationBusy: Bool { isRunning || isChecking || isPreparingWorkspace || isPreparingResources }
    var busy: Bool { configurationBusy || isImportingImages }
    var canReferenceImages: Bool { selectedModel == .qwenImage21Turbo && !needsGeneralSetup && !isPreparingWorkspace && terminationCompletion == nil }
    var canAddImages: Bool { canReferenceImages && !isImportingImages }
    var needsGeneralSetup: Bool { !hasCompletedGeneralSetup || !settings.hasGeneralPaths }
    var hasUnsavedModelSettings: Bool { modelDirectory != settings.model || modelConfig != settings.config }
    var width: Int? { generationSize.dimensions?.width }
    var height: Int? { generationSize.dimensions?.height }
    var canGenerate: Bool { selectedModel != nil && !needsGeneralSetup && environmentReady && !settings.model.isEmpty && !settings.config.isEmpty && !busy && !isComposingPrompt && !hasUnsavedModelSettings && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
        refreshEnhancementResources()
    }

    func persist() {
        guard canPersist, !isPreparingWorkspace, !settings.workingDirectory.isEmpty else { return }
        do { try JSONFile.write(WorkspaceData(settings: settings, generations: generations, hasCompletedGeneralSetup: hasCompletedGeneralSetup), to: stateURL) }
        catch { errorMessage = "无法保存应用状态：\(error.localizedDescription)" }
    }

    func newGeneration() {
        guard !isImportingImages else { return }
        selectedID = nil; prompt = ""; showLogs = false; generationSize = GenerationSize()
        draftCreationID = UUID()
        clearInputImages()
    }

    func chooseInputImages() {
        guard canAddImages else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加图片"
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

    /// Returning true consumes an image paste even when it is unavailable, so
    /// file paths or a browser's image URL never replace the user's prompt.
    func receiveImagePaste(_ pasteboard: NSPasteboard) -> Bool {
        guard ImagePasteboard.containsImages(pasteboard) else { return false }
        guard canReferenceImages else {
            if selectedModel == nil { errorMessage = "请先选择模型，再添加参考图。" }
            return true
        }
        do {
            let sources = try ImagePasteboard.read(pasteboard)
            guard !sources.isEmpty else { throw AppError.message("无法读取剪贴板图片，请重新复制。") }
            pendingImageImports.append(sources)
            importNextImageBatch()
        } catch { errorMessage = error.localizedDescription }
        return true
    }

    private func importImages(deduplicate: Bool = true, cleanup: (() -> Void)? = nil,
                              _ load: @escaping () async throws -> [URL]) {
        guard canAddImages else { return }
        let directory = draftImageDirectory ?? WorkspaceLayout(settings.workingDirectory).temporary
            .appendingPathComponent("input-draft-" + UUID().uuidString)
        draftImageDirectory = directory
        let existing = inputImages
        isImportingImages = true
        Task {
            defer { cleanup?(); isImportingImages = false; importNextImageBatch(); finishTerminationIfNeeded() }
            do {
                let urls = try await load()
                inputImages = try await Task.detached(priority: .userInitiated) {
                    try InputImages.importing(urls, into: directory, existing: existing, deduplicate: deduplicate)
                }.value
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func removeInputImage(_ image: InputImage) {
        guard !isImportingImages else { return }
        inputImages.removeAll { $0.id == image.id }
        let url = URL(fileURLWithPath: image.path)
        if let directory = draftImageDirectory,
           url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == directory.standardizedFileURL.resolvingSymlinksInPath().path {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func clearInputImages() {
        pendingImageImports = []
        inputImages = []
        if let directory = draftImageDirectory { try? FileManager.default.removeItem(at: directory) }
        draftImageDirectory = nil
    }

    func usePrompt(_ value: String) { selectedID = nil; prompt = value }

    func selectModel(_ model: GenerationModel) {
        guard !busy else { return }
        selectedModel = model
        showInspector = true
        modelPreparationExpanded = true
        generationParametersExpanded = true
        if modelDirectory.isEmpty {
            modelDirectory = QwenImage21Turbo.suggestedModel(near: [settings.repository, settings.workingDirectory]) ?? ""
        }
        if modelConfig.isEmpty { modelConfig = QwenImage21Turbo.suggestedConfig(repository: settings.repository) ?? "" }
    }

    func reuse(_ generation: Generation) {
        guard !isImportingImages else { return }
        clearInputImages()
        inputImages = generation.request.inputImages
        prompt = generation.request.prompt
        generationSize = GenerationSize(width: generation.request.width, height: generation.request.height,
                                        automaticResolution: generation.request.resolution)
        selectedID = generation.id
    }

    func reference(_ generation: Generation) {
        guard generation.status == .completed, canReferenceImages else { return }
        pendingImageImports.append([.file(URL(fileURLWithPath: generation.request.output))])
        importNextImageBatch()
    }

    private func importNextImageBatch() {
        guard canAddImages, !pendingImageImports.isEmpty else { return }
        let sources = pendingImageImports.removeFirst()
        let staging = WorkspaceLayout(settings.workingDirectory).temporary
            .appendingPathComponent("clipboard-" + UUID().uuidString)
        importImages(deduplicate: false, cleanup: { try? FileManager.default.removeItem(at: staging) }) {
            try await Task.detached(priority: .userInitiated) {
                try ImagePasteboard.materialize(sources, in: staging)
            }.value
        }
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
        // Default to the only supported model's config in the selected checkout.
        var suggested: String?
        if updated.config.isEmpty {
            suggested = QwenImage21Turbo.suggestedConfig(repository: updated.repository)
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
        if changedWorkspace { selectedID = nil; draftCreationID = UUID(); logs = ""; showLogs = false; clearInputImages() }
        if !preserveModelDraft { modelDirectory = settings.model; modelConfig = settings.config }
        stateURL = WorkspaceLayout(settings.workingDirectory).state
        canPersist = true; hasCompletedGeneralSetup = true; environmentReady = false
        errorMessage = nil
        isPreparingWorkspace = false
        checkEnvironment()
    }

    func applyModelSettings() {
        guard selectedModel != nil, !busy else { return }
        var updated = settings
        updated.model = modelDirectory
        updated.config = modelConfig
        do {
            try updated.validatePaths()
            settings = updated; persist()
        } catch { errorMessage = error.localizedDescription }
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

    func start() {
        guard !didStart else { return }
        didStart = true
        if needsGeneralSetup { environmentMessage = "请先完成通用设置。"; return }
        checkEnvironment()
    }

    func closeGeneralSettings() {
        setupTask?.cancel()
        showStartupSettings = false; showSettings = false
    }

    func checkEnvironment() {
        guard !busy, terminationCompletion == nil else { return }
        guard !needsGeneralSetup else {
            environmentReady = false
            environmentMessage = "请先完成通用设置。"
            return
        }
        do {
            try settings.validateGeneralPaths()
            let layout = WorkspaceLayout(settings.workingDirectory)
            try layout.prepare()
            isChecking = true; environmentReady = false; environmentMessage = "正在检查环境依赖与 MPS…"
            let python = settings.python
            setupTask = Task {
                defer { isChecking = false; finishSetupTask() }
                do {
                    // Startup and the general-settings picker share one policy.
                    // Environment readiness is independent of model selection.
                    let environment = try await PythonEnvironmentSearch.probe(python, workspace: layout)
                    try Task.checkCancellation()
                    environmentReady = environment.isCompatible
                    environmentMessage = environment.compatibilityDetail
                    if environmentReady { showStartupSettings = false; showSettings = false }
                } catch {
                    environmentReady = false
                    environmentMessage = Task.isCancelled ? "环境检查已取消。" : error.localizedDescription
                }
            }
        } catch {
            isChecking = false; environmentReady = false
            environmentMessage = error.localizedDescription
        }
    }

    func generate() {
        guard !busy, !isComposingPrompt else { return }
        guard selectedModel != nil else { errorMessage = "请先选择模型。"; return }
        guard !needsGeneralSetup else { showSettings = true; return }
        guard environmentReady else { showSettings = true; return }
        guard !hasUnsavedModelSettings else {
            showModelPreparation()
            errorMessage = "请先在右侧「模型准备」中保存模型设置。"
            return
        }
        do {
            try settings.validatePaths()
            if settings.promptEnhancement.enabled && (try? settings.promptEnhancement.validate(for: enhancementMode)) == nil {
                showEnhancementSettings = true
                return
            }
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
            let generation = Generation(id: id, creationID: selected?.creationID ?? draftCreationID, request: request)
            try JSONFile.write(generation, to: directory.appendingPathComponent("generation.json"))
            let logFile = try GenerationLog(directory: directory) { [weak self] message in self?.errorMessage = message }
            generations.insert(generation, at: 0)
            activeLogFile = logFile; activeLog = ""; activeID = id; selectedID = id
            startedAt = Date(); phase = generation.enhancement == nil ? "正在启动推理" : "正在启动 Prompt 增强"; currentStep = 0
            appendLog("任务：\(id.uuidString)\n开始：\(generation.createdAt.ISO8601Format())\n\(phase)\n")
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
                activeLogFile?.close(); activeLogFile = nil
                isRunning = false; runner = nil; activeID = nil
                throw error
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func receive(_ event: [String: Any], for id: UUID) {
        guard activeID == id else { return }
        switch event["type"] as? String {
        case "enhancement_thinking":
            guard let job = generations.first(where: { $0.id == id }), job.enhancement?.status.isActive == true,
                  let delta = event["delta"] as? String else { break }
            thinkingStream(for: job).text += delta
        case "enhancement_prompt":
            guard let job = generations.first(where: { $0.id == id }), job.enhancement?.status == .rewriting,
                  let delta = event["delta"] as? String else { break }
            // Only the rewritten-prompt text observes these token updates.
            promptStream(for: job).text += delta
        case "enhancement_phase":
            guard let index = generations.firstIndex(where: { $0.id == id }), generations[index].enhancement != nil else { break }
            let rewriting = event["phase"] as? String == "rewriting"
            generations[index].enhancement?.status = rewriting ? .rewriting : .thinking
            if rewriting {
                generations[index].enhancement?.thinking = thinkingStreams[id]?.text ?? ""
                saveGeneration(generations[index]); persist()
            }
            if !isStopping { phase = rewriting ? "正在整理增强提示词" : "正在增强提示词" }
            appendLog((rewriting ? "正在整理增强提示词" : "正在增强提示词") + "\n")
        case "enhancement_result":
            guard let index = generations.firstIndex(where: { $0.id == id }),
                  let prompt = event["prompt"] as? String, !prompt.isEmpty else { break }
            promptStream(for: generations[index]).text = prompt
            generations[index].enhancement?.thinking = thinkingStreams[id]?.text ?? ""
            generations[index].enhancement?.prompt = prompt
            generations[index].enhancement?.whRatio = event["whRatio"] as? String
            generations[index].enhancement?.ratioFollow = event["ratioFollow"] as? String
            generations[index].enhancement?.duration = event["duration"] as? Double
            generations[index].enhancement?.status = .completed
            appendLog("Prompt 增强已完成\n")
            saveGeneration(generations[index]); persist()
        case "log":
            appendLog((event["message"] as? String ?? "") + "\n")
        case "status":
            if let message = event["message"] as? String {
                if !isStopping { phase = message }
                appendLog(message + "\n")
            }
        case "step":
            currentStep = event["step"] as? Int ?? 0
            let totalSteps = event["total"] as? Int ?? QwenImage21Turbo.inferenceSteps
            if !isStopping { phase = "正在生成 · 第 \(currentStep) / \(totalSteps) 步" }
        case "error":
            appendLog("\n" + (event["message"] as? String ?? "未知错误") + "\n")
        case "done":
            receivedDone = true
            // The bridge validates PNG decoding and dimensions before completion.
            let status = GenerationStatus(rawValue: event["status"] as? String ?? "failed") ?? .failed
            let message = event["message"] as? String
            markFinished(id, status: status, message: message, duration: event["duration"] as? Double)
        default: break
        }
    }

    private func appendLog(_ text: String) {
        activeLogFile?.append(text)
        activeLog = GenerationLog.preview(activeLog + text)
        if logGenerationID == activeID { logs = activeLog }
    }

    private func markFinished(_ id: UUID, status: GenerationStatus, message: String?, duration: Double? = nil) {
        guard let index = generations.firstIndex(where: { $0.id == id }) else { return }
        generations[index].status = status
        generations[index].error = message
        generations[index].duration = duration ?? startedAt.map { Date().timeIntervalSince($0) }
        if generations[index].enhancement?.status.isActive == true {
            generations[index].enhancement?.thinking = thinkingStreams[id]?.text ?? ""
            if let partial = promptStreams[id]?.text, !partial.isEmpty {
                generations[index].enhancement?.prompt = partial
            }
            generations[index].enhancement?.status = status == .cancelled ? .cancelled : .failed
        }
        phase = status.label
        appendLog("\n\(status.label)" + (message.map { "：\($0)" } ?? "") + "\n")
        saveGeneration(generations[index])
        persist()
    }

    private func saveGeneration(_ job: Generation) {
        do { try JSONFile.write(job, to: URL(fileURLWithPath: job.directory).appendingPathComponent("generation.json")) }
        catch { errorMessage = "无法保存任务记录：\(error.localizedDescription)" }
    }

    private func exited(_ code: Int32, for id: UUID) {
        guard activeID == id else { return }
        if !receivedDone {
            markFinished(id, status: isStopping ? .cancelled : .failed,
                         message: isStopping ? "生成已停止" : "推理进程意外退出（\(code)）。请查看运行日志。")
        }
        activeLogFile?.close(); activeLogFile = nil
        isRunning = false; isStopping = false; runner = nil; activeID = nil
        finishTerminationIfNeeded()
    }

    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true; phase = "正在停止并释放内存…"; runner?.stop()
    }

    func prepareToTerminate(_ completion: @escaping () -> Void) {
        terminationCompletion = completion
        stop(); setupTask?.cancel(); finishTerminationIfNeeded()
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
        guard let job = logGeneration else { logs = ""; return }
        if job.id == activeID { logs = activeLog; return }
        logs = "正在读取日志…"
        let id = job.id
        let directory = job.directory
        let error = job.error
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let text = GenerationLog.readPreview(directory: directory, error: error)
            DispatchQueue.main.async { if self?.logGenerationID == id { self?.logs = text } }
        }
    }

    func selectLog(_ id: UUID) {
        guard selectedCreation.contains(where: { $0.id == id }) else { return }
        logGenerationID = id
        loadSelectedLog()
    }

    func openLog(for job: Generation) {
        guard generations.contains(where: { $0.id == job.id }) else { return }
        if selected?.creationID != job.creationID { selectedID = job.id }
        selectLog(job.id)
        showLogs = true
    }

    func revealLog(_ job: Generation) {
        NSWorkspace.shared.activateFileViewerSelecting([GenerationLog.existingURL(for: job) ?? URL(fileURLWithPath: job.directory)])
    }

    func reveal(_ job: Generation) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.status == .completed ? job.request.output : job.directory)]) }

    func copyImage(_ job: Generation) {
        guard let image = NSImage(contentsOfFile: job.request.output) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
    }

    func removeFromHistory(_ job: Generation) {
        guard !generations.contains(where: { $0.creationID == job.creationID && $0.status == .running }) else { return }
        let removingSelected = selected?.creationID == job.creationID
        generations.removeAll { $0.creationID == job.creationID }
        thinkingStreams = thinkingStreams.filter { id, _ in generations.contains { $0.id == id } }
        promptStreams = promptStreams.filter { id, _ in generations.contains { $0.id == id } }
        if removingSelected { selectedID = nil; draftCreationID = UUID() }
        persist()
    }
}
