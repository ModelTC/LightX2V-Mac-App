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
        let serverWorkspace = WorkspaceLayout(root.appendingPathComponent("source-server").path)
        try serverWorkspace.prepare()
        let portFile = serverWorkspace.root.appendingPathComponent("port")
        let script = #"""
import http.server, pathlib, random, sys, time, zipfile
root = pathlib.Path(sys.argv[1])
archive = root / 'source.zip'
with zipfile.ZipFile(archive, 'w') as output:
    prefix = sys.argv[3] + '/'
    for name in ('lightx2v/infer.py', 'lightx2v_kernel/apple/python/lightx2v_kernel_apple/int8_gemm/gemm.py',
                 'lightx2v_kernel/apple/pyproject.toml', 'configs/platforms/mps/qwen_image_21_turbo_int8.json',
                 'lightx2v_rl/scripts/train.py'):
        output.writestr(prefix + name, 'source fixture\n')
    output.writestr(prefix + 'lightx2v/payload.bin', random.Random(42).randbytes(1048576))
payload = archive.read_bytes()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path not in ('/source.zip', '/slow.zip'):
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        try:
            for offset in range(0, len(payload), 4096):
                self.wfile.write(payload[offset:offset + 4096])
                self.wfile.flush()
                if self.path == '/slow.zip': time.sleep(.02)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()
"""#
        let server = Task {
            try await SetupCommand.run("/usr/bin/python3", arguments: ["-I", "-B", "-u", "-c", script,
                                       serverWorkspace.root.path, portFile.path, BundledInferenceResources.sourceRoot],
                                       workspace: serverWorkspace, timeout: 60)
        }
        defer { server.cancel() }
        for _ in 0..<200 where !fm.fileExists(atPath: portFile.path) { try await Task.sleep(for: .milliseconds(25)) }
        try expect(fm.fileExists(atPath: portFile.path), "source download server did not start")
        let port = try String(contentsOf: portFile, encoding: .utf8)
        func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path).zip")! }

        let workspace = WorkspaceLayout(root.appendingPathComponent("source download 中文 spaces").path)
        let updates = SourceDownloadUpdates()
        let downloaded = try await SourceDownloader.download(workspace: workspace, archiveURL: url("source")) { updates.append($0) }
        let source = URL(fileURLWithPath: downloaded.directory)
        let training = source.appendingPathComponent("lightx2v_rl")
        try expect(source == workspace.code.appendingPathComponent(BundledInferenceResources.sourceRoot), "default source installation moved outside workspace code")
        try expect(updates.hasBytes, "source download did not report byte progress")
        try expect(fm.fileExists(atPath: source.appendingPathComponent("lightx2v/infer.py").path), "source download missing inference entry")
        try expect(!fm.fileExists(atPath: training.path), "fresh source download retained training resources")
        let original = try Data(contentsOf: source.appendingPathComponent("lightx2v/infer.py"))
        try fm.createDirectory(at: training, withIntermediateDirectories: true)
        try Data("cached training resource".utf8).write(to: training.appendingPathComponent("sentinel"))
        let sentinel = source.appendingPathComponent("preserve-sentinel")
        try Data("preserve".utf8).write(to: sentinel)
        let reused = try await SourceDownloader.download(workspace: workspace, archiveURL: url("missing")) { _ in }
        try expect(reused.directory == downloaded.directory && !fm.fileExists(atPath: training.path), "verified source cache was not reused and cleaned without a download")
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
            if name == "incomplete" {
                try JSONFile.write(["commit": SourceDownloader.revision, "directory": existing.path], to: existing.appendingPathComponent(".lightx2v-source.json"))
            } else {
                try fm.createDirectory(at: existing.appendingPathComponent("lightx2v"), withIntermediateDirectories: true)
                try original.write(to: existing.appendingPathComponent("lightx2v/infer.py"))
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
