import Foundation

public struct LlamaRuntimeDistribution: Sendable {
    public let version: String
    public let url: URL
    public let sha256: String
    public init(version: String, url: URL, sha256: String) {
        self.version = version; self.url = url; self.sha256 = sha256
    }
    public static let official = LlamaRuntimeDistribution(
        version: "b11564",
        url: URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/b11564/llama-b11564-bin-macos-arm64.tar.gz")!,
        sha256: "fa7897448562888373f1c4d393dc860da78873e0fbc230fd17312e0e972af844")
}

public struct LlamaRuntimeDownload: Codable, Sendable {
    public let version: String
    public let directory: String
    public let sha256: String
}

public enum LlamaRuntimeDownloader {
    public static func validateRuntime(_ directory: String) throws {
        let fm = FileManager.default
        guard directory.hasPrefix("/") else { throw AppError.message("请选择 llama.cpp 运行目录（bin），并使用绝对路径。") }
        for name in ["llama-completion", "llama-mtmd-cli"] {
            let file = URL(fileURLWithPath: directory).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  fm.isExecutableFile(atPath: file.path) else {
                throw AppError.message("llama.cpp 运行目录中缺少可执行的 \(name)，请重新选择 bin 目录或自动下载。")
            }
        }
    }

    public static func validateArchive(paths: String, details: String, version: String) throws {
        let expected = "llama-\(version)"
        let entries = paths.split(separator: "\n")
        guard !entries.isEmpty, entries.allSatisfy({ entry in
            let parts = entry.split(separator: "/")
            return !entry.hasPrefix("/") && parts.first == Substring(expected) && !parts.contains("..")
        }) else { throw AppError.message("llama.cpp 压缩包目录异常，请重新下载。") }
        for entry in details.split(separator: "\n") {
            guard let type = entry.first, ["-", "d", "l"].contains(type) else {
                throw AppError.message("llama.cpp 压缩包包含异常文件，请重新下载。")
            }
            if type == "l" {
                guard let range = entry.range(of: " -> ") else { throw AppError.message("llama.cpp 动态库链接异常。") }
                let target = entry[range.upperBound...]
                guard !target.isEmpty, !target.hasPrefix("/"), !target.split(separator: "/").contains("..") else {
                    throw AppError.message("llama.cpp 动态库链接超出运行目录，请重新下载。")
                }
            }
        }
    }

    public static func download(_ distribution: LlamaRuntimeDistribution = .official, workspace: WorkspaceLayout,
                                progress: @escaping @Sendable (String) -> Void) async throws -> LlamaRuntimeDownload {
        guard distribution.version.range(of: #"^b[0-9]+$"#, options: .regularExpression) != nil else {
            throw AppError.message("llama.cpp 版本无效。")
        }
        try workspace.prepare(); try Task.checkCancellation()
        let fm = FileManager.default
        let destination = workspace.runtimes.appendingPathComponent("llama.cpp-\(distribution.version)")
        let result = LlamaRuntimeDownload(version: distribution.version,
                                          directory: destination.appendingPathComponent("bin").path, sha256: distribution.sha256)
        if fm.fileExists(atPath: destination.path) {
            if let saved = try? JSONFile.read(LlamaRuntimeDownload.self, from: destination.appendingPathComponent(".lightx2v-llama.json")),
               saved.version == distribution.version, saved.sha256 == distribution.sha256,
               (try? validateRuntime(result.directory)) != nil {
                progress("已就绪 · \(distribution.version)")
                return result
            }
            throw AppError.message("同名 llama.cpp 目录已存在但不完整，请移走后重试：\(destination.path)")
        }
        let staging = workspace.temporary.appendingPathComponent("llama-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("runtime.tar.gz")
        fm.createFile(atPath: archive.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archive)
        defer { try? handle.close() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        progress("正在连接 GitHub · \(distribution.version)…")
        var request = URLRequest(url: distribution.url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("LightX2V-Mac-App", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message("llama.cpp 下载失败，请检查网络后重试。") }
        var buffer = Data(); buffer.reserveCapacity(262144)
        var count = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 262144 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer); count += buffer.count; buffer.removeAll(keepingCapacity: true)
                let total = response.expectedContentLength
                progress(total > 0
                    ? String(format: "正在下载 llama.cpp · %.1f / %.1f MB", Double(count) / 1_000_000, Double(total) / 1_000_000)
                    : String(format: "正在下载 llama.cpp · %.1f MB", Double(count) / 1_000_000))
            }
        }
        try handle.write(contentsOf: buffer); try handle.close()
        try Task.checkCancellation()
        progress("正在校验并解压 llama.cpp…")
        guard try PyTorchEnvironmentInstaller.digest(archive) == distribution.sha256 else {
            throw AppError.message("llama.cpp 文件校验失败，请重新下载。")
        }
        let listing = try await SetupCommand.run("/usr/bin/tar", arguments: ["-tzf", archive.path], workspace: workspace, timeout: 30)
        let details = try await SetupCommand.run("/usr/bin/tar", arguments: ["-tvzf", archive.path], workspace: workspace, timeout: 30)
        guard listing.status == 0 && details.status == 0 else { throw AppError.message("llama.cpp 压缩包不完整，请重新下载。") }
        try validateArchive(paths: listing.output, details: details.output, version: distribution.version)
        let extracted = staging.appendingPathComponent("extracted")
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        let unpacked = try await SetupCommand.run("/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", extracted.path],
                                                 workspace: workspace, timeout: 120)
        guard unpacked.status == 0 else { throw AppError.message("llama.cpp 解压失败，请检查磁盘空间后重试。") }
        let source = extracted.appendingPathComponent("llama-\(distribution.version)")
        try validateRuntime(source.path)
        let installation = staging.appendingPathComponent("installation")
        try fm.createDirectory(at: installation, withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: installation.appendingPathComponent("bin"))
        try JSONFile.write(result, to: installation.appendingPathComponent(".lightx2v-llama.json"))
        try Task.checkCancellation()
        try fm.createDirectory(at: workspace.runtimes, withIntermediateDirectories: true)
        try fm.moveItem(at: installation, to: destination)
        progress("已就绪 · \(distribution.version)")
        return result
    }
}
