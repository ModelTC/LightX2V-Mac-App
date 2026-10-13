import Foundation

public struct PythonDependency: Sendable {
    public let name: String
    public let minimum: String?
    public init(_ name: String, _ minimum: String? = nil) { self.name = name; self.minimum = minimum }
}

public enum PyTorchRequirements {
    public static let dependencies = [PythonDependency("torch", "2.14.1"), PythonDependency("torchvision", "0.29.1"),
                                      PythonDependency("torchaudio", "2.11.0"), PythonDependency("transformers", "5.19.0"),
                                      PythonDependency("diffusers", "0.41.0"),
                                      PythonDependency("loguru"), PythonDependency("imageio"), PythonDependency("imageio_ffmpeg"),
                                      PythonDependency("safetensors"), PythonDependency("einops"), PythonDependency("gguf"),
                                      PythonDependency("opencv-python"), PythonDependency("prometheus_client"), PythonDependency("pydantic"),
                                      PythonDependency("huggingface_hub"), PythonDependency("modelscope")]
    public static var summary: String {
        dependencies.map { dependency in
            if let minimum = dependency.minimum { return "\(dependency.name) ≥ \(minimum)" }
            return dependency.name
        }.joined(separator: " · ")
    }

    /// Compare release components numerically, including common PEP 440 suffixes.
    /// A prerelease of the minimum itself is lower; local build tags do not affect the minimum.
    public static func meetsMinimum(_ version: String, _ minimum: String) -> Bool {
        let pattern = #"^v?([0-9]+(?:\.[0-9]+)*)(?:(?:[._-]?)(a|b|rc|alpha|beta|pre|preview)[0-9]*)?(?:[._-]?post[0-9]*)?(?:[._-]?(dev)[0-9]*)?(?:\+[a-z0-9._-]+)?$"#
        func parse(_ text: String) -> ([Int], Bool)? {
            let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            let release = text[range].split(separator: ".").compactMap { Int($0) }
            guard !release.isEmpty else { return nil }
            return (release, match.range(at: 2).location != NSNotFound || match.range(at: 3).location != NSNotFound)
        }
        guard let (actual, prerelease) = parse(version), let (required, _) = parse(minimum) else { return false }
        for index in 0..<max(actual.count, required.count) {
            let a = index < actual.count ? actual[index] : 0
            let b = index < required.count ? required[index] : 0
            if a != b { return a > b }
        }
        return !prerelease
    }
}

public struct PythonEnvironment: Identifiable, Codable, Equatable {
    public var id: String { executable }
    public let executable: String
    public var pythonVersion: String = ""
    public var torchVersion: String = ""
    public var torchvisionVersion: String = ""
    public var torchaudioVersion: String = ""
    public var transformersVersion: String = ""
    public var diffusersVersion: String = ""
    public var packageVersions: [String: String] = [:]
    public var architecture: String = ""
    public var mpsAvailable = false
    public var detail: String = ""
    public func version(of package: String) -> String {
        switch package {
        case "torch": return torchVersion
        case "torchvision": return torchvisionVersion
        case "torchaudio": return torchaudioVersion
        case "transformers": return transformersVersion
        case "diffusers": return diffusersVersion
        default: return packageVersions[package] ?? ""
        }
    }
    public var versionIssues: [String] {
        PyTorchRequirements.dependencies.compactMap { dependency in
            let current = version(of: dependency.name)
            if current.isEmpty { return L10n.english("Missing %@", [String(describing: dependency.name)]) }
            guard let minimum = dependency.minimum else { return nil }
            return PyTorchRequirements.meetsMinimum(current, minimum) ? nil : L10n.english("%@ %@; requires ≥ %@", [String(describing: dependency.name), String(describing: current), String(describing: minimum)])
        }
    }
    public var isCompatible: Bool { mpsAvailable && architecture == "arm64" && versionIssues.isEmpty }
    public var compatibilityDetail: String {
        if isCompatible { return L10n.english("Dependencies meet requirements · MPS available") }
        var issues = versionIssues
        if !architecture.isEmpty && architecture != "arm64" { issues.append(L10n.english("An Apple Silicon arm64 environment is required")) }
        if !mpsAvailable { issues.append(detail.isEmpty ? L10n.english("MPS unavailable") : detail) }
        return issues.joined(separator: "；")
    }
    public var name: String {
        let prefix = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent()
        return ["usr", "opt"].contains(prefix.lastPathComponent) ? L10n.english("System Python") : prefix.lastPathComponent
    }
    public init(executable: String) { self.executable = executable }
}

