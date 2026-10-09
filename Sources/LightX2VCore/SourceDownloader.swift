import Foundation

public struct SourceDownload: Codable {
    public let commit: String
    public let directory: String
}

public enum SourceDownloader {
    public static func commit(in text: String) -> String? {
        let patterns = [#""currentOid"\s*:\s*"([a-f0-9]{40})""#, #""sha"\s*:\s*"([a-f0-9]{40})""#]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) { return String(text[range]) }
        }
        return nil
    }

    public static func validateArchivePaths(_ listing: String, commit: String) throws {
        let expected = "LightX2V-\(commit)"
        let paths = listing.split(separator: "\n").map(String.init)
        guard !paths.isEmpty, paths.allSatisfy({ path in
            let parts = path.split(separator: "/")
            return !path.hasPrefix("/") && parts.first == Substring(expected) && !parts.contains("..") && !parts.contains(".git")
        }) else { throw AppError.message("源码压缩包目录异常，请重试下载。") }
    }

    public static func download(workspace: WorkspaceLayout, progress: @escaping @Sendable (String) -> Void) async throws -> SourceDownload {
        try workspace.prepare()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        progress("正在获取 main 的最新版本…")
        var revision: String?
        for address in ["https://api.github.com/repos/ModelTC/LightX2V/commits/main", "https://github.com/ModelTC/LightX2V/tree/main"] {
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: address)!, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("LightX2V-Mac-App", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 { revision = commit(in: String(decoding: data, as: UTF8.self)) }
                if revision != nil { break }
            } catch { try Task.checkCancellation() }
        }
        guard let revision else { throw AppError.message("无法获取 GitHub main 版本，请检查网络后重试，或选择已有源码。") }
        let destination = workspace.code.appendingPathComponent("LightX2V-\(revision)")
        let result = SourceDownload(commit: revision, directory: destination.path)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            if let existing = try? JSONFile.read(SourceDownload.self, from: destination.appendingPathComponent(".lightx2v-source.json")),
               existing.commit == revision, fm.fileExists(atPath: destination.appendingPathComponent("lightx2v/infer.py").path) {
                progress("当前已是 main 最新版本 · \(revision.prefix(8))")
                return result
            }
            throw AppError.message("同名源码文件夹已存在但不完整，请移走后重试：\(destination.path)")
        }
        let staging = workspace.temporary.appendingPathComponent("source-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("source.zip")
        fm.createFile(atPath: archive.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archive)
        defer { try? handle.close() }
        let request = URLRequest(url: URL(string: "https://codeload.github.com/ModelTC/LightX2V/zip/\(revision)")!)
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message("GitHub 下载失败，请稍后重试。") }
        var buffer = Data(); buffer.reserveCapacity(262144)
        var count = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 262144 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer); count += buffer.count; buffer.removeAll(keepingCapacity: true)
                progress(String(format: "正在下载源码 · %.1f MB", Double(count) / 1_000_000))
            }
        }
        try handle.write(contentsOf: buffer)
        try Task.checkCancellation()
        progress("正在解压并校验源码…")
        let listing = try await SetupCommand.run("/usr/bin/unzip", arguments: ["-Z1", archive.path], workspace: workspace, timeout: 30)
        guard listing.status == 0 else { throw AppError.message("下载的压缩包不完整，请重试。") }
        try validateArchivePaths(listing.output, commit: revision)
        let extract = staging.appendingPathComponent("extracted")
        let unpack = try await SetupCommand.run("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extract.path], workspace: workspace, timeout: 120)
        guard unpack.status == 0 else { throw AppError.message("源码解压失败，请检查磁盘空间后重试。") }
        let source = extract.appendingPathComponent("LightX2V-\(revision)")
        guard fm.fileExists(atPath: source.appendingPathComponent("lightx2v/infer.py").path),
              !fm.fileExists(atPath: source.appendingPathComponent(".git").path) else { throw AppError.message("源码校验失败，请重新下载。") }
        try Task.checkCancellation()
        try JSONFile.write(result, to: source.appendingPathComponent(".lightx2v-source.json"))
        try fm.moveItem(at: source, to: destination)
        progress("已下载 main · \(revision.prefix(8))")
        return result
    }
}
