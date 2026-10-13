import Foundation

public struct AppSettings: Codable, Equatable {
    public var repository: String
    public var config: String
    public var python: String
    public var workingDirectory: String
    public var qwenImage21Turbo: QwenImage21TurboSettings
    public var model: String {
        get { qwenImage21Turbo.modelDirectory }
        set { qwenImage21Turbo.modelDirectory = newValue }
    }
    public var modelDownloadSource: ModelDownloadSource {
        get { qwenImage21Turbo.modelDownloadSource }
        set { qwenImage21Turbo.modelDownloadSource = newValue }
    }
    public var promptEnhancement: PromptEnhancementSettings {
        get { qwenImage21Turbo.promptEnhancement }
        set { qwenImage21Turbo.promptEnhancement = newValue }
    }
    public var outputDirectory: String { workingDirectory.isEmpty ? "" : WorkspaceLayout(workingDirectory).outputs.path }

    public init(repository: String, model: String, config: String, python: String, workingDirectory: String = "", promptEnhancement: PromptEnhancementSettings = .init(), modelDownloadSource: ModelDownloadSource = .huggingFace) {
        self.repository = repository; self.config = config
        self.python = python; self.workingDirectory = workingDirectory
        qwenImage21Turbo = .init(modelDirectory: model, modelDownloadSource: modelDownloadSource, promptEnhancement: promptEnhancement)
    }

    public static var defaults: AppSettings {
        AppSettings(repository: "", model: "", config: "", python: "")
    }

    private enum CodingKeys: String, CodingKey {
        case python, workingDirectory
        case qwenImage21Turbo = "Qwen-Image-2.1-Turbo"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        python = try values.decode(String.self, forKey: .python)
        workingDirectory = try values.decode(String.self, forKey: .workingDirectory)
        qwenImage21Turbo = try values.decode(QwenImage21TurboSettings.self, forKey: .qwenImage21Turbo)
        repository = ""; config = ""
        BundledInferenceResources.configure(&self)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(python, forKey: .python)
        try values.encode(workingDirectory, forKey: .workingDirectory)
        try values.encode(qwenImage21Turbo, forKey: .qwenImage21Turbo)
    }

    public var hasGeneralPaths: Bool {
        [workingDirectory, python].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public func validateGeneralPaths() throws {
        for step in GeneralSetupStep.allCases { try validateGeneralPath(step) }
    }

    public func validateGeneralPath(_ step: GeneralSetupStep) throws {
        if step == .workspace { try WorkspaceLayout.validate(workingDirectory); return }
        if step == .llama { try LlamaRuntimeDownloader.validateRuntime(promptEnhancement.runtimeDirectory); return }
        let fm = FileManager.default
        let (label, value) = step == .source ? (L10n.english("LightX2V source directory"), repository) : (L10n.english("PyTorch environment"), python)
        guard !value.isEmpty else { throw AppError.message(L10n.english("Choose %@.", [String(describing: label)])) }
        guard value.hasPrefix("/") else { throw AppError.message(L10n.english("%@ must use an absolute path.", [String(describing: label)])) }
        if step == .source {
            guard fm.fileExists(atPath: repository + "/lightx2v/infer.py") else {
                throw AppError.message(L10n.english("lightx2v/infer.py is missing from the source directory. Choose the correct LightX2V directory."))
            }
            return
        }
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: python, isDirectory: &directory), !directory.boolValue,
              fm.isExecutableFile(atPath: python) else {
            throw AppError.message(L10n.english("Choose the Python executable in your PyTorch environment, for example bin/python."))
        }
    }

    public func validatePaths() throws {
        let fm = FileManager.default
        try validateGeneralPaths()
        guard model.hasPrefix("/") else { throw AppError.message(L10n.english("Model directory must use an absolute path.")) }
        guard fm.fileExists(atPath: model + "/model_index.json") else { throw AppError.message(L10n.english("Model directory is missing model_index.json.")) }
    }
}

public enum AppError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

public struct InferenceRequest: Codable {
    public var repository: String
    public var model: String
    public var config: String
    public var prompt: String
    public var width: Int?
    public var height: Int?
    public var resolution: Int?
    public var seed: Int64
    public var output: String
    public var inputImages: [InputImage]
    public var promptEnhancement: PromptEnhancementSettings?

