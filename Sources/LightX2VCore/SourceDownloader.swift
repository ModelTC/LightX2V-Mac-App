import Foundation

public struct SourceDownload: Codable {
    public let commit: String
    public let directory: String
}

public enum SourceDownloader {
    public static let version = BundledInferenceResources.sourceRevision
    public static let revision = BundledInferenceResources.sourceRevision
    public static var archiveURL: URL { get throws { try distribution().url } }
    public static var manualCommand: String {
        get throws {
            let source = try distribution()
            let archive = "./code/LightX2V-\(version).tar.gz"
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
            let removed = (source.prune ?? []).map { quote("./code/\(BundledInferenceResources.sourceRoot)/\($0)") }.joined(separator: " ")
            return """
mkdir -p './code' &&
curl -fL '\(source.url.absoluteString)' -o '\(archive)' &&
printf '%s  %s\\n' '\(source.sha256)' '\(archive)' | shasum -a 256 -c - &&
tar -xzf '\(archive)' -C './code' &&
rm -rf \(removed)
"""
        }
    }

    private static func distribution() throws -> BundledInferenceResources.Archive {
        let manifest = try BundledInferenceResources.manifest()
        guard let source = manifest[BundledInferenceResources.sourceArchive] else {
            throw AppError.message("Bundled inference manifest is missing the pinned LightX2V source.")
        }
        return source
    }

    static func isComplete(_ source: URL) -> Bool {
        let fm = FileManager.default
        return ["lightx2v/infer.py", "lightx2v_kernel/apple/python/lightx2v_kernel_apple/int8_gemm/gemm.py",
                "lightx2v_kernel/apple/pyproject.toml", "configs/platforms/mps/qwen_image_21_turbo_int8.json"].allSatisfy { name in
            var isDirectory: ObjCBool = false
            let path = source.appendingPathComponent(name).path
            return fm.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue && fm.isReadableFile(atPath: path)
        } && !fm.fileExists(atPath: source.appendingPathComponent(".git").path)
    }

    static func prune(_ source: URL, directories: [String]) throws {
        let fm = FileManager.default
        for name in directories {
            let path = source.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) || (try? fm.destinationOfSymbolicLink(atPath: path.path)) != nil {
                try fm.removeItem(at: path)
            }
        }
    }

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
        }) else { throw AppError.message(L10n.english("Invalid source archive paths. Download it again.")) }
    }

    public static func download(workspace: WorkspaceLayout, destination requestedDestination: URL? = nil,
                                archiveURL: URL? = nil,
                                progress: @escaping @Sendable (String) -> Void) async throws -> SourceDownload {
        try Task.checkCancellation()
        let sourceDistribution = try distribution()
        try workspace.prepare()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        progress(L10n.english("Downloading LightX2V %@…", [String(describing: version)]))
        let destination = requestedDestination ?? workspace.code.appendingPathComponent("LightX2V-\(version)")
        let result = SourceDownload(commit: revision, directory: destination.path)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            if let existing = try? JSONFile.read(SourceDownload.self, from: destination.appendingPathComponent(".lightx2v-source.json")),
               existing.commit == revision, isComplete(destination) {
                try Task.checkCancellation()
                try prune(destination, directories: sourceDistribution.prune ?? [])
                progress(L10n.english("LightX2V %@ source ready", [String(describing: version)]))
                return result
            }
            throw AppError.message(L10n.english("An incomplete source directory with the same name exists. Move it aside and retry: %@", [String(describing: destination.path)]))
        }
        let staging = workspace.temporary.appendingPathComponent("source-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("source.tar.gz")
        fm.createFile(atPath: archive.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archive)
        defer { try? handle.close() }
        let request = URLRequest(url: archiveURL ?? sourceDistribution.url)
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message(L10n.english("GitHub download failed. Try again later.")) }
        var buffer = Data(); buffer.reserveCapacity(262144)
        var count = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 262144 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer); count += buffer.count; buffer.removeAll(keepingCapacity: true)
                progress(String(format: L10n.english("Downloading source · %.1f MB"), Double(count) / 1_000_000))
            }
        }
        try handle.write(contentsOf: buffer)
        try handle.close()
        try Task.checkCancellation()
        progress(L10n.english("Extracting and verifying source…"))
        guard try PyTorchEnvironmentInstaller.digest(archive) == sourceDistribution.sha256 else {
            throw AppError.message("LightX2V source archive checksum failed. Download it again.")
        }
        let listing = try await SetupCommand.run("/usr/bin/tar", arguments: ["-tzf", archive.path], workspace: workspace, timeout: 30)
        let details = try await SetupCommand.run("/usr/bin/tar", arguments: ["-tvzf", archive.path], workspace: workspace, timeout: 30)
        guard listing.status == 0, details.status == 0 else { throw AppError.message(L10n.english("Download archive incomplete. Download it again.")) }
        try validateArchivePaths(listing.output, commit: version)
        try LlamaRuntimeDownloader.validateArchive(paths: listing.output, details: details.output, version: version, expectedRoot: BundledInferenceResources.sourceRoot)
        let extract = staging.appendingPathComponent("extracted")
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)
        let unpack = try await SetupCommand.run("/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", extract.path], workspace: workspace, timeout: 120)
        guard unpack.status == 0 else { throw AppError.message(L10n.english("Unable to extract source. Check disk space and retry.")) }
        let source = extract.appendingPathComponent("LightX2V-\(version)")
        try Task.checkCancellation()
        try prune(source, directories: sourceDistribution.prune ?? [])
        guard isComplete(source) else { throw AppError.message(L10n.english("Source verification failed. Download it again.")) }
        try JSONFile.write(result, to: source.appendingPathComponent(".lightx2v-source.json"))
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try fm.moveItem(at: source, to: destination)
        progress(L10n.english("Downloaded LightX2V %@", [String(describing: version)]))
        return result
    }
}
