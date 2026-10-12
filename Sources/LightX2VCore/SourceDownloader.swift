import Foundation

public struct SourceDownload: Codable {
    public let commit: String
    public let directory: String
}

public enum SourceDownloader {
    public static let version = "0.6.0"
    public static let revision = "94f0f19459e66f61a723db7690f1707f308599ef"
    public static let archiveURL = URL(string: "https://github.com/ModelTC/LightX2V/archive/refs/tags/0.6.0.zip")!
    public static let manualCommand = """
mkdir -p './code'
curl -L '\(archiveURL.absoluteString)' -o './code/LightX2V-\(version).zip'
unzip './code/LightX2V-\(version).zip' -d './code'
"""

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

    public static func download(workspace: WorkspaceLayout, progress: @escaping @Sendable (String) -> Void) async throws -> SourceDownload {
        try workspace.prepare()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        progress(L10n.english("Downloading LightX2V %@…", [String(describing: version)]))
        let destination = workspace.code.appendingPathComponent("LightX2V-\(version)")
        let result = SourceDownload(commit: revision, directory: destination.path)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            if let existing = try? JSONFile.read(SourceDownload.self, from: destination.appendingPathComponent(".lightx2v-source.json")),
               existing.commit == revision, fm.fileExists(atPath: destination.appendingPathComponent("lightx2v/infer.py").path) {
                progress(L10n.english("LightX2V %@ source ready", [String(describing: version)]))
                return result
            }
            throw AppError.message(L10n.english("An incomplete source directory with the same name exists. Move it aside and retry: %@", [String(describing: destination.path)]))
        }
        let staging = workspace.temporary.appendingPathComponent("source-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("source.zip")
        fm.createFile(atPath: archive.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archive)
        defer { try? handle.close() }
        let request = URLRequest(url: archiveURL)
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
        try Task.checkCancellation()
        progress(L10n.english("Extracting and verifying source…"))
        let listing = try await SetupCommand.run("/usr/bin/unzip", arguments: ["-Z1", archive.path], workspace: workspace, timeout: 30)
        guard listing.status == 0 else { throw AppError.message(L10n.english("Download archive incomplete. Download it again.")) }
        try validateArchivePaths(listing.output, commit: version)
        let extract = staging.appendingPathComponent("extracted")
        let unpack = try await SetupCommand.run("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extract.path], workspace: workspace, timeout: 120)
        guard unpack.status == 0 else { throw AppError.message(L10n.english("Unable to extract source. Check disk space and retry.")) }
        let source = extract.appendingPathComponent("LightX2V-\(version)")
        guard fm.fileExists(atPath: source.appendingPathComponent("lightx2v/infer.py").path),
              !fm.fileExists(atPath: source.appendingPathComponent(".git").path) else { throw AppError.message(L10n.english("Source verification failed. Download it again.")) }
        try Task.checkCancellation()
        try JSONFile.write(result, to: source.appendingPathComponent(".lightx2v-source.json"))
        try fm.moveItem(at: source, to: destination)
        progress(L10n.english("Downloaded LightX2V %@", [String(describing: version)]))
        return result
    }
}