public enum PythonEnvironmentSearch {
    public static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                                  repository: String, workspace: String, selected: String) -> [String] {
        let fm = FileManager.default
        var found: [String] = []; var seen = Set<String>()
        func add(_ value: String) {
            let url = URL(fileURLWithPath: value).standardizedFileURL
            var directory: ObjCBool = false
            guard found.count < 100, fm.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue,
                  fm.isExecutableFile(atPath: url.path) else { return }
            // Resolve the bin directory, NOT the executable: distinct venvs often link to one base Python.
            let key = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            if seen.insert(key).inserted { found.append(url.path) }
        }
        func prefix(_ root: URL) {
            let bin = root.appendingPathComponent("bin")
            for name in ["python", "python3"] { add(bin.appendingPathComponent(name).path) }
            for file in children(bin) where file.lastPathComponent.range(of: #"^python3\.[0-9]+$"#, options: .regularExpression) != nil { add(file.path) }
        }
        func children(_ root: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).sorted { $0.path < $1.path }
        }
        if !selected.isEmpty { add(selected) }
        if !repository.isEmpty { for name in [".venv", "venv", ".env"] { prefix(URL(fileURLWithPath: repository).appendingPathComponent(name)) } }
        if !workspace.isEmpty {
            let root = URL(fileURLWithPath: workspace)
            for name in [".venv", "venv", "env"] { prefix(root.appendingPathComponent(name)) }
            for env in children(root.appendingPathComponent("envs")) { prefix(env) }
            let manager = PyTorchEnvironmentInstaller.manager(in: WorkspaceLayout(workspace))
            prefix(manager)
            for env in children(manager.appendingPathComponent("envs")) { prefix(env) }
        }
        for name in ["miniconda3", "anaconda3", "miniforge3", "mambaforge"] {
            for root in [home.appendingPathComponent(name), URL(fileURLWithPath: "/opt/\(name)")] {
                prefix(root)
                for env in children(root.appendingPathComponent("envs")) { prefix(env) }
            }
        }
        let registry = home.appendingPathComponent(".conda/environments.txt")
        if let text = try? String(contentsOf: registry, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("/") { prefix(URL(fileURLWithPath: String(line))) }
        }
        for directory in [".pyenv/versions", ".virtualenvs", ".local/share/virtualenvs", ".local/share/uv/python"] {
            for env in children(home.appendingPathComponent(directory)) {
                prefix(env)
                for nested in children(env.appendingPathComponent("envs")) { prefix(nested) }
            }
        }
        for root in ["/opt/homebrew/opt", "/usr/local/opt"] {
            for env in children(URL(fileURLWithPath: root)) where env.lastPathComponent.hasPrefix("python") { prefix(env) }
        }
        for env in children(URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions")) { prefix(env) }
        for name in ["miniforge", "miniconda", "anaconda"] {
            let base = URL(fileURLWithPath: "/opt/homebrew/Caskroom/\(name)/base")
            prefix(base)
            for env in children(base.appendingPathComponent("envs")) { prefix(env) }
        }
        // Bounded project scan. Never recursively search all of a home directory or model weights.
        var visited = 0
        func scan(_ root: URL, depth: Int) {
            guard depth <= 3, visited < 1500 else { return }; visited += 1
            for name in [".venv", "venv", ".env"] { prefix(root.appendingPathComponent(name)) }
            guard depth < 3 else { return }
            let ignored: Set<String> = ["node_modules", "Library", "models", "model", "outputs", "cache", "envs", "venv", "site-packages", "LightX2V-APP", "dist"]
            for child in children(root) where !ignored.contains(child.lastPathComponent) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true { scan(child, depth: depth + 1) }
            }
        }
        for name in ["Documents", "Desktop", "Developer", "Projects", "code"] { scan(home.appendingPathComponent(name), depth: 0) }
        for bin in path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] where bin.hasPrefix("/") {
            for name in ["python", "python3"] { add(URL(fileURLWithPath: bin).appendingPathComponent(name).path) }
        }
        return found
    }

    public static func probe(_ executable: String, workspace: WorkspaceLayout, logFile: URL? = nil,
                             onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws -> PythonEnvironment {
        var result = PythonEnvironment(executable: executable)
        let packages = String(decoding: try JSONEncoder().encode(PyTorchRequirements.dependencies.map(\.name)), as: UTF8.self)
        let script = #"""
import json, platform, importlib.metadata
result = {"python": platform.python_version(), "architecture": platform.machine(), "mps": False, "detail": ""}
for name in \#(packages):
    try: result[name] = importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError: result[name] = ""
try:
    import torch
    result["torch"] = str(torch.__version__)
    result["mps"] = bool(hasattr(torch.backends, "mps") and torch.backends.mps.is_available())
    result["detail"] = "Apple Silicon MPS supported" if result["mps"] else "PyTorch installed, but MPS unavailable"
except Exception as error:
    result["detail"] = "PyTorch not installed" if isinstance(error, ModuleNotFoundError) and error.name == "torch" else "Unable to load PyTorch: " + str(error)[:160]
print("LIGHTX2V_ENV:" + json.dumps(result, ensure_ascii=False))
"""#
        do {
            let output = try await SetupCommand.run(executable, arguments: ["-I", "-B", "-u", "-c", script], workspace: workspace,
                timeout: 20, logFile: logFile, logCommand: logFile != nil, onOutput: onOutput)
            guard output.status == 0,
                  let line = output.output.components(separatedBy: "\n").last(where: { $0.hasPrefix("LIGHTX2V_ENV:") }),
                  let info = try JSONSerialization.jsonObject(with: Data(line.dropFirst("LIGHTX2V_ENV:".count).utf8)) as? [String: Any] else {
                result.detail = L10n.english("Unable to run this Python (exit code %@)", [String(describing: output.status)]); return result
            }
            result.pythonVersion = info["python"] as? String ?? ""
            result.torchVersion = info["torch"] as? String ?? ""
            result.torchvisionVersion = info["torchvision"] as? String ?? ""
            result.torchaudioVersion = info["torchaudio"] as? String ?? ""
            result.transformersVersion = info["transformers"] as? String ?? ""
            result.diffusersVersion = info["diffusers"] as? String ?? ""
            result.packageVersions = Dictionary(uniqueKeysWithValues: PyTorchRequirements.dependencies.map { ($0.name, info[$0.name] as? String ?? "") })
            result.architecture = info["architecture"] as? String ?? ""
            result.mpsAvailable = info["mps"] as? Bool ?? false
            result.detail = info["detail"] as? String ?? L10n.english("Check failed")
        } catch {
            try Task.checkCancellation()
            result.detail = error.localizedDescription
        }
        return result
    }

    public static func search(workspace: WorkspaceLayout, repository: String, selected: String,
                              progress: @escaping @Sendable ([PythonEnvironment], Int, Int) -> Void) async throws -> [PythonEnvironment] {
        try workspace.prepare()
        let paths = candidates(repository: repository, workspace: workspace.root.path, selected: selected)
        var results: [PythonEnvironment] = []
        progress([], 0, paths.count)
        // Two imports at a time keeps memory use modest on a MacBook.
        for start in stride(from: 0, to: paths.count, by: 2) {
            try Task.checkCancellation()
            try await withThrowingTaskGroup(of: PythonEnvironment.self) { group in
                for path in paths[start..<min(start + 2, paths.count)] {
                    group.addTask { try await probe(path, workspace: workspace) }
                }
                for try await value in group {
                    results.append(value)
                    results.sort { lhs, rhs in lhs.isCompatible != rhs.isCompatible ? lhs.isCompatible : lhs.executable < rhs.executable }
                    progress(results, results.count, paths.count)
                }
            }
        }
        return results
    }
}
