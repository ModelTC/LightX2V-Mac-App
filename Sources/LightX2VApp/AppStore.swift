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
    @Published var modelDirectory: String { didSet { if oldValue != modelDirectory { modelPathChanged(.turbo) } } }
    @Published var t2iDirectory: String { didSet { if oldValue != t2iDirectory { modelPathChanged(.t2i) } } }
    @Published var i2iDirectory: String { didSet { if oldValue != i2iDirectory { modelPathChanged(.i2i) } } }
    @Published var activeModelDownload: ModelResource?
    @Published var modelDownloadMessages: [ModelResource: String] = [:]
    @Published var modelDownloadProgress: [ModelResource: ModelDownloadProgress] = [:]
    @Published var modelDownloadErrors: Set<ModelResource> = []
    private var modelDownloadID: UUID?
    @Published var readyModelResources: Set<ModelResource> = []
    @Published var modelResourceMessages: [ModelResource: String] = [:]
    private var modelResourceTask: Task<Void, Never>?
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
    @Published var environmentMessage = L10n.english("Environment has not been checked")
    @Published var phase = L10n.english("Ready")
    @Published var currentStep = 0
    @Published var activeID: UUID?
    @Published var logs = ""
    @Published var errorMessage: String?
    @Published var showSettings = false
    @Published var showStartupSettings = true
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
    private var restoringModelPaths = false
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
        enhancementAvailability = [:]
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
            if presentIfMissing && value.enabled && availability[mode] != true { self.showModelPreparation() }
        }
    }

    func setPromptEnhancementEnabled(_ enabled: Bool) {
        guard !configurationBusy else { return }
        var value = settings.promptEnhancement
        if enabled { value.discover(near: [settings.model, settings.repository, settings.workingDirectory], includeRuntime: false) }
        value.enabled = enabled
        settings.promptEnhancement = value
        persist()
        if enabled { refreshEnhancementResources(presentIfMissing: true) }
    }

    func applyEnhancementSettings(_ value: PromptEnhancementSettings) {
        guard !configurationBusy else { return }
        var updated = value
        updated.runtimeDirectory = settings.promptEnhancement.runtimeDirectory
        settings.promptEnhancement = updated
        persist()
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
    var width: Int? { generationSize.dimensions?.width }
    var height: Int? { generationSize.dimensions?.height }
    var canGenerate: Bool { selectedModel != nil && !needsGeneralSetup && environmentReady && readyModelResources.contains(.turbo) && !busy && !isComposingPrompt && (!settings.promptEnhancement.enabled || enhancementResourcesReady) && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
            readError = L10n.english("Unable to read the previous workspace. Original files were preserved. %@", [String(describing: error.localizedDescription)])
        }
        data.recoverInterrupted()
        // Existing complete HF folders can populate the inline directory controls.
        for resource in [ModelResource.t2i, .i2i] {
            let files = data.settings.promptEnhancement
            let model = resource == .t2i ? files.t2iModel : files.i2iModel
            let system = resource == .t2i ? files.t2iSystemPrompt : files.i2iSystemPrompt
            let current = resource == .t2i ? files.t2iDirectory : files.i2iDirectory
            let folder = URL(fileURLWithPath: model).deletingLastPathComponent().path
            if current.isEmpty, model.hasPrefix("/"), URL(fileURLWithPath: system).deletingLastPathComponent().path == folder,
               (try? resource.validate(directory: folder)) != nil {
                if resource == .t2i { data.settings.promptEnhancement.t2iDirectory = folder }
                else { data.settings.promptEnhancement.i2iDirectory = folder }
            }
        }
        settings = data.settings; generations = data.generations
        modelDirectory = data.settings.model
        t2iDirectory = data.settings.promptEnhancement.t2iDirectory; i2iDirectory = data.settings.promptEnhancement.i2iDirectory
        hasCompletedGeneralSetup = data.hasCompletedGeneralSetup
        errorMessage = readError
        refreshEnhancementResources(); refreshModelResources()
    }

    func persist() {
        guard canPersist, !isPreparingWorkspace, !settings.workingDirectory.isEmpty else { return }
        do { try JSONFile.write(WorkspaceData(settings: settings, generations: generations, hasCompletedGeneralSetup: hasCompletedGeneralSetup), to: stateURL) }
        catch { errorMessage = L10n.english("Unable to save application state: %@", [String(describing: error.localizedDescription)]) }
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
        panel.prompt = L10n.english("Add images")
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
                        else { continuation.resume(throwing: AppError.message(L10n.english("Unable to read dropped image. Drag an image file from Finder."))) }
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
            if selectedModel == nil { errorMessage = L10n.english("Choose a model before adding reference images.") }
            return true
        }
        do {
            let sources = try ImagePasteboard.read(pasteboard)
            guard !sources.isEmpty else { throw AppError.message(L10n.english("Unable to read clipboard image. Copy it again.")) }
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
        for resource in [ModelResource.t2i, .i2i] {
            let candidate = resource.destination(in: WorkspaceLayout(settings.workingDirectory)).path
            if (try? resource.validate(directory: candidate)) != nil {
                if resource == .t2i && t2iDirectory.isEmpty { t2iDirectory = candidate }
                if resource == .i2i && i2iDirectory.isEmpty { i2iDirectory = candidate }
            }
        }
        refreshModelResources()
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

    func existingWorkspaceSettings(at path: String) throws -> AppSettings? {
        try WorkspaceStorage.existingWorkspace(at: path, previousState: stateURL)?.settings
    }

    func applyGeneralSettings(_ value: AppSettings) async throws {
        guard !busy else { throw AppError.message(L10n.english("Wait for the current task to finish before saving settings.")) }
        var updated = settings
        func path(_ value: String) -> String {
            (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        }
        updated.workingDirectory = path(value.workingDirectory)
        updated.repository = path(value.repository)
        updated.python = path(value.python)
        updated.promptEnhancement.runtimeDirectory = path(value.promptEnhancement.runtimeDirectory)
        if try WorkspaceStorage.existingWorkspace(at: updated.workingDirectory, previousState: stateURL) == nil {
            try updated.validateGeneralPaths()
        }
        isPreparingWorkspace = true
        defer { isPreparingWorkspace = false; finishTerminationIfNeeded() }
        let snapshot = WorkspaceData(settings: updated, generations: generations, hasCompletedGeneralSetup: true)
        let previous = stateURL; let locator = locatorRoot
        let saved = try await Task.detached(priority: .userInitiated) {
            try WorkspaceStorage.save(snapshot, previousState: previous, locatorRoot: locator)
        }.value
        let keepEnvironmentReady = environmentReady && !needsGeneralSetup && saved.settings.hasGeneralPaths && saved.settings.python == path(settings.python)
        let changedWorkspace = stateURL.standardizedFileURL.resolvingSymlinksInPath() != WorkspaceLayout(saved.settings.workingDirectory).state
        restoringModelPaths = true
        var restored = saved
        restored.recoverInterrupted()
        settings = restored.settings; generations = restored.generations
        if changedWorkspace { selectedID = nil; draftCreationID = UUID(); prompt = ""; generationSize = GenerationSize(); logs = ""; showLogs = false; clearInputImages() }
        restoreModelPaths()
        stateURL = WorkspaceLayout(settings.workingDirectory).state
        restoringModelPaths = false
        refreshModelResources()
        canPersist = true; hasCompletedGeneralSetup = saved.hasCompletedGeneralSetup; environmentReady = keepEnvironmentReady
        errorMessage = nil
        isPreparingWorkspace = false
        guard !needsGeneralSetup else { return }
        if !keepEnvironmentReady {
            checkEnvironment()
            await setupTask?.value
            guard environmentReady else { return }
        }
        showStartupSettings = false; showSettings = false
    }

    func resourceDirectory(_ resource: ModelResource) -> String {
        switch resource { case .turbo: return modelDirectory; case .t2i: return t2iDirectory; case .i2i: return i2iDirectory }
    }

    func modelPathChanged(_ resource: ModelResource) {
        guard !restoringModelPaths else { return }
        readyModelResources.remove(resource)
        modelResourceMessages.removeValue(forKey: resource)
        var updated = settings
        updated.config = ""
        let path = Self.normalizedModelPath(resourceDirectory(resource))
        switch resource {
        case .turbo: updated.model = path
        case .t2i:
            updated.promptEnhancement.t2iDirectory = path
            updated.promptEnhancement.t2iModel = ""; updated.promptEnhancement.t2iSystemPrompt = ""
        case .i2i:
            updated.promptEnhancement.i2iDirectory = path
            updated.promptEnhancement.i2iModel = ""; updated.promptEnhancement.i2iSystemPrompt = ""; updated.promptEnhancement.visionProjector = ""
        }
        settings = updated
        persist()
        if activeModelDownload != resource {
            modelDownloadMessages.removeValue(forKey: resource); modelDownloadErrors.remove(resource)
            modelDownloadProgress.removeValue(forKey: resource)
        }
        refreshModelResources()
    }

    func refreshModelResources() {
        modelResourceTask?.cancel()
        let paths = Dictionary(uniqueKeysWithValues: ModelResource.allCases.map { ($0, resourceDirectory($0)) })
        modelResourceTask = Task { [weak self] in
            let errors = await Task.detached(priority: .utility) {
                var result: [ModelResource: String] = [:]
                for resource in ModelResource.allCases {
                    do { try resource.validate(directory: Self.normalizedModelPath(paths[resource]!)) }
                    catch { result[resource] = error.localizedDescription }
                }
                return result
            }.value
            guard !Task.isCancelled, let self, ModelResource.allCases.allSatisfy({ self.resourceDirectory($0) == paths[$0] }) else { return }
            self.modelResourceMessages = errors
            self.readyModelResources = Set(ModelResource.allCases.filter { errors[$0] == nil })
        }
    }

    private func restoreModelPaths() {
        modelDirectory = settings.model
        t2iDirectory = settings.promptEnhancement.t2iDirectory; i2iDirectory = settings.promptEnhancement.i2iDirectory
    }

    private nonisolated static func normalizedModelPath(_ value: String) -> String {
        (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    func downloadModel(_ resource: ModelResource) {
        guard !busy, !needsGeneralSetup else { return }
        let downloadID = UUID(); modelDownloadID = downloadID
        activeModelDownload = resource; isPreparingResources = true
        modelDownloadErrors.remove(resource); modelDownloadMessages[resource] = L10n.english("Fetching model information…")
        modelDownloadProgress[resource] = ModelDownloadProgress()
        let python = settings.python; let layout = WorkspaceLayout(settings.workingDirectory)
        setupTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.modelDownloadID = nil; self.activeModelDownload = nil
                self.modelDownloadProgress.removeValue(forKey: resource); self.finishSetupTask()
            }
            do {
                let path = try await HuggingFaceModelDownloader.download(resource, python: python, workspace: layout, onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.modelDownloadID == downloadID,
                              progress.sequence > (self.modelDownloadProgress[resource]?.sequence ?? -1) else { return }
                        self.modelDownloadProgress[resource] = progress
                    }
                }) { [weak self] line in
                    let text = line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.modelDownloadID == downloadID else { return }
                        self.modelDownloadMessages[resource] = String(text.suffix(500))
                    }
                }
                try Task.checkCancellation()
                switch resource { case .turbo: self.modelDirectory = path; case .t2i: self.t2iDirectory = path; case .i2i: self.i2iDirectory = path }
                self.modelDownloadMessages[resource] = L10n.english("Download complete · Saved automatically")
                self.refreshModelResources()
                self.refreshEnhancementResources()
            } catch {
                if Task.isCancelled { self.modelDownloadMessages[resource] = L10n.english("Stopped · Download again to resume") }
                else { self.modelDownloadErrors.insert(resource); self.modelDownloadMessages[resource] = error.localizedDescription }
            }
        }
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
        if needsGeneralSetup { environmentMessage = L10n.english("Complete general settings first."); return }
        checkEnvironment(enterWorkspaceOnSuccess: true)
    }

    func closeGeneralSettings() {
        // A model transfer belongs to the main workspace, not the settings page.
        if activeModelDownload == nil { setupTask?.cancel() }
        showStartupSettings = false; showSettings = false
    }

    func checkEnvironment(enterWorkspaceOnSuccess: Bool = false) {
        guard !busy, terminationCompletion == nil else { return }
        guard !needsGeneralSetup else {
            environmentReady = false
            environmentMessage = L10n.english("Complete general settings first.")
            return
        }
        do {
            try settings.validateGeneralPaths()
            let layout = WorkspaceLayout(settings.workingDirectory)
            try layout.prepare()
            isChecking = true; environmentReady = false; environmentMessage = L10n.english("Checking dependencies and MPS…")
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
                    if environmentReady && enterWorkspaceOnSuccess { showStartupSettings = false }
                } catch {
                    environmentReady = false
                    environmentMessage = Task.isCancelled ? L10n.english("Environment check cancelled.") : error.localizedDescription
                }
            }
        } catch {
            isChecking = false; environmentReady = false
            environmentMessage = error.localizedDescription
        }
    }

    func generate() {
        guard !busy, !isComposingPrompt else { return }
        guard selectedModel != nil else { errorMessage = L10n.english("Choose a model first."); return }
        guard !needsGeneralSetup else { showSettings = true; return }
        guard environmentReady else { showSettings = true; return }
        do {
            try settings.validatePaths()
            try ModelResource.turbo.validate(directory: settings.model)
            if settings.promptEnhancement.enabled && (try? settings.promptEnhancement.validate(for: enhancementMode)) == nil {
                showModelPreparation()
                errorMessage = L10n.english("Configure complete enhancement model directories in model preparation, or turn off prompt enhancement.")
                return
            }
            let seed = Int64.random(in: 0...4294967295)
            let id = UUID()
            let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
            let directory = URL(fileURLWithPath: settings.outputDirectory)
                .appendingPathComponent(formatter.string(from: Date()) + "-" + id.uuidString.prefix(8))
            var runSettings = settings
            if runSettings.promptEnhancement.enabled { runSettings.promptEnhancement = try runSettings.promptEnhancement.resolvedResources(for: enhancementMode) }
            var request = try InferenceRequest(settings: runSettings, prompt: prompt, width: width, height: height,
                                               seed: seed, output: directory.appendingPathComponent("image.png").path,
                                               inputImages: inputImages, resolution: generationSize.automaticResolution)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            request.config = try QwenImage21Turbo.writeConfig(in: directory)
            request.inputImages = try InputImages.snapshot(inputImages, in: directory)
            let requestURL = directory.appendingPathComponent("request.json")
            try JSONFile.write(request, to: requestURL)
            let generation = Generation(id: id, creationID: selected?.creationID ?? draftCreationID, request: request)
            try JSONFile.write(generation, to: directory.appendingPathComponent("generation.json"))
            let logFile = try GenerationLog(directory: directory) { [weak self] message in self?.errorMessage = message }
            generations.insert(generation, at: 0)
            activeLogFile = logFile; activeLog = ""; activeID = id; selectedID = id
            startedAt = Date(); phase = generation.enhancement == nil ? L10n.english("Starting inference") : L10n.english("Starting prompt enhancement"); currentStep = 0
            appendLog(L10n.english("Task: %@\nStarted: %@\n%@\n", [String(describing: id.uuidString), String(describing: generation.createdAt.ISO8601Format()), String(describing: phase)]))
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
            if !isStopping { phase = rewriting ? L10n.english("Refining enhanced prompt") : L10n.english("Enhancing prompt") }
            appendLog((rewriting ? L10n.english("Refining enhanced prompt") : L10n.english("Enhancing prompt")) + "\n")
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
            appendLog(L10n.english("Prompt enhancement completed\n"))
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
            if !isStopping { phase = L10n.english("Generating · Step %@ / %@", [String(describing: currentStep), String(describing: totalSteps)]) }
        case "error":
            appendLog("\n" + (event["message"] as? String ?? L10n.english("Unknown error")) + "\n")
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
        appendLog("\n\(status.label)" + (message.map { ": \($0)" } ?? "") + "\n")
        saveGeneration(generations[index])
        persist()
    }

    private func saveGeneration(_ job: Generation) {
        do { try JSONFile.write(job, to: URL(fileURLWithPath: job.directory).appendingPathComponent("generation.json")) }
        catch { errorMessage = L10n.english("Unable to save task record: %@", [String(describing: error.localizedDescription)]) }
    }

    private func exited(_ code: Int32, for id: UUID) {
        guard activeID == id else { return }
        if !receivedDone {
            markFinished(id, status: isStopping ? .cancelled : .failed,
                         message: isStopping ? L10n.english("Generation stopped") : L10n.english("Inference process exited unexpectedly (%@). Check the run log.", [String(describing: code)]))
        }
        activeLogFile?.close(); activeLogFile = nil
        isRunning = false; isStopping = false; runner = nil; activeID = nil
        finishTerminationIfNeeded()
    }

    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true; phase = L10n.english("Stopping and releasing memory…"); runner?.stop()
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
        return seconds < 60 ? L10n.english("%@ s", [String(describing: seconds)]) : L10n.english("%@ min %@ s", [String(describing: seconds / 60), String(describing: seconds % 60)])
    }

    private func loadSelectedLog() {
        guard let job = logGeneration else { logs = ""; return }
        if job.id == activeID { logs = activeLog; return }
        logs = L10n.english("Reading log…")
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
