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
        switch self { case .turbo: return "图像生成模型"; case .t2i: return "PE-T2I"; case .i2i: return "PE-I2I" }
    }
    public var modelName: String { repository.components(separatedBy: "/").last! }
    public var url: URL { URL(string: "https://huggingface.co/" + repository)! }
    public func destination(in workspace: WorkspaceLayout) -> URL { workspace.root.appendingPathComponent("models/" + repository) }
    public var relativeCommand: String { command(destination: "./models/" + repository) }
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
        let title = mode == .t2i ? ModelResource.t2i.title : ModelResource.i2i.title
        guard directory.hasPrefix("/") else { throw AppError.message("请选择 \(title) 模型的本地文件夹。") }
        let root = URL(fileURLWithPath: directory)
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        func required(_ name: String) throws -> String {
            let path = root.appendingPathComponent(name)
            let size = (try? fm.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.intValue ?? 0
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path.path, isDirectory: &isDirectory), !isDirectory.boolValue, fm.isReadableFile(atPath: path.path), size > 0 else {
                throw AppError.message("\(title) 模型文件夹缺少 \(name)，请下载完整仓库。")
            }
            return path.path
        }
        func pick(_ preferred: [String], matches: (String) -> Bool, label: String) throws -> String {
            if let name = preferred.first(where: { files.contains($0) }) { return try required(name) }
            let candidates = files.filter(matches).sorted()
            guard candidates.count == 1 else { throw AppError.message("\(title) 模型文件夹\(candidates.isEmpty ? "缺少" : "存在多个")\(label)，请选择对应的模型仓库文件夹。") }
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
        throw AppError.message("所选 Python 环境中找不到 hf。请先在该环境运行 python -m pip install -U huggingface_hub，或按下载指南自行下载。")
    }

    public static func download(_ resource: ModelResource, python: String, workspace: WorkspaceLayout,
                                onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void = { _ in },
                                onOutput: @escaping @Sendable (String) -> Void) async throws -> String {
        let cli = try executable(python: python)
        try workspace.prepare()
        let destination = resource.destination(in: workspace)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // Resolve the byte total before concurrent workers start. Reading only
        // metadata never downloads weights and reuses the same HF local cache.
        var metadata: DownloadMetadata?
        do {
            let result = try await SetupCommand.run(python, arguments: ["-u", "-c", metadataScript, resource.repository, destination.path],
                workspace: workspace, timeout: 60,
                environment: ["HF_HUB_DISABLE_PROGRESS_BARS": "1", "HF_HUB_DISABLE_UPDATE_CHECK": "1"],
                logFile: workspace.root.appendingPathComponent("logs/hf-" + resource.rawValue + "-metadata.log"))
            if result.status == 0, let marker = result.output.range(of: "LIGHTX2V_DOWNLOAD_METADATA:"),
               let json = result.output[marker.upperBound...].split(whereSeparator: \.isNewline).first,
               let data = String(json).data(using: .utf8) {
                metadata = try? JSONDecoder().decode(DownloadMetadata.self, from: data)
            }
        } catch { try Task.checkCancellation() }
        try Task.checkCancellation()
        let updates = DownloadUpdates()
        onProgress(updates.begin(totalBytes: metadata?.totalBytes))
        var arguments = ["download", resource.repository, "--local-dir", destination.path]
        if let revision = metadata?.revision, revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil {
            arguments += ["--revision", revision]
        }
        let result = try await SetupCommand.run(cli, arguments: arguments,
            workspace: workspace, timeout: 86400,
            environment: ["HF_HUB_DOWNLOAD_TIMEOUT": "60", "HF_HUB_DISABLE_UPDATE_CHECK": "1",
                          "HF_HUB_DISABLE_PROGRESS_BARS": "0", "TQDM_POSITION": "-1", "TQDM_MININTERVAL": "0.5", "COLUMNS": "200"],
            logFile: workspace.root.appendingPathComponent("logs/hf-" + resource.rawValue + ".log")) { line in
                onOutput(line)
                if let progress = updates.consume(line) { onProgress(progress) }
            }
        try Task.checkCancellation()
        guard result.status == 0 else { throw AppError.message("HF 下载失败，可重试或按下载指南自行下载。\n" + String(result.output.suffix(1500))) }
        onProgress(updates.checking())
        try resource.validate(directory: destination.path)
        return destination.path
    }

    private struct DownloadMetadata: Decodable {
        let totalBytes: Double?
        let revision: String?
    }

    private static let metadataScript = #"""
import json, sys
from huggingface_hub import snapshot_download
files = snapshot_download(sys.argv[1], local_dir=sys.argv[2], dry_run=True)
pending = [item for item in files if item.will_download]
total = None if any(item.file_size is None for item in pending) else sum(item.file_size for item in pending)
revisions = {item.commit_hash for item in files}
print("LIGHTX2V_DOWNLOAD_METADATA:" + json.dumps({"totalBytes": total, "revision": next(iter(revisions)) if len(revisions) == 1 else None}), flush=True)
"""#

    private final class DownloadUpdates: @unchecked Sendable {
        private let lock = NSLock()
        private var parser = ModelDownloadProgressParser()
        func begin(totalBytes: Double?) -> ModelDownloadProgress { lock.lock(); defer { lock.unlock() }; return parser.begin(totalBytes: totalBytes) }
        func consume(_ line: String) -> ModelDownloadProgress? { lock.lock(); defer { lock.unlock() }; return parser.consume(line) }
        func checking() -> ModelDownloadProgress { lock.lock(); defer { lock.unlock() }; return parser.checking() }
    }
}
