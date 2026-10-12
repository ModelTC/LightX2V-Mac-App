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
        guard directory.hasPrefix("/") else { throw AppError.message(L10n.english("Choose an absolute path to the llama.cpp binaries directory.")) }
        for name in ["llama-completion", "llama-mtmd-cli"] {
            let file = URL(fileURLWithPath: directory).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  fm.isExecutableFile(atPath: file.path) else {
                throw AppError.message(L10n.english("llama.cpp directory is missing executable %@. Choose its binaries directory or download it automatically.", [String(describing: name)]))
            }
        }
    }

    public static func validateArchive(paths: String, details: String, version: String) throws {
        let expected = "llama-\(version)"
        let entries = paths.split(separator: "\n")
        guard !entries.isEmpty, entries.allSatisfy({ entry in
            let parts = entry.split(separator: "/")
            return !entry.hasPrefix("/") && parts.first == Substring(expected) && !parts.contains("..")
        }) else { throw AppError.message(L10n.english("Invalid llama.cpp archive paths. Download it again.")) }
        for entry in details.split(separator: "\n") {
            guard let type = entry.first, ["-", "d", "l"].contains(type) else {
                throw AppError.message(L10n.english("llama.cpp archive contains invalid files. Download it again."))
            }
            if type == "l" {
                guard let range = entry.range(of: " -> ") else { throw AppError.message(L10n.english("Invalid llama.cpp shared-library link.")) }
                let target = entry[range.upperBound...]
                guard !target.isEmpty, !target.hasPrefix("/"), !target.split(separator: "/").contains("..") else {
                    throw AppError.message(L10n.english("llama.cpp shared-library link points outside its directory. Download it again."))
                }
            }
        }
    }

    public static func download(_ distribution: LlamaRuntimeDistribution = .official, workspace: WorkspaceLayout,
                                progress: @escaping @Sendable (String) -> Void) async throws -> LlamaRuntimeDownload {
        guard distribution.version.range(of: #"^b[0-9]+$"#, options: .regularExpression) != nil else {
            throw AppError.message(L10n.english("Invalid llama.cpp version."))
        }
        try workspace.prepare(); try Task.checkCancellation()
        let fm = FileManager.default
        let destination = workspace.runtimes.appendingPathComponent("llama.cpp-\(distribution.version)")
        let result = LlamaRuntimeDownload(version: distribution.version,
                                          directory: destination.path, sha256: distribution.sha256)
        if fm.fileExists(atPath: destination.path) {
            if let saved = try? JSONFile.read(LlamaRuntimeDownload.self, from: destination.appendingPathComponent(".lightx2v-llama.json")),
               saved.version == distribution.version, saved.sha256 == distribution.sha256,
               let directory = [destination.path, destination.appendingPathComponent("bin").path].first(where: {
                   (try? validateRuntime($0)) != nil
               }) {
                progress(L10n.english("Ready · %@", [String(describing: distribution.version)]))
                return LlamaRuntimeDownload(version: distribution.version, directory: directory, sha256: distribution.sha256)
            }
            throw AppError.message(L10n.english("An incomplete llama.cpp directory with the same name exists. Move it aside and retry: %@", [String(describing: destination.path)]))
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
        progress(L10n.english("Connecting to GitHub · %@…", [String(describing: distribution.version)]))
        var request = URLRequest(url: distribution.url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("LightX2V-Mac-App", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message(L10n.english("llama.cpp download failed. Check your network and retry.")) }
        var buffer = Data(); buffer.reserveCapacity(262144)
        var count = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 262144 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer); count += buffer.count; buffer.removeAll(keepingCapacity: true)
                let total = response.expectedContentLength
                progress(total > 0
                    ? String(format: L10n.english("Downloading llama.cpp · %.1f / %.1f MB"), Double(count) / 1_000_000, Double(total) / 1_000_000)
                    : String(format: L10n.english("Downloading llama.cpp · %.1f MB"), Double(count) / 1_000_000))
            }
        }
        try handle.write(contentsOf: buffer); try handle.close()
        try Task.checkCancellation()
        progress(L10n.english("Verifying and extracting llama.cpp…"))
        guard try PyTorchEnvironmentInstaller.digest(archive) == distribution.sha256 else {
            throw AppError.message(L10n.english("llama.cpp verification failed. Download it again."))
        }
        let listing = try await SetupCommand.run("/usr/bin/tar", arguments: ["-tzf", archive.path], workspace: workspace, timeout: 30)
        let details = try await SetupCommand.run("/usr/bin/tar", arguments: ["-tvzf", archive.path], workspace: workspace, timeout: 30)
        guard listing.status == 0 && details.status == 0 else { throw AppError.message(L10n.english("llama.cpp archive incomplete. Download it again.")) }
        try validateArchive(paths: listing.output, details: details.output, version: distribution.version)
        let extracted = staging.appendingPathComponent("extracted")
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        let unpacked = try await SetupCommand.run("/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", extracted.path],
                                                 workspace: workspace, timeout: 120)
        guard unpacked.status == 0 else { throw AppError.message(L10n.english("Unable to extract llama.cpp. Check disk space and retry.")) }
        let source = extracted.appendingPathComponent("llama-\(distribution.version)")
        try validateRuntime(source.path)
        let installation = staging.appendingPathComponent("installation")
        try fm.moveItem(at: source, to: installation)
        try JSONFile.write(result, to: installation.appendingPathComponent(".lightx2v-llama.json"))
        try Task.checkCancellation()
        try fm.createDirectory(at: workspace.runtimes, withIntermediateDirectories: true)
        try fm.moveItem(at: installation, to: destination)
        progress(L10n.english("Ready · %@", [String(describing: distribution.version)]))
        return result
    }
}
