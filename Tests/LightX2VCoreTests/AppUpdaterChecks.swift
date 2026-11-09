import Foundation
import LightX2VCore

private final class UpdateResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: (Data, Int)] = [:]
    func set(_ path: String, data: Data, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        values[path] = (data, status)
    }
    func response(for path: String) -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        return values[path] ?? (Data(), 404)
    }
}

private final class UpdateProtocol: URLProtocol {
    static let responses = UpdateResponses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let (data, status) = Self.responses.response(for: url.path)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func appUpdaterChecks() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("app-updater-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: root) }
    let workspace = WorkspaceLayout(root.path)
    try workspace.prepare()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let commit = String(repeating: "a", count: 40)
    let other = String(repeating: "b", count: 40)
    let date = ISO8601DateFormatter().date(from: "2026-11-09T09:00:00Z")!
    let apiPath = "/repos/ModelTC/LightX2V-Mac-App/"
    let label = "lightx2v-run:42; commit:" + commit
    let asset: [String: Any] = ["name": AppUpdater.assetName, "label": label, "digest": "sha256:" + String(repeating: "1", count: 64),
                                "size": 123, "state": "uploaded", "browser_download_url": AppUpdater.stableDownloadURL.absoluteString]
    func installMetadata(asset value: [String: Any], tagCommit: String? = nil) throws {
        let release: [String: Any] = ["tag_name": "stable", "draft": false, "prerelease": false, "assets": [value]]
        UpdateProtocol.responses.set(apiPath + "releases/tags/stable", data: try JSONSerialization.data(withJSONObject: release))
        UpdateProtocol.responses.set(apiPath + "git/ref/tags/stable", data: try JSONSerialization.data(withJSONObject: ["object": ["sha": tagCommit ?? commit, "type": "commit"]]))
        let metadata: [String: Any] = ["sha": commit, "commit": ["committer": ["date": "2026-11-09T09:00:00Z"]]]
        UpdateProtocol.responses.set(apiPath + "commits/" + commit, data: try JSONSerialization.data(withJSONObject: metadata))
    }
    func reject(_ operation: () async throws -> Void, _ message: String) async throws {
        var failed = false
        do { try await operation() } catch { failed = true }
        try expect(failed, message)
    }
    try installMetadata(asset: asset)
    let fetched = try await AppUpdater.fetchStableRelease(session: session)
    try expect(fetched.commit == commit && fetched.commitDate == date, "Stable release source metadata was lost")
    try expect(fetched.isNewer(than: other, commitDate: date.addingTimeInterval(-1)), "newer Stable commit was not offered")
    try expect(!fetched.isNewer(than: other, commitDate: date.addingTimeInterval(1)), "older Stable commit would downgrade the current app")
    try expect(!fetched.isNewer(than: commit, commitDate: date.addingTimeInterval(-1)), "identical Stable source was offered again")
    try expect(!fetched.isNewer(than: nil, commitDate: nil), "unknown installed identity allowed an automatic downgrade")
    try expect(!fetched.isNewer(than: "", commitDate: date.addingTimeInterval(-1)), "invalid installed identity allowed an automatic downgrade")
    try installMetadata(asset: asset, tagCommit: other)
    try await reject({ _ = try await AppUpdater.fetchStableRelease(session: session) }, "mismatched Stable tag was accepted")
    var badAsset = asset
    badAsset["digest"] = "sha256:invalid"
    try installMetadata(asset: badAsset)
    try await reject({ _ = try await AppUpdater.fetchStableRelease(session: session) }, "missing Stable checksum was accepted")
    for listing in ["/tmp/outside", "LightX2V.app/../outside", "Other.app/Contents/Info.plist",
                    "LightX2V.app/a\nLightX2V APP.app/b", "LightX2V.app/Contents\\..\\outside"] {
        var rejected = false
        do { _ = try AppUpdater.validateArchivePaths(listing) } catch { rejected = true }
        try expect(rejected, "unsafe or ambiguous application archive was accepted")
    }

    for name in ["LightX2V.app", "LightX2V APP.app"] {
        let fixture = root.appendingPathComponent("fixture-" + UUID().uuidString)
        let app = fixture.appendingPathComponent(name)
        let binary = app.appendingPathComponent("Contents/MacOS/LightX2VApp")
        try manager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixtureExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        try manager.copyItem(at: fixtureExecutable, to: binary)
        let metadata: [String: Any] = ["CFBundleIdentifier": "app.lightx2v.desktop", "CFBundleExecutable": "LightX2VApp",
                                        "CFBundlePackageType": "APPL", "CFBundleName": "LightX2V", "CFBundleVersion": "1"]
        let info = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let signed = try await SetupCommand.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", app.path], workspace: workspace)
        try expect(signed.status == 0, "isolated update fixture could not be signed")
        let archive = fixture.appendingPathComponent("app.zip")
        let zipped = try await SetupCommand.run("/usr/bin/ditto", arguments: ["-c", "-k", "--keepParent", app.path, archive.path], workspace: workspace)
        try expect(zipped.status == 0, "isolated update fixture could not be archived")
        let data = try Data(contentsOf: archive)
        let digest = try PyTorchEnvironmentInstaller.digest(archive)
        let release = StableAppRelease(commit: commit, commitDate: date, assetURL: AppUpdater.stableDownloadURL,
                                       sha256: digest, size: Int64(data.count))
        UpdateProtocol.responses.set(AppUpdater.stableDownloadURL.path, data: data)
        let job = fixture.appendingPathComponent("job")
        let staged = try await AppUpdater.stage(release, in: job, session: session) { _ in }
        try expect(staged.lastPathComponent == name && manager.fileExists(atPath: staged.appendingPathComponent("Contents/MacOS/LightX2VApp").path), "verified Stable app was not staged")
        let damaged = StableAppRelease(commit: commit, commitDate: date, assetURL: AppUpdater.stableDownloadURL,
                                       sha256: String(repeating: "0", count: 64), size: Int64(data.count))
        let failedJob = fixture.appendingPathComponent("bad-checksum")
        try await reject({ _ = try await AppUpdater.stage(damaged, in: failedJob, session: session) { _ in } }, "corrupted Stable application was accepted")
        let leftovers = try manager.contentsOfDirectory(atPath: failedJob.path)
        try expect(leftovers.isEmpty, "failed update retained a partial package")
        let cancelledJob = fixture.appendingPathComponent("cancelled")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AppUpdater.stage(release, in: cancelledJob, session: session) { _ in }
        }
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true }
        try expect(cancelled && !manager.fileExists(atPath: cancelledJob.path), "cancelled update created a partial installation")
        let copiedInfo = staged.appendingPathComponent("Contents/Info.plist")
        var altered = metadata
        altered["CFBundleIdentifier"] = "example.unrelated"
        try PropertyListSerialization.data(fromPropertyList: altered, format: .xml, options: 0).write(to: copiedInfo)
        try await reject({ try await AppUpdater.validateApplication(at: staged, workspace: workspace) }, "unrelated application bundle was accepted")
    }
    print("PASS Stable identity, downgrade prevention, verified current/legacy app staging, checksum rejection and cancellation")
}
