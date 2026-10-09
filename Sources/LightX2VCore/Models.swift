import Foundation

public struct AppSettings: Codable, Equatable {
    public var repository: String
    public var model: String
    public var config: String
    public var python: String
    public var workingDirectory: String
    public var outputDirectory: String { workingDirectory.isEmpty ? "" : WorkspaceLayout(workingDirectory).outputs.path }

    public init(repository: String, model: String, config: String, python: String, workingDirectory: String = "") {
        self.repository = repository; self.model = model; self.config = config
        self.python = python; self.workingDirectory = workingDirectory
    }

    public static var defaults: AppSettings {
        AppSettings(repository: "", model: "", config: "", python: "")
    }

    private enum CodingKeys: String, CodingKey { case repository, model, config, python, workingDirectory }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(repository: try values.decode(String.self, forKey: .repository),
                  model: try values.decode(String.self, forKey: .model),
                  config: try values.decode(String.self, forKey: .config),
                  python: try values.decode(String.self, forKey: .python),
                  workingDirectory: try values.decodeIfPresent(String.self, forKey: .workingDirectory) ?? "")
    }

    public var hasGeneralPaths: Bool {
        [workingDirectory, repository, python].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public func validateGeneralPaths() throws {
        for step in GeneralSetupStep.allCases { try validateGeneralPath(step) }
    }

    public func validateGeneralPath(_ step: GeneralSetupStep) throws {
        if step == .workspace { try WorkspaceLayout.validate(workingDirectory); return }
        let fm = FileManager.default
        let (label, value) = step == .source ? ("LightX2V 源码目录", repository) : ("PyTorch 环境", python)
        guard !value.isEmpty else { throw AppError.message("请选择\(label)。") }
        guard value.hasPrefix("/") else { throw AppError.message("\(label)必须使用绝对路径。") }
        if step == .source {
            guard fm.fileExists(atPath: repository + "/lightx2v/infer.py") else {
                throw AppError.message("源码目录中找不到 lightx2v/infer.py，请选择正确的 LightX2V 目录。")
            }
            return
        }
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: python, isDirectory: &directory), !directory.boolValue,
              fm.isExecutableFile(atPath: python) else {
            throw AppError.message("请选择 PyTorch 环境中的 Python 可执行文件，例如 bin/python。")
        }
    }

    public func validatePaths() throws {
        let fm = FileManager.default
        try validateGeneralPaths()
        for (label, value) in [("模型", model), ("配置", config)] {
            guard value.hasPrefix("/") else { throw AppError.message("\(label)必须使用绝对路径") }
        }
        guard fm.fileExists(atPath: config) else { throw AppError.message("找不到 MPS 推理配置。") }
        guard fm.fileExists(atPath: model + "/model_index.json") else { throw AppError.message("模型目录缺少 model_index.json。") }
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
    public var width: Int
    public var height: Int
    public var seed: Int64
    public var output: String
    public var inputImages: [InputImage]

    public init(settings: AppSettings, prompt: String, width: Int, height: Int, seed: Int64, output: String, inputImages: [InputImage] = []) throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 20000 else {
            throw AppError.message("请输入 1–20000 字的提示词。")
        }
        guard ImageDimensions(width: width, height: height).isValid else {
            throw AppError.message(ImageDimensions.validationMessage)
        }
        guard (0...4294967295).contains(seed) else { throw AppError.message("种子须介于 0 和 4294967295 之间。") }
        try InputImages.validate(inputImages)
        repository = settings.repository; model = settings.model; config = settings.config
        self.prompt = prompt; self.width = width; self.height = height; self.seed = seed; self.output = output
        self.inputImages = inputImages
    }

    private enum CodingKeys: String, CodingKey { case repository, model, config, prompt, width, height, seed, output, inputImages }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        repository = try values.decode(String.self, forKey: .repository)
        model = try values.decode(String.self, forKey: .model)
        config = try values.decode(String.self, forKey: .config)
        prompt = try values.decode(String.self, forKey: .prompt)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        seed = try values.decode(Int64.self, forKey: .seed)
        output = try values.decode(String.self, forKey: .output)
        inputImages = try values.decodeIfPresent([InputImage].self, forKey: .inputImages) ?? []
    }
}

public enum GenerationStatus: String, Codable {
    case running, completed, failed, cancelled, interrupted
    public var label: String {
        switch self {
        case .running: return "生成中"
        case .completed: return "已完成"
        case .failed: return "生成失败"
        case .cancelled: return "已停止"
        case .interrupted: return "已中断"
        }
    }
}

public struct Generation: Codable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var request: InferenceRequest
    public var status: GenerationStatus
    public var duration: Double?
    public var error: String?
    public var directory: String { URL(fileURLWithPath: request.output).deletingLastPathComponent().path }
    public var title: String { String(request.prompt.replacingOccurrences(of: "\n", with: " ").prefix(52)) }
    public init(id: UUID = UUID(), request: InferenceRequest) {
        self.id = id; self.createdAt = Date(); self.request = request; self.status = .running
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
        // Existing installations predate the setup flag. Preserve their saved paths.
        hasCompletedGeneralSetup = try values.decodeIfPresent(Bool.self, forKey: .hasCompletedGeneralSetup) ?? settings.hasGeneralPaths
    }
    public mutating func recoverInterrupted() {
        for index in generations.indices where generations[index].status == .running {
            generations[index].status = .interrupted
            generations[index].error = "应用在上次生成完成前退出，可复用参数重新生成。"
        }
    }
}

public enum JSONFile {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
