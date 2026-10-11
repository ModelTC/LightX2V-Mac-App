import Foundation
import Darwin

public enum PromptEnhancementMode: String, Codable {
    case t2i, i2i
    public var title: String { self == .t2i ? "文字增强" : "参考图增强" }
}

/// Explicit local resources, snapshotted per run; no implicit PATH or shell.
public struct PromptEnhancementSettings: Codable, Equatable {
    public var enabled = false
    public var runtimeDirectory = ""
    public var t2iModel = ""
    public var t2iSystemPrompt = ""
    public var i2iModel = ""
    public var i2iSystemPrompt = ""
    public var visionProjector = ""
    public init() {}

    public func validate(for mode: PromptEnhancementMode) throws {
        let binary = runtimeDirectory + (mode == .t2i ? "/llama-completion" : "/llama-mtmd-cli")
        let files = mode == .t2i
            ? [("T2I 模型", t2iModel), ("T2I 系统提示词", t2iSystemPrompt)]
            : [("I2I 模型", i2iModel), ("I2I 系统提示词", i2iSystemPrompt), ("视觉编码器", visionProjector)]
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard binary.hasPrefix("/"), fm.fileExists(atPath: binary, isDirectory: &directory),
              !directory.boolValue, fm.isExecutableFile(atPath: binary) else {
            throw AppError.message("Prompt 增强需要 \(mode == .t2i ? "llama-completion" : "llama-mtmd-cli")，请配置 llama.cpp 的 bin 目录。")
        }
        for (label, path) in files {
            var isDirectory: ObjCBool = false
            var metadata = stat()
            guard path.hasPrefix("/"), fm.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue, fm.isReadableFile(atPath: path),
                  stat(path, &metadata) == 0, metadata.st_size > 0 else {
                throw AppError.message("找不到\(label)，请在 Prompt 增强设置中选择对应文件。")
            }
        }
    }

    /// The supplied PE scripts' layout, discovered near the selected source/model.
    /// Existing explicit selections always win.
    public mutating func discover(near paths: [String]) {
        let fm = FileManager.default
        var roots: [URL] = []
        for path in paths where path.hasPrefix("/") {
            var root = URL(fileURLWithPath: path).standardizedFileURL
            for _ in 0..<5 where root.path != "/" {
                if !roots.contains(root) { roots.append(root) }
                root.deleteLastPathComponent()
            }
        }
        func first(_ candidates: [String], executable: Bool = false) -> String? {
            candidates.first { path in
                var directory: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
                    && (executable ? fm.isExecutableFile(atPath: path) : fm.isReadableFile(atPath: path))
            }
        }
        if runtimeDirectory.isEmpty,
           let binary = first(roots.flatMap { root in
               [".qwen-image-pe-t2i/build/bin", ".qwen-image-pe-i2i/build/bin", "llama.cpp/build/bin", "bin"].flatMap { folder in
                   ["llama-completion", "llama-mtmd-cli"].map { root.appendingPathComponent(folder + "/" + $0).path }
               }
           }, executable: true) { runtimeDirectory = URL(fileURLWithPath: binary).deletingLastPathComponent().path }
        for mode in ["T2I", "I2I"] {
            let name = "Qwen-Image-2.1-PE-" + mode
            let model = first(roots.map { $0.appendingPathComponent("models/Qwen/\(name)-GGUF/\(name)-Q8_0.gguf").path })
            let system = first(roots.map { $0.appendingPathComponent("models/Qwen/\(name)/system_prompt.txt").path })
            if mode == "T2I" {
                if t2iModel.isEmpty { t2iModel = model ?? "" }
                if t2iSystemPrompt.isEmpty { t2iSystemPrompt = system ?? "" }
            } else {
                if i2iModel.isEmpty { i2iModel = model ?? "" }
                if i2iSystemPrompt.isEmpty { i2iSystemPrompt = system ?? "" }
                if visionProjector.isEmpty {
                    visionProjector = first(roots.map { $0.appendingPathComponent("models/Qwen/\(name)-GGUF/mmproj-\(name)-F16.gguf").path }) ?? ""
                }
            }
        }
    }
}

public enum PromptEnhancementStatus: String, Codable {
    case thinking, rewriting, completed, failed, cancelled, interrupted
    public var isActive: Bool { self == .thinking || self == .rewriting }
}

public struct PromptEnhancementReply: Codable, Equatable {
    public var mode: PromptEnhancementMode
    public var status: PromptEnhancementStatus = .thinking
    public var thinking = ""
    public var prompt: String?
    public var whRatio: String?
    public var ratioFollow: String?
    public var duration: Double?
    public init(mode: PromptEnhancementMode) { self.mode = mode }
}