    public init(settings: AppSettings, prompt: String, width: Int?, height: Int?, seed: Int64, output: String, inputImages: [InputImage] = [], resolution: Int? = nil) throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 20000 else {
            throw AppError.message(L10n.english("Enter a prompt between 1 and 20000 characters."))
        }
        if let resolution {
            guard [512, 1024, 2048].contains(resolution), width == nil, height == nil else {
                throw AppError.message(L10n.english("Choose 512, 1K or 2K for adaptive mode; width and height are not required."))
            }
        } else {
            guard let width, let height, ImageDimensions(width: width, height: height).isValid else {
                throw AppError.message(ImageDimensions.validationMessage)
            }
        }
        guard (0...4294967295).contains(seed) else { throw AppError.message(L10n.english("Seed must be between 0 and 4294967295.")) }
        try InputImages.validate(inputImages)
        repository = settings.repository; model = settings.model; config = settings.config
        self.prompt = prompt; self.width = width; self.height = height; self.seed = seed; self.output = output
        self.inputImages = inputImages
        self.resolution = resolution
        self.promptEnhancement = settings.promptEnhancement.enabled ? settings.promptEnhancement : nil
    }

    private enum CodingKeys: String, CodingKey { case repository, model, config, prompt, width, height, resolution, seed, output, inputImages, promptEnhancement }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        repository = try values.decode(String.self, forKey: .repository)
        model = try values.decode(String.self, forKey: .model)
        config = try values.decode(String.self, forKey: .config)
        prompt = try values.decode(String.self, forKey: .prompt)
        width = try values.decodeIfPresent(Int.self, forKey: .width)
        height = try values.decodeIfPresent(Int.self, forKey: .height)
        resolution = try values.decodeIfPresent(Int.self, forKey: .resolution)
        seed = try values.decode(Int64.self, forKey: .seed)
        output = try values.decode(String.self, forKey: .output)
        inputImages = try values.decode([InputImage].self, forKey: .inputImages)
        promptEnhancement = try values.decodeIfPresent(PromptEnhancementSettings.self, forKey: .promptEnhancement)
    }
}

public enum GenerationStatus: String, Codable {
    case running, completed, failed, cancelled, interrupted
    public var label: String {
        switch self {
        case .running: return L10n.english("Generating")
        case .completed: return L10n.english("Completed")
        case .failed: return L10n.english("Generation failed")
        case .cancelled: return L10n.english("Stopped")
        case .interrupted: return L10n.english("Interrupted")
        }
    }
}

public struct Generation: Codable, Identifiable {
    public var id: UUID
    public var creationID: UUID
    public var createdAt: Date
    public var request: InferenceRequest
    public var status: GenerationStatus
    public var duration: Double?
    public var error: String?
    public var enhancement: PromptEnhancementReply?
    public var python: String = ""
    public var actualWidth: Int?
    public var actualHeight: Int?
    public var finishedAt: Date?
    public var directory: String { URL(fileURLWithPath: request.output).deletingLastPathComponent().path }
    public var title: String { String(request.prompt.replacingOccurrences(of: "\n", with: " ").prefix(52)) }
    public init(id: UUID = UUID(), creationID: UUID? = nil, request: InferenceRequest) {
        self.id = id; self.creationID = creationID ?? id
        self.createdAt = Date(); self.request = request; self.status = .running
        if request.promptEnhancement != nil { enhancement = PromptEnhancementReply(mode: request.inputImages.isEmpty ? .t2i : .i2i) }
    }
    public init(from decoder: Decoder) throws {
        self = try GenerationSnapshot(from: decoder).generation()
    }
    public func encode(to encoder: Encoder) throws {
        try GenerationSnapshot(self).encode(to: encoder)
    }

}

public struct WorkspaceData: Codable {
    public var settings: AppSettings
    public var generations: [Generation]
    public var hasCompletedGeneralSetup: Bool
    public init(settings: AppSettings = .defaults, generations: [Generation] = [], hasCompletedGeneralSetup: Bool = false) {
        self.settings = settings; self.generations = generations
        self.hasCompletedGeneralSetup = hasCompletedGeneralSetup
    }
    private enum CodingKeys: String, CodingKey { case settings, generations, hasCompletedGeneralSetup }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        settings = try values.decode(AppSettings.self, forKey: .settings)
        generations = try values.decode([Generation].self, forKey: .generations)
        hasCompletedGeneralSetup = try values.decode(Bool.self, forKey: .hasCompletedGeneralSetup)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(settings, forKey: .settings)
        try values.encode(generations, forKey: .generations)
        try values.encode(hasCompletedGeneralSetup, forKey: .hasCompletedGeneralSetup)
    }
    public mutating func recoverInterrupted() {
        for index in generations.indices where generations[index].status == .running {
            generations[index].status = .interrupted
            generations[index].error = L10n.english("The APP exited before generation finished. Reuse the settings to generate again.")
            if generations[index].enhancement?.status.isActive == true { generations[index].enhancement?.status = .interrupted }
        }
    }
}

public enum JSONFile {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try ReadableJSON.format(encoder.encode(value))
        try data.write(to: url, options: .atomic)
    }
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
