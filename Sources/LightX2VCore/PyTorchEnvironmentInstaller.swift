import Foundation
import CryptoKit
import Darwin

public enum EnvironmentInstallStage: Int, CaseIterable, Sendable {
    case download, miniconda, python, dependencies, verify, completed
    public var title: String {
        switch self {
        case .download: return L10n.english("Download Miniconda")
        case .miniconda: return L10n.english("Install Miniconda")
        case .python: return L10n.english("Create Python 3.11 environment")
        case .dependencies: return L10n.english("Install inference dependencies")
        case .verify: return L10n.english("Check versions and MPS")
        case .completed: return L10n.english("Installation complete")
        }
    }
}

public struct EnvironmentInstallProgress: Sendable {
    public let stage: EnvironmentInstallStage
    public let detail: String
    public let fraction: Double?
    public let logLine: String?
    public init(_ stage: EnvironmentInstallStage, detail: String = "", fraction: Double? = nil, logLine: String? = nil) {
        self.stage = stage; self.detail = detail; self.fraction = fraction; self.logLine = logLine
    }
}

public struct MinicondaDistribution: Sendable {
    public let url: URL
    public let sha256: String
    public let requiresSpaceFreePrefix: Bool
    public init(url: URL, sha256: String, requiresSpaceFreePrefix: Bool = true) {
        self.url = url; self.sha256 = sha256; self.requiresSpaceFreePrefix = requiresSpaceFreePrefix
    }
    // Versioned official Apple Silicon distribution; never execute an unverified mutable 'latest' download.
    public static let official = MinicondaDistribution(
        url: URL(string: "https://repo.anaconda.com/miniconda/Miniconda3-py311_26.7.1-1-MacOSX-arm64.sh")!,
        sha256: "da6322bf9a213536df5ce630da2a249b9fb6d433f439b84be07003a790be6be6")
}

