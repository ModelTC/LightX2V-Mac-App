import Foundation

public enum QwenImage21Turbo {
    public static let title = "Qwen-Image-2.1-Turbo"
    public static let inferenceSteps = 8
    public static var bundledConfig: URL {
        Bundle.main.url(forResource: "qwen_image_21_turbo", withExtension: "json")
            ?? Bundle.module.url(forResource: "qwen_image_21_turbo", withExtension: "json")!
    }

    public static func writeConfig(in directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("config.json")
        try Data(contentsOf: bundledConfig).write(to: path, options: .atomic)
        return path.path
    }

    public static let configRelativePath = "configs/platforms/mps/qwen_image_21_turbo.json"

    public static func suggestedConfig(repository: String) -> String? {
        guard repository.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: repository).appendingPathComponent(configRelativePath).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

}
