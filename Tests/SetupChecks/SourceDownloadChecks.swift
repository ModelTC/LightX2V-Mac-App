import Foundation
import LightX2VCore

private final class SourceDownloadUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func append(_ text: String) { lock.lock(); messages.append(text); lock.unlock() }
    var hasBytes: Bool { lock.lock(); defer { lock.unlock() }; return messages.contains { $0.contains("MB") } }
}

extension SetupChecks {
    static func sourceDownloadChecks(_ root: URL) async throws {
        let fm = FileManager.default
        guard let archivePath = ProcessInfo.processInfo.environment["LIGHTX2V_TEST_SOURCE_ARCHIVE"],
              fm.isReadableFile(atPath: archivePath) else {
            throw Failure(message: "Set LIGHTX2V_TEST_SOURCE_ARCHIVE to the original pinned LightX2V 0.6.1 tar.gz before running SetupChecks. The fixture is served locally and must match Bundled/manifest.json.")
        }
        let serverWorkspace = WorkspaceLayout(root.appendingPathComponent("source-server").path)
        try serverWorkspace.prepare()
        let portFile = serverWorkspace.root.appendingPathComponent("port")
        let script = #"""
import http.server, pathlib, sys, time
payload = pathlib.Path(sys.argv[2]).read_bytes()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path not in ('/source.tar.gz', '/slow.tar.gz', '/corrupt.tar.gz'):
            self.send_error(404)
            return
        content = payload + b'corrupted archive' if self.path == '/corrupt.tar.gz' else payload
        self.send_response(200)
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        try:
            for offset in range(0, len(content), 4096):
                self.wfile.write(content[offset:offset + 4096])
                self.wfile.flush()
                if self.path == '/slow.tar.gz': time.sleep(.02)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
"""#
        let server = Task {
            try await SetupCommand.run("/usr/bin/python3", arguments: ["-I", "-B", "-u", "-c", script,
                                       portFile.path, archivePath],
                                       workspace: serverWorkspace, timeout: 120)
        }
        defer { server.cancel() }
        for _ in 0..<200 where !fm.fileExists(atPath: portFile.path) { try await Task.sleep(for: .milliseconds(25)) }
        try expect(fm.fileExists(atPath: portFile.path), "source download server did not start")
        let port = try String(contentsOf: portFile, encoding: .utf8)
        func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path).tar.gz")! }

        struct ArchivePolicy: Decodable { let prune: [String]? }
        let policies = try JSONDecoder().decode([String: ArchivePolicy].self,
            from: Data(contentsOf: BundledInferenceResources.resource("manifest.json")))
        let prunedDirectories = policies[BundledInferenceResources.sourceArchive]?.prune ?? []
        try expect(prunedDirectories.contains("lightx2v_rl"), "source manifest must remove training resources")

        let workspace = WorkspaceLayout(root.appendingPathComponent("source download 中文 spaces").path)
        let updates = SourceDownloadUpdates()
        let downloaded = try await SourceDownloader.download(workspace: workspace, archiveURL: url("source")) { updates.append($0) }
        let source = URL(fileURLWithPath: downloaded.directory)
        let training = source.appendingPathComponent("lightx2v_rl")
        try expect(source == workspace.code.appendingPathComponent(BundledInferenceResources.sourceRoot), "default source installation moved outside workspace code")
        try expect(updates.hasBytes, "source download did not report byte progress")
        try expect(fm.fileExists(atPath: source.appendingPathComponent("lightx2v/infer.py").path), "source download missing inference entry")
        for name in prunedDirectories {
            try expect(!fm.fileExists(atPath: source.appendingPathComponent(name).path), "fresh source download retained pruned directory " + name)
        }
        let original = try Data(contentsOf: source.appendingPathComponent("lightx2v/infer.py"))
        for name in prunedDirectories {
            let directory = source.appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("cached resource".utf8).write(to: directory.appendingPathComponent("sentinel"))
        }
        // Earlier ZIP installations stored only these two fields.
        try JSONFile.write(["commit": SourceDownloader.revision, "directory": source.path], to: source.appendingPathComponent(".lightx2v-source.json"))
        let sentinel = source.appendingPathComponent("preserve-sentinel")
        try Data("preserve".utf8).write(to: sentinel)
        let reused = try await SourceDownloader.download(workspace: workspace, archiveURL: url("missing")) { _ in }
        try expect(reused.directory == downloaded.directory && !fm.fileExists(atPath: training.path), "verified source cache was not reused and cleaned without a download")
        for name in prunedDirectories {
            try expect(!fm.fileExists(atPath: source.appendingPathComponent(name).path), "legacy source cache retained pruned directory " + name)
        }
        let retained = try Data(contentsOf: source.appendingPathComponent("lightx2v/infer.py"))
        try expect(retained == original && fm.fileExists(atPath: sentinel.path), "cache cleanup changed inference or user files")

        try fm.createDirectory(at: training, withIntermediateDirectories: true)
        let cancelledCleanup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SourceDownloader.download(workspace: workspace, archiveURL: url("missing")) { _ in }
        }
        var cleanupStopped = false
        do { _ = try await cancelledCleanup.value } catch is CancellationError { cleanupStopped = true }
        try expect(cleanupStopped && fm.fileExists(atPath: training.path), "cancelled cache reuse changed the installed source")

        let customWorkspace = WorkspaceLayout(root.appendingPathComponent("source custom destination").path)
        let custom = customWorkspace.runtimes.appendingPathComponent("staged/resources/" + BundledInferenceResources.sourceRoot)
        let installed = try await SourceDownloader.download(workspace: customWorkspace, destination: custom, archiveURL: url("source")) { _ in }
        try expect(installed.directory == custom.path && fm.fileExists(atPath: custom.appendingPathComponent("lightx2v/infer.py").path), "custom source destination was not installed")
        try expect(!fm.fileExists(atPath: customWorkspace.code.appendingPathComponent(BundledInferenceResources.sourceRoot).path), "custom source download populated an unused default installation")

        let retryWorkspace = WorkspaceLayout(root.appendingPathComponent("source HTTP retry").path)
        var failed = false
        do { _ = try await SourceDownloader.download(workspace: retryWorkspace, archiveURL: url("missing")) { _ in } }
        catch { failed = true }
        let failedTemporary = try fm.contentsOfDirectory(atPath: retryWorkspace.temporary.path)
        try expect(failed && failedTemporary.isEmpty && !fm.fileExists(atPath: retryWorkspace.code.appendingPathComponent(BundledInferenceResources.sourceRoot).path), "HTTP failure retained a partial source installation")
        let retried = try await SourceDownloader.download(workspace: retryWorkspace, archiveURL: url("source")) { _ in }
        try expect(fm.fileExists(atPath: retried.directory + "/lightx2v/infer.py"), "source download could not retry after HTTP failure")

        let corruptWorkspace = WorkspaceLayout(root.appendingPathComponent("source checksum failure").path)
        var checksumFailed = false
        do { _ = try await SourceDownloader.download(workspace: corruptWorkspace, archiveURL: url("corrupt")) { _ in } }
        catch { checksumFailed = error.localizedDescription.contains("checksum") }
        let corruptTemporary = try fm.contentsOfDirectory(atPath: corruptWorkspace.temporary.path)
        try expect(checksumFailed && corruptTemporary.isEmpty && !fm.fileExists(atPath: corruptWorkspace.code.appendingPathComponent(BundledInferenceResources.sourceRoot).path), "checksum failure was accepted or left a partial source installation")

        let cancelledWorkspace = WorkspaceLayout(root.appendingPathComponent("source download cancelled").path)
        let slow = SourceDownloadUpdates()
        let downloading = Task {
            try await SourceDownloader.download(workspace: cancelledWorkspace, archiveURL: url("slow")) { slow.append($0) }
        }
        defer { downloading.cancel() }
        for _ in 0..<200 where !slow.hasBytes { try await Task.sleep(for: .milliseconds(25)) }
        try expect(slow.hasBytes, "slow source download did not start")
        downloading.cancel()
        var stopped = false
        do { _ = try await downloading.value } catch { stopped = true }
        let cancelledTemporary = try fm.contentsOfDirectory(atPath: cancelledWorkspace.temporary.path)
        try expect(stopped && cancelledTemporary.isEmpty && !fm.fileExists(atPath: cancelledWorkspace.code.appendingPathComponent(BundledInferenceResources.sourceRoot).path), "cancelled source download retained a partial installation")
        _ = try await SourceDownloader.download(workspace: cancelledWorkspace, archiveURL: url("source")) { _ in }

        for name in ["unowned", "incomplete"] {
            let collision = WorkspaceLayout(root.appendingPathComponent("source collision " + name).path)
            try collision.prepare()
            let existing = collision.code.appendingPathComponent(BundledInferenceResources.sourceRoot)
            let protected = existing.appendingPathComponent("lightx2v_rl/preserve-sentinel")
            try fm.createDirectory(at: protected.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("protected".utf8).write(to: protected)
            try fm.createDirectory(at: existing.appendingPathComponent("lightx2v"), withIntermediateDirectories: true)
            try original.write(to: existing.appendingPathComponent("lightx2v/infer.py"))
            if name == "incomplete" {
                try JSONFile.write(["commit": SourceDownloader.revision, "directory": existing.path], to: existing.appendingPathComponent(".lightx2v-source.json"))
            }
            var rejected = false
            do { _ = try await SourceDownloader.download(workspace: collision, archiveURL: url("source")) { _ in } }
            catch { rejected = true }
            let protectedBytes = try Data(contentsOf: protected)
            try expect(rejected && protectedBytes == Data("protected".utf8), "source collision was overwritten or pruned")
        }
        server.cancel()
        _ = try? await server.value
    }
}
