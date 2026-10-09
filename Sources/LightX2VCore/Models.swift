import Foundation

public struct AppSettings: Codable, Equatable {
    public var repository: String
    public var model: String
    public var config: String
    public var python: String
    public var outputDirectory: String

    public init(repository: String, model: String, config: String, python: String, outputDirectory: String) {
        self.repository = repository; self.model = model; self.config = config
        self.python = python; self.outputDirectory = outputDirectory
    }

    public static var defaults: AppSettings {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let repo = home + "/Documents/x2v/LightX2V"
        let candidates = ["/opt/miniconda3/envs/torch/bin/python", repo + "/.venv/bin/python",
                          home + "/miniforge3/envs/torch/bin/python", "/opt/homebrew/bin/python3", "/usr/bin/python3"]
        return AppSettings(repository: repo, model: home + "/Documents/x2v/models/Qwen/Qwen-Image-2.1-merged",
                           config: repo + "/configs/platforms/mps/qwen_image_21_viggle_v03.json",
                           python: candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/python3",
                           outputDirectory: home + "/Pictures/LightX2V")
    }

    public func validatePaths() throws {
        let fm = FileManager.default
        for (label, value) in [("LightX2V", repository), ("模型", model), ("配置", config), ("Python", python), ("输出目录", outputDirectory)] {
            guard value.hasPrefix("/") else { throw AppError.message("\(label)必须使用绝对路径") }
        }
        guard fm.fileExists(atPath: repository + "/lightx2v/infer.py") else { throw AppError.message("找不到 lightx2v/infer.py，请在设置中选择正确的 LightX2V 目录。") }
        guard fm.isExecutableFile(atPath: python) else { throw AppError.message("Python 不可执行，请在设置中选择现有的 Python 环境。") }
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

    public init(settings: AppSettings, prompt: String, width: Int, height: Int, seed: Int64, output: String) throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 20000 else {
            throw AppError.message("请输入 1–20000 字的提示词。")
        }
        guard ImageDimensions(width: width, height: height).isValid else {
            throw AppError.message(ImageDimensions.validationMessage)
        }
        guard (0...4294967295).contains(seed) else { throw AppError.message("种子须介于 0 和 4294967295 之间。") }
        repository = settings.repository; model = settings.model; config = settings.config
        self.prompt = prompt; self.width = width; self.height = height; self.seed = seed; self.output = output
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
    public init(settings: AppSettings = .defaults, generations: [Generation] = []) {
        self.settings = settings; self.generations = generations
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
