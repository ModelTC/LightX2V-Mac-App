import Foundation
import Darwin

public enum PromptEnhancementMode: String, Codable {
    case t2i, i2i
    public var title: String { self == .t2i ? L10n.english("Text enhancement") : L10n.english("Reference image enhancement") }
}

/// Explicit local resources, snapshotted per run; no implicit PATH or shell.
public struct PromptEnhancementSettings: Codable, Equatable {
    public var enabled = true
    public var runtimeDirectory = ""
    public var t2iDirectory = ""
    public var i2iDirectory = ""
    public var t2iModel = ""
    public var t2iSystemPrompt = ""
    public var i2iModel = ""
    public var i2iSystemPrompt = ""
    public var visionProjector = ""
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, runtimeDirectory, t2iDirectory, i2iDirectory, t2iModel, t2iSystemPrompt, i2iModel, i2iSystemPrompt, visionProjector
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        runtimeDirectory = try values.decodeIfPresent(String.self, forKey: .runtimeDirectory) ?? ""
        t2iDirectory = try values.decodeIfPresent(String.self, forKey: .t2iDirectory) ?? ""
        i2iDirectory = try values.decodeIfPresent(String.self, forKey: .i2iDirectory) ?? ""
        t2iModel = try values.decodeIfPresent(String.self, forKey: .t2iModel) ?? ""
        t2iSystemPrompt = try values.decodeIfPresent(String.self, forKey: .t2iSystemPrompt) ?? ""
        i2iModel = try values.decodeIfPresent(String.self, forKey: .i2iModel) ?? ""
        i2iSystemPrompt = try values.decodeIfPresent(String.self, forKey: .i2iSystemPrompt) ?? ""
        visionProjector = try values.decodeIfPresent(String.self, forKey: .visionProjector) ?? ""
    }

    /// Resolve only within the selected repository. Request snapshots retain exact files.
    public func resolvedResources(for selectedMode: PromptEnhancementMode? = nil) throws -> Self {
        var value = self
        for mode in [PromptEnhancementMode.t2i, .i2i] {
            if let selectedMode, mode != selectedMode { continue }
            let directory = mode == .t2i ? t2iDirectory : i2iDirectory
            guard !directory.isEmpty else { continue }
            let files = try ModelResource.enhancementFiles(in: directory, mode: mode)
            if mode == .t2i { value.t2iModel = files.model; value.t2iSystemPrompt = files.system }
            else { value.i2iModel = files.model; value.i2iSystemPrompt = files.system; value.visionProjector = files.projector! }
        }
        return value
    }

    public func validate(for mode: PromptEnhancementMode) throws {
        let resolved = try resolvedResources(for: mode)
        let binary = runtimeDirectory + (mode == .t2i ? "/llama-completion" : "/llama-mtmd-cli")
        let files = mode == .t2i
            ? [(L10n.english("T2I model"), resolved.t2iModel), (L10n.english("T2I system prompt"), resolved.t2iSystemPrompt)]
            : [(L10n.english("I2I model"), resolved.i2iModel), (L10n.english("I2I system prompt"), resolved.i2iSystemPrompt), (L10n.english("Vision encoder"), resolved.visionProjector)]
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard binary.hasPrefix("/"), fm.fileExists(atPath: binary, isDirectory: &directory),
              !directory.boolValue, fm.isExecutableFile(atPath: binary) else {
            throw AppError.message(L10n.english("Prompt enhancement requires %@. Configure the llama.cpp binaries directory in general settings.", [String(describing: mode == .t2i ? "llama-completion" : "llama-mtmd-cli")]))
        }
        for (label, path) in files {
            var isDirectory: ObjCBool = false
            var metadata = stat()
            guard path.hasPrefix("/"), fm.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue, fm.isReadableFile(atPath: path),
                  stat(path, &metadata) == 0, metadata.st_size > 0 else {
                throw AppError.message(L10n.english("Missing %@. Choose a complete enhancement model directory in model preparation.", [String(describing: label)]))
            }
        }
    }

    /// The supplied PE scripts' layout, discovered near the selected source/model.
    /// Existing explicit selections always win.
    public mutating func discover(near paths: [String], includeRuntime: Bool = true) {
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
        if includeRuntime, runtimeDirectory.isEmpty,
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
