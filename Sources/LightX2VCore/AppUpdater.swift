import Foundation

public struct StableAppRelease: Equatable, Sendable {
    public let commit: String
    public let commitDate: Date
    public let assetURL: URL
    public let sha256: String
    public let size: Int64

    public init(commit: String, commitDate: Date, assetURL: URL, sha256: String, size: Int64) {
        self.commit = commit
        self.commitDate = commitDate
        self.assetURL = assetURL
        self.sha256 = sha256
        self.size = size
    }

    public func isNewer(than currentCommit: String?, commitDate currentDate: Date?) -> Bool {
        guard let currentCommit, let currentDate, currentCommit != commit,
              currentCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else { return false }
        return commitDate > currentDate
    }
}

public enum AppUpdater {
    public static let repository = "ModelTC/LightX2V-Mac-App"
    public static let assetName = "LightX2V-APP-macOS-arm64.zip"
    public static let stableDownloadURL = URL(string: "https://github.com/\(repository)/releases/download/stable/\(assetName)")!
    private static let apiRoot = "https://api.github.com/repos/\(repository)/"

    private struct Asset: Decodable {
        let name: String
        let label: String?
        let digest: String?
        let size: Int64
        let state: String
        let browser_download_url: URL
    }
    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
    private struct GitObject: Decodable {
        let sha: String
        let type: String
    }
    private struct Reference: Decodable { let object: GitObject }
    private struct Commit: Decodable {
        struct Metadata: Decodable {
            struct Person: Decodable { let date: String }
            let committer: Person
        }
        let sha: String
        let commit: Metadata
    }

    public static func fetchStableRelease(session: URLSession = .shared) async throws -> StableAppRelease {
        try Task.checkCancellation()
        let release: Release = try await fetch("releases/tags/stable", session: session)
        guard release.tag_name == "stable", !release.draft, !release.prerelease,
              let asset = release.assets.first(where: { $0.name == assetName && $0.state == "uploaded" }),
              let label = asset.label,
              let match = label.range(of: #"(?<=commit:)[0-9a-f]{40}(?=$|[;\s])"#, options: .regularExpression),
              let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw AppError.message("The Stable release is missing verified package metadata.")
        }
        let commit = String(label[match])
        let reference: Reference = try await fetch("git/ref/tags/stable", session: session)
        let tagCommit = try await resolveCommit(reference.object, session: session)
        guard tagCommit == commit else { throw AppError.message("The Stable tag does not match its package commit.") }
        let metadata: Commit = try await fetch("commits/\(commit)", session: session)
        guard metadata.sha == commit, let date = ISO8601DateFormatter().date(from: metadata.commit.committer.date) else {
            throw AppError.message("The Stable source commit has invalid version metadata.")
        }
        let result = StableAppRelease(commit: commit, commitDate: date, assetURL: asset.browser_download_url,
                                      sha256: String(digest.dropFirst(7)), size: asset.size)
        try validateRelease(result)
        return result
    }

