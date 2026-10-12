import Foundation

public enum ModelResource: String, CaseIterable, Identifiable, Sendable {
    case turbo, t2i, i2i
    public var id: String { rawValue }
    public var repository: String {
        switch self {
        case .turbo: return "Qwen/Qwen-Image-2.1-Turbo"
        case .t2i: return "lightx2v/Qwen-Image-2.1-PE-T2I-GGUF-Q8_0"
        case .i2i: return "lightx2v/Qwen-Image-2.1-PE-I2I-GGUF-Q8_0"
        }
    }
    public var title: String {
        switch self { case .turbo: return "图像生成模型"; case .t2i: return "文字增强模型"; case .i2i: return "参考图增强模型" }
    }
    public var modelName: String { repository.components(separatedBy: "/").last! }
    public var url: URL { URL(string: "https://huggingface.co/" + repository)! }
    public func destination(in workspace: WorkspaceLayout) -> URL { workspace.root.appendingPathComponent("models/" + modelName) }
    public func command(destination: String) -> String {
        "hf download " + repository + " --local-dir '" + destination.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public func validate(directory: String) throws {
        guard directory.hasPrefix("/") else { throw AppError.message("请选择\(title)的本地文件夹。") }
        if self == .turbo {
            let root = URL(fileURLWithPath: directory)
            for name in ["model_index.json", "transformer", "text_encoder", "vae", "scheduler", "processor"] {
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) else {
                    throw AppError.message("图像生成模型缺少 \(name)，请选择完整的 Qwen-Image-2.1-Turbo 文件夹。")
                }
            }
        } else { _ = try Self.enhancementFiles(in: directory, mode: self == .t2i ? .t2i : .i2i) }
    }

    public static func enhancementFiles(in directory: String, mode: PromptEnhancementMode) throws -> (model: String, system: String, projector: String?) {
        guard directory.hasPrefix("/") else { throw AppError.message("请选择\(mode.title)模型的本地文件夹。") }
        let root = URL(fileURLWithPath: directory)
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        func required(_ name: String) throws -> String {
            let path = root.appendingPathComponent(name)
            let size = (try? fm.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.intValue ?? 0
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path.path, isDirectory: &isDirectory), !isDirectory.boolValue, fm.isReadableFile(atPath: path.path), size > 0 else {
                throw AppError.message("\(mode.title)模型文件夹缺少 \(name)，请下载完整仓库。")
            }
            return path.path
        }
        func pick(_ preferred: [String], matches: (String) -> Bool, label: String) throws -> String {
            if let name = preferred.first(where: { files.contains($0) }) { return try required(name) }
            let candidates = files.filter(matches).sorted()
            guard candidates.count == 1 else { throw AppError.message("\(mode.title)模型文件夹\(candidates.isEmpty ? "缺少" : "存在多个")\(label)，请选择对应的 Q8_0 模型仓库文件夹。") }
            return try required(candidates[0])
        }
        let name = "Qwen-Image-2.1-PE-" + (mode == .t2i ? "T2I" : "I2I")
        let model = try pick([name + "-Q8_0.gguf"], matches: { $0.contains(name) && $0.hasSuffix("-Q8_0.gguf") && !$0.hasPrefix("mmproj") }, label: "GGUF 模型")
        let system = try required("system_prompt.txt")
        let projector = mode == .i2i ? try pick(["mmproj-" + name + "-BF16.gguf", "mmproj-" + name + "-F16.gguf"], matches: { $0.hasPrefix("mmproj") && $0.hasSuffix(".gguf") }, label: "视觉编码器 mmproj") : nil
        return (model, system, projector)
    }
}

public enum HuggingFaceModelDownloader {
    public static func executable(python: String) throws -> String {
        let file = URL(fileURLWithPath: python)
        for parent in [file.deletingLastPathComponent(), file.resolvingSymlinksInPath().deletingLastPathComponent()] {
            let cli = parent.appendingPathComponent("hf")
            if FileManager.default.isExecutableFile(atPath: cli.path) { return cli.path }
        }
        throw AppError.message("所选 Python 环境中找不到 hf。请先在该环境运行 python -m pip install -U huggingface_hub，或使用下方命令自行下载。")
    }

    public static func download(_ resource: ModelResource, python: String, workspace: WorkspaceLayout,
                                onOutput: @escaping @Sendable (String) -> Void) async throws -> String {
        let cli = try executable(python: python)
        try workspace.prepare()
        let destination = resource.destination(in: workspace)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let result = try await SetupCommand.run(cli, arguments: ["download", resource.repository, "--local-dir", destination.path],
            workspace: workspace, timeout: 86400, environment: ["HF_HUB_DOWNLOAD_TIMEOUT": "60", "HF_HUB_DISABLE_UPDATE_CHECK": "1"],
            logFile: workspace.root.appendingPathComponent("logs/hf-" + resource.rawValue + ".log"), onOutput: onOutput)
        try Task.checkCancellation()
        guard result.status == 0 else { throw AppError.message("HF 下载失败，可重试或按下方命令下载。\n" + String(result.output.suffix(1500))) }
        try resource.validate(directory: destination.path)
        return destination.path
    }
}
