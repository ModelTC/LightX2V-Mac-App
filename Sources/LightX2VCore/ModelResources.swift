import Foundation
import Darwin

public enum ModelDownloadSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case huggingFace, modelScope
    public var id: String { rawValue }
    public var title: String { self == .huggingFace ? "Hugging Face" : "ModelScope" }
    public var executableName: String { self == .huggingFace ? "hf" : "modelscope" }
    public var linkTitle: String { self == .huggingFace ? L10n.english("Open Hugging Face") : L10n.english("Open ModelScope") }
}

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
        switch self { case .turbo: return L10n.english("Image generation model"); case .t2i: return "PE-T2I"; case .i2i: return "PE-I2I" }
    }
    public var modelName: String { repository.components(separatedBy: "/").last! }
    public var url: URL { url(source: .huggingFace) }
    public func url(source: ModelDownloadSource) -> URL {
        URL(string: (source == .huggingFace ? "https://huggingface.co/" : "https://modelscope.cn/models/") + repository)!
    }
    public func destination(in workspace: WorkspaceLayout) -> URL { workspace.root.appendingPathComponent("models/" + repository) }
    public var relativeCommand: String { relativeCommand(source: .huggingFace) }
    public func relativeCommand(source: ModelDownloadSource) -> String {
        command(destination: "./models/" + repository, source: source)
    }
    public func command(destination: String, source: ModelDownloadSource = .huggingFace) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        return source == .huggingFace
            ? "hf download " + repository + " --local-dir " + quote(destination)
            : "modelscope download --model " + quote(repository) + " --local_dir " + quote(destination)
    }

    public func validate(directory: String) throws {
        guard directory.hasPrefix("/") else { throw AppError.message(L10n.english("Choose a local directory for %@.", [String(describing: title)])) }
        if self == .turbo {
            let root = URL(fileURLWithPath: directory)
            for name in ["model_index.json", "transformer", "text_encoder", "vae", "scheduler", "processor"] {
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) else {
                    throw AppError.message(L10n.english("Image generation model is missing %@. Choose the complete Qwen-Image-2.1-Turbo directory.", [String(describing: name)]))
                }
            }
        } else { _ = try Self.enhancementFiles(in: directory, mode: self == .t2i ? .t2i : .i2i) }
    }

    public static func enhancementFiles(in directory: String, mode: PromptEnhancementMode) throws -> (model: String, system: String, projector: String?) {
        let title = mode == .t2i ? ModelResource.t2i.title : ModelResource.i2i.title
        guard directory.hasPrefix("/") else { throw AppError.message(L10n.english("Choose a local directory for the %@ model.", [String(describing: title)])) }
        let root = URL(fileURLWithPath: directory)
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        func required(_ name: String) throws -> String {
            let path = root.appendingPathComponent(name)
            let size = (try? fm.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.intValue ?? 0
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path.path, isDirectory: &isDirectory), !isDirectory.boolValue, fm.isReadableFile(atPath: path.path), size > 0 else {
                throw AppError.message(L10n.english("%@ model directory is missing %@. Download the complete repository.", [String(describing: title), String(describing: name)]))
            }
            return path.path
        }
        func pick(_ preferred: [String], matches: (String) -> Bool, label: String) throws -> String {
            if let name = preferred.first(where: { files.contains($0) }) { return try required(name) }
            let candidates = files.filter(matches).sorted()
            guard candidates.count == 1 else { throw AppError.message(L10n.english("%@ model directory %@%@. Choose the corresponding model repository directory.", [String(describing: title), String(describing: candidates.isEmpty ? L10n.english("is missing ") : L10n.english("has multiple ")), String(describing: label)])) }
            return try required(candidates[0])
        }
        let name = "Qwen-Image-2.1-PE-" + (mode == .t2i ? "T2I" : "I2I")
        let model = try pick([name + "-Q8_0.gguf"], matches: { $0.contains(name) && $0.hasSuffix("-Q8_0.gguf") && !$0.hasPrefix("mmproj") }, label: L10n.english("GGUF model"))
        let system = try required("system_prompt.txt")
        let projector = mode == .i2i ? try pick(["mmproj-" + name + "-BF16.gguf", "mmproj-" + name + "-F16.gguf"], matches: { $0.hasPrefix("mmproj") && $0.hasSuffix(".gguf") }, label: L10n.english("Vision encoder mmproj")) : nil
        return (model, system, projector)
    }
}