    private static func fetch<Value: Decodable>(_ path: String, session: URLSession) async throws -> Value {
        var request = URLRequest(url: URL(string: apiRoot + path)!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 45
        request.setValue("LightX2V-Mac-App", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.message("Unable to check the Stable release. Check your network and retry.")
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func resolveCommit(_ initial: GitObject, session: URLSession) async throws -> String {
        var object = initial
        for _ in 0..<8 {
            guard object.sha.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
                throw AppError.message("The Stable tag has an invalid commit identifier.")
            }
            if object.type == "commit" { return object.sha }
            guard object.type == "tag" else { break }
            let reference: Reference = try await fetch("git/tags/\(object.sha)", session: session)
            object = reference.object
        }
        throw AppError.message("The Stable tag does not identify a source commit.")
    }

    private static func validateRelease(_ release: StableAppRelease) throws {
        guard release.assetURL == stableDownloadURL, release.size > 0,
              release.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              release.commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw AppError.message("The Stable package has an invalid download URL or checksum.")
        }
    }

    public static func validateArchivePaths(_ listing: String) throws -> String {
        let entries = listing.split(separator: "\n")
        var appRoots = Set<String>()
        let allowed = ["LightX2V.app", "LightX2V APP.app"]
        guard !entries.isEmpty else { throw AppError.message("The Stable package is empty.") }
        for entry in entries {
            let parts = entry.split(separator: "/")
            guard !entry.hasPrefix("/"), !entry.contains("\\"), !parts.contains(".."),
                  let first = parts.first else { throw AppError.message("The Stable package contains unsafe paths.") }
            if first == "__MACOSX" { continue }
            guard allowed.contains(String(first)) else { throw AppError.message("The Stable package contains unexpected files.") }
            appRoots.insert(String(first))
        }
        guard appRoots.count == 1, let root = appRoots.first else {
            throw AppError.message("The Stable package must contain one LightX2V application.")
        }
        return root
    }

    public static func validateApplication(at app: URL, workspace: WorkspaceLayout, expectedCommit: String? = nil) async throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any]
        guard app.pathExtension == "app", info?["CFBundleIdentifier"] as? String == "app.lightx2v.desktop",
              let executable = info?["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/") else {
            throw AppError.message("The Stable package does not contain a valid LightX2V application.")
        }
        if let recordedCommit = info?["LightX2VCommit"] as? String, let expectedCommit, recordedCommit != expectedCommit {
            throw AppError.message("The downloaded application does not match the Stable source commit.")
        }
        let binary = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw AppError.message("The Stable application executable is missing.") }
        let architecture = try await SetupCommand.run("/usr/bin/lipo", arguments: ["-archs", binary.path], workspace: workspace)
        guard architecture.status == 0, architecture.output.split(whereSeparator: \.isWhitespace).contains("arm64") else {
            throw AppError.message("The Stable application does not support Apple Silicon.")
        }
        let signature = try await SetupCommand.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", app.path], workspace: workspace, timeout: 60)
        guard signature.status == 0 else { throw AppError.message("The Stable application signature is invalid.") }
    }

    public static func stage(_ release: StableAppRelease, in jobDirectory: URL, session: URLSession = .shared,
                             progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        try validateRelease(release)
        try Task.checkCancellation()
        let manager = FileManager.default
        let staging = jobDirectory.appendingPathComponent("update-\(UUID().uuidString)")
        let workspace = WorkspaceLayout(staging.path)
        do {
            try workspace.prepare()
            let archive = staging.appendingPathComponent("Stable.zip")
            manager.createFile(atPath: archive.path, contents: nil)
            let file = try FileHandle(forWritingTo: archive)
            defer { try? file.close() }
            progress("Downloading Stable application…")
            var request = URLRequest(url: release.assetURL, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 120
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message("The Stable application download failed.") }
            var buffer = Data()
            buffer.reserveCapacity(262144)
            var count: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 262144 {
                    try Task.checkCancellation()
                    count += Int64(buffer.count)
                    guard count <= release.size else { throw AppError.message("The Stable download exceeded its published size.") }
                    try file.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    progress(String(format: "Downloading Stable application · %.1f / %.1f MB", Double(count) / 1_000_000, Double(release.size) / 1_000_000))
                }
            }
            try file.write(contentsOf: buffer)
            count += Int64(buffer.count)
            try file.close()
            try Task.checkCancellation()
            guard count == release.size, try PyTorchEnvironmentInstaller.digest(archive) == release.sha256 else {
                throw AppError.message("The Stable download does not match its published size and SHA-256.")
            }
            progress("Verifying Stable application…")
            let listing = try await SetupCommand.run("/usr/bin/unzip", arguments: ["-Z1", archive.path], workspace: workspace, timeout: 30)
            guard listing.status == 0 else { throw AppError.message("The Stable package is incomplete.") }
            let root = try validateArchivePaths(listing.output)
            let details = try await SetupCommand.run("/usr/bin/zipinfo", arguments: ["-l", archive.path], workspace: workspace, timeout: 30)
            guard details.status == 0, !details.output.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else {
                throw AppError.message("The Stable package contains unsupported symbolic links.")
            }
            let extracted = staging.appendingPathComponent("extracted")
            let result = try await SetupCommand.run("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path], workspace: workspace, timeout: 120)
            guard result.status == 0 else { throw AppError.message("Unable to extract the Stable application.") }
            let app = extracted.appendingPathComponent(root)
            try await validateApplication(at: app, workspace: workspace, expectedCommit: release.commit)
            try Task.checkCancellation()
            progress("Stable application is ready to install.")
            return app
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }
}
