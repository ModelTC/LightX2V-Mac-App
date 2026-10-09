import Foundation

public struct PythonEnvironment: Identifiable, Codable, Equatable {
    public var id: String { executable }
    public let executable: String
    public var pythonVersion: String = ""
    public var torchVersion: String = ""
    public var mpsAvailable = false
    public var detail: String = ""
    public var name: String {
        let prefix = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent()
        return ["usr", "opt"].contains(prefix.lastPathComponent) ? "系统 Python" : prefix.lastPathComponent
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

    public static func probe(_ executable: String, workspace: WorkspaceLayout) async throws -> PythonEnvironment {
        var result = PythonEnvironment(executable: executable)
        let script = #"""
import json, platform
result = {"python": platform.python_version(), "torch": "", "mps": False, "detail": ""}
try:
    import torch
    result["torch"] = str(torch.__version__)
    result["mps"] = bool(hasattr(torch.backends, "mps") and torch.backends.mps.is_available())
    result["detail"] = "支持 Apple Silicon MPS" if result["mps"] else "PyTorch 已安装，但 MPS 不可用"
except Exception as error:
    result["detail"] = "未安装 PyTorch" if isinstance(error, ModuleNotFoundError) and error.name == "torch" else "PyTorch 无法加载：" + str(error)[:160]
print("LIGHTX2V_ENV:" + json.dumps(result, ensure_ascii=False))
"""#
        do {
            let output = try await SetupCommand.run(executable, arguments: ["-I", "-B", "-u", "-c", script], workspace: workspace, timeout: 20)
            guard output.status == 0,
                  let line = output.output.components(separatedBy: "\n").last(where: { $0.hasPrefix("LIGHTX2V_ENV:") }),
                  let info = try JSONSerialization.jsonObject(with: Data(line.dropFirst("LIGHTX2V_ENV:".count).utf8)) as? [String: Any] else {
                result.detail = "无法运行此 Python（退出码 \(output.status)）"; return result
            }
            result.pythonVersion = info["python"] as? String ?? ""
            result.torchVersion = info["torch"] as? String ?? ""
            result.mpsAvailable = info["mps"] as? Bool ?? false
            result.detail = info["detail"] as? String ?? "检测失败"
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
                    results.sort { lhs, rhs in lhs.mpsAvailable != rhs.mpsAvailable ? lhs.mpsAvailable : lhs.executable < rhs.executable }
                    progress(results, results.count, paths.count)
                }
            }
        }
        return results
    }
}