public enum PyTorchEnvironmentInstaller {
    public static let environmentName = "TorchLightX2V"
    public static func manager(in workspace: WorkspaceLayout) -> URL { workspace.root.appendingPathComponent("environments/miniconda3") }
    public static func environment(in workspace: WorkspaceLayout) -> URL { manager(in: workspace).appendingPathComponent("envs/\(environmentName)") }
    public static func executable(in workspace: WorkspaceLayout) -> URL { environment(in: workspace).appendingPathComponent("bin/python") }
    public static func installationIssue(in workspace: WorkspaceLayout) -> String? {
        guard manager(in: workspace).path.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return nil }
        // The official constructor installer explicitly rejects space-containing prefixes.
        return L10n.english("Miniconda requires a workspace path without spaces. Choose another directory or install manually.")
    }

    public static func prepareRequirements(_ source: URL, workspace: WorkspaceLayout) throws -> URL {
        try workspace.prepare()
        let data = try Data(contentsOf: source)
        guard !data.isEmpty else { throw AppError.message(L10n.english("The APP dependency file is missing. Download the APP again.")) }
        let target = workspace.root.appendingPathComponent("environments/requirements.txt")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        return target
    }

    public static func digest(_ file: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var hash = SHA256()
        while let data = try reader.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let report: @Sendable (EnvironmentInstallProgress) -> Void
        let destination: URL
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var continuation: CheckedContinuation<URL, Error>?
        private var cancelled = false
        private var fileError: Error?
        private var lastReport: TimeInterval = 0
        init(destination: URL, report: @escaping @Sendable (EnvironmentInstallProgress) -> Void) {
            self.destination = destination; self.report = report
        }
        func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<URL, Error>) {
            lock.lock(); self.task = task; self.continuation = continuation; let stop = cancelled; lock.unlock()
            if stop { task.cancel() }
            task.resume()
        }
        func cancel() {
            lock.lock(); cancelled = true; let task = task; lock.unlock()
            task?.cancel()
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message(L10n.english("Miniconda download failed. Check your network and retry.")) }
                try FileManager.default.moveItem(at: location, to: destination)
            } catch { fileError = error }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); let waiting = continuation; continuation = nil; self.task = nil; let stop = cancelled; lock.unlock()
            if stop { waiting?.resume(throwing: CancellationError()) }
            else if let error = error ?? fileError { waiting?.resume(throwing: error) }
            else { waiting?.resume(returning: destination) }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let now = Date.timeIntervalSinceReferenceDate
            guard now - lastReport > 0.25 || totalBytesWritten == totalBytesExpectedToWrite else { return }
            lastReport = now
            report(.init(.download, detail: String(format: "%.1f MB / %.1f MB", Double(totalBytesWritten) / 1_000_000,
                                                  Double(max(totalBytesWritten, totalBytesExpectedToWrite)) / 1_000_000),
                         fraction: totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil))
        }
    }

    public static func downloadInstaller(_ distribution: MinicondaDistribution = .official, workspace: WorkspaceLayout, logFile: URL? = nil,
                                         progress: @escaping @Sendable (EnvironmentInstallProgress) -> Void) async throws -> URL {
        try workspace.prepare(); try Task.checkCancellation()
        let cache = workspace.root.appendingPathComponent("cache/miniconda")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent(distribution.url.lastPathComponent)
        if let logFile {
            try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: logFile)
        }
        func log(_ message: String) throws {
            if let logFile {
                let writer = try FileHandle(forWritingTo: logFile)
                defer { try? writer.close() }
                try writer.seekToEnd(); try writer.write(contentsOf: Data((message + "\n").utf8))
            }
            progress(.init(.download, logLine: message))
        }
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        try log(L10n.english("Equivalent download command: curl -L %@ -o %@", [String(describing: quoted(distribution.url.absoluteString)), String(describing: quoted(file.path))]))
        try log(L10n.english("Download URL: %@\nDestination: %@\nExpected SHA-256: %@", [String(describing: distribution.url.absoluteString), String(describing: file.path), String(describing: distribution.sha256)]))
        if FileManager.default.fileExists(atPath: file.path), try digest(file) == distribution.sha256 {
            try log(L10n.english("Reusing downloaded Miniconda; SHA-256 verified."))
            return file
        }
        var finished = false
        defer { if !finished { try? log(L10n.english("Miniconda download incomplete or verification failed.")) } }
        progress(.init(.download, detail: L10n.english("Connecting to the official Miniconda download server…")))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 1800
        let temporary = workspace.temporary.appendingPathComponent("miniconda-\(UUID().uuidString).download")
        let observer = DownloadProgress(destination: temporary, report: progress)
        let session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                observer.start(session.downloadTask(with: distribution.url), continuation: continuation)
            }
        }, onCancel: { observer.cancel() })
        try Task.checkCancellation()
        progress(.init(.download, detail: L10n.english("Verifying download…")))
        try log(L10n.english("Download complete; verifying SHA-256…"))
        guard try digest(temporary) == distribution.sha256 else { throw AppError.message(L10n.english("Miniconda verification failed. Download it again.")) }
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try FileManager.default.moveItem(at: temporary, to: file)
        try log(L10n.english("SHA-256 verified. Miniconda saved."))
        finished = true
        return file
    }

    public static func install(workspace: WorkspaceLayout, requirements source: URL, distribution: MinicondaDistribution = .official,
                               progress: @escaping @Sendable (EnvironmentInstallProgress) -> Void) async throws -> PythonEnvironment {
        if distribution.requiresSpaceFreePrefix, let issue = installationIssue(in: workspace) { throw AppError.message(issue) }
        try workspace.prepare(); try Task.checkCancellation()
        let fm = FileManager.default
        let folder = workspace.root.appendingPathComponent("environments")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = open(folder.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw AppError.message(L10n.english("Workspace is not writable. Choose another directory.")) }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw AppError.message(L10n.english("An installation is already running in this workspace. Try again later.")) }
        let requirements = try prepareRequirements(source, workspace: workspace)
        let prefix = manager(in: workspace), env = environment(in: workspace), python = executable(in: workspace)
        let marker = folder.appendingPathComponent("miniconda-install.json")
        let envMarker = folder.appendingPathComponent("torchlightx2v-install.json")
        func owns(_ marker: URL, _ target: URL) -> Bool {
            let saved = try? JSONFile.read([String: String].self, from: marker)
            return saved?["prefix"] == target.path && saved?["installer"] == distribution.sha256
        }
        if fm.fileExists(atPath: prefix.path) && !owns(marker, prefix) {
            throw AppError.message(L10n.english("The Miniconda directory already exists and was not created by this APP. Choose another workspace to preserve it."))
        }
        if fm.fileExists(atPath: env.path) && !owns(envMarker, env) {
            throw AppError.message(L10n.english("The TorchLightX2V directory already exists and was not created by this APP. Search existing environments or choose another workspace."))
        }
        let operation = UUID().uuidString
        let logs = workspace.root.appendingPathComponent("logs/environment-\(operation)")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        var overrides = ["CONDA_PKGS_DIRS": workspace.root.appendingPathComponent("cache/conda/pkgs").path,
                         "CONDA_ENVS_PATH": prefix.appendingPathComponent("envs").path,
                         "CONDARC": folder.appendingPathComponent("condarc").path,
                         "PIP_CACHE_DIR": workspace.root.appendingPathComponent("cache/pip").path,
                         "PIP_CONFIG_FILE": "/dev/null", "PIP_INDEX_URL": "https://pypi.org/simple",
                         "PIP_DISABLE_PIP_VERSION_CHECK": "1", "PYTHONUNBUFFERED": "1"]
        overrides["CONDA_SUBDIR"] = "osx-arm64"
        try Data("channels:\n  - conda-forge\nchannel_priority: strict\nauto_activate_base: false\n".utf8)
            .write(to: URL(fileURLWithPath: overrides["CONDARC"]!), options: .atomic)
        func run(_ executable: String, _ arguments: [String], stage: EnvironmentInstallStage, timeout: TimeInterval = 3600) async throws {
            try Task.checkCancellation()
            progress(.init(stage))
            let log = logs.appendingPathComponent("\(stage.rawValue)-\(stage).log")
            let result = try await SetupCommand.run(executable, arguments: arguments, workspace: workspace, timeout: timeout,
                                                    environment: overrides, logFile: log, logCommand: true) { line in
                progress(.init(stage, logLine: line))
            }
            guard result.status == 0 else {
                let tail = result.output.components(separatedBy: .newlines).filter { !$0.isEmpty }.suffix(3).joined(separator: "\n")
                throw AppError.message(L10n.english("%@ failed (exit code %@).\n%@\nLog: %@", [String(describing: stage.title), String(describing: result.status), String(describing: tail), String(describing: log.path)]))
            }
        }
        let conda = prefix.appendingPathComponent("bin/conda")
        if !fm.isExecutableFile(atPath: conda.path) {
            let installer = try await downloadInstaller(distribution, workspace: workspace,
                logFile: logs.appendingPathComponent("0-download.log"), progress: progress)
            if fm.fileExists(atPath: prefix.path) { try fm.removeItem(at: prefix) } // Only a marked, incomplete installation reaches this branch.
            try JSONFile.write(["prefix": prefix.path, "installer": distribution.sha256], to: marker)
            try await run("/bin/bash", [installer.path, "-b", "-p", prefix.path], stage: .miniconda)
        }
        if !fm.isExecutableFile(atPath: python.path) {
            if fm.fileExists(atPath: env.path) { try fm.removeItem(at: env) }
            try JSONFile.write(["prefix": env.path, "installer": distribution.sha256], to: envMarker)
            try await run(conda.path, ["create", "--yes", "--prefix", env.path, "--no-default-packages", "--override-channels", "--channel", "conda-forge", "python=3.11", "pip"], stage: .python)
        }
        try await run(python.path, ["-I", "-B", "-m", "pip", "install", "--no-input", "--progress-bar", "off", "--no-compile", "-r", requirements.path], stage: .dependencies)
        try await run(python.path, ["-I", "-B", "-m", "pip", "check"], stage: .verify, timeout: 60)
        let checked = try await PythonEnvironmentSearch.probe(python.path, workspace: workspace,
            logFile: logs.appendingPathComponent("4-probe.log")) { line in
                progress(.init(.verify, logLine: line))
            }
        guard checked.pythonVersion.hasPrefix("3.11."), checked.isCompatible else {
            throw AppError.message(L10n.english("Installed environment failed verification: %@\nReview the logs and retry: %@", [String(describing: checked.compatibilityDetail), String(describing: logs.path)]))
        }
        try Task.checkCancellation()
        progress(.init(.completed, detail: L10n.english("TorchLightX2V is ready. Search local environments again.")))
        return checked
    }
}