public enum ModelDownloader {
    public static func executable(python: String, source: ModelDownloadSource = .huggingFace) throws -> String {
        let file = URL(fileURLWithPath: python)
        for parent in [file.deletingLastPathComponent(), file.resolvingSymlinksInPath().deletingLastPathComponent()] {
            let cli = parent.appendingPathComponent(source.executableName)
            if FileManager.default.isExecutableFile(atPath: cli.path) { return cli.path }
        }
        if source == .modelScope {
            throw AppError.message(L10n.english("modelscope was not found in the selected Python environment. Run python -m pip install modelscope there, or download manually using the guide."))
        }
        throw AppError.message(L10n.english("hf was not found in the selected Python environment. Run python -m pip install -U huggingface_hub there, or download manually using the guide."))
    }

    public static func download(_ resource: ModelResource, python: String, workspace: WorkspaceLayout, source: ModelDownloadSource = .huggingFace,
                                onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void = { _ in },
                                onOutput: @escaping @Sendable (String) -> Void) async throws -> String {
        let cli = try executable(python: python, source: source)
        try workspace.prepare()
        let destination = resource.destination(in: workspace)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let updates = DownloadUpdates(source: source)
        onProgress(updates.begin(totalBytes: nil))
        // Load the same login/interactive shell configuration as Terminal, then
        // exec the selected CLI beside the configured Python. Positional
        // arguments preserve paths literally, including quotes and shell syntax.
        let shell = loginShell
        let command = source == .huggingFace
            ? [cli, "download", resource.repository, "--local-dir", destination.path]
            : [cli, "download", "--model", resource.repository, "--local_dir", destination.path]
        let exports = source == .huggingFace ? "export HF_HUB_DISABLE_PROGRESS_BARS=0; " : ""
        let arguments = ["-lic", exports + "export TQDM_POSITION=-1 TQDM_MININTERVAL=0.5; exec \"$@\"",
                         "lightx2v-" + source.executableName] + command
        let result = try await SetupCommand.run(shell, arguments: arguments,
            workspace: workspace, timeout: 86400,
            environment: ["COLUMNS": "200", "PYTHONUNBUFFERED": "1"],
            logFile: workspace.root.appendingPathComponent("logs/" + source.executableName + "-" + resource.rawValue + ".log"),
            useWorkspaceEnvironment: false) { line in
                onOutput(line)
                if let progress = updates.consume(line) { onProgress(progress) }
            }
        try Task.checkCancellation()
        let failedFiles = source == .modelScope && (updates.hasFailedFiles || result.output.contains("Failed to download ") || result.output.contains("file(s) failed to download"))
        guard result.status == 0, !failedFiles else {
            let message = source == .huggingFace ? L10n.english("HF download failed. Retry or download manually using the guide.\n")
                : L10n.english("ModelScope download failed. Retry or download manually using the guide.\n")
            throw AppError.message(message + String(result.output.suffix(1500)))
        }
        onProgress(updates.checking())
        try resource.validate(directory: destination.path)
        return destination.path
    }

    private static var loginShell: String {
        let configured = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }
        return ["/bin/zsh", "/bin/bash", "/bin/sh"].contains(configured ?? "") ? configured! : "/bin/zsh"
    }

    private final class DownloadUpdates: @unchecked Sendable {
        private let lock = NSLock()
        private var failedFiles = false
        var hasFailedFiles: Bool { lock.lock(); defer { lock.unlock() }; return failedFiles }
        private var parser: ModelDownloadProgressParser
        init(source: ModelDownloadSource) { parser = ModelDownloadProgressParser(source: source) }
        func begin(totalBytes: Double?) -> ModelDownloadProgress { lock.lock(); defer { lock.unlock() }; return parser.begin(totalBytes: totalBytes) }
        func consume(_ line: String) -> ModelDownloadProgress? {
            lock.lock(); defer { lock.unlock() }
            if line.contains("Failed to download ") || line.contains("file(s) failed to download") { failedFiles = true }
            return parser.consume(line)
        }
        func checking() -> ModelDownloadProgress { lock.lock(); defer { lock.unlock() }; return parser.checking() }
    }
}
