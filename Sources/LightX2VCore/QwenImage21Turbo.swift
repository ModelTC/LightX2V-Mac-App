import Foundation

public enum QwenImage21Turbo {
    public static let title = "Qwen-Image-2.1-Turbo"
    public static let inferenceSteps = 8
    public static let configRelativePath = "configs/platforms/mps/qwen_image_21_turbo.json"

    public static func suggestedConfig(repository: String) -> String? {
        guard repository.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: repository).appendingPathComponent(configRelativePath).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Search a few conventional locations near paths explicitly selected by the user.
    /// Never scan the disk or substitute another model family.
    public static func suggestedModel(near paths: [String]) -> String? {
        var roots: [URL] = []
        for path in paths where path.hasPrefix("/") {
            var root = URL(fileURLWithPath: path).standardizedFileURL
            for _ in 0..<5 where root.path != "/" {
                if !roots.contains(root) { roots.append(root) }
                root.deleteLastPathComponent()
            }
        }
        for root in roots {
            for relative in ["models/Qwen/" + title, "models/" + title, title] {
                let candidate = root.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("model_index.json").path) {
                    return candidate.path
                }
            }
        }
        return nil
    }
}
