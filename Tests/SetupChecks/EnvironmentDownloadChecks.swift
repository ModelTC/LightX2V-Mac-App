import Foundation
import LightX2VCore

private final class DownloadUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [EnvironmentInstallProgress] = []
    func append(_ value: EnvironmentInstallProgress) { lock.lock(); updates.append(value); lock.unlock() }
    var logs: [String] { lock.lock(); defer { lock.unlock() }; return updates.compactMap(\.logLine) }
    var hasByteProgress: Bool {
        lock.lock(); defer { lock.unlock() }
        return updates.contains { ($0.fraction ?? 0) > 0 && $0.detail.contains("MB") }
    }
}

extension SetupChecks {
    static func environmentDownload(_ root: URL) async throws {
        let fm = FileManager.default
        let serverWorkspace = WorkspaceLayout(root.appendingPathComponent("download-server").path)
        try serverWorkspace.prepare()
        let payload = Data(repeating: 65, count: 1_048_576)
        let fixture = serverWorkspace.root.appendingPathComponent("payload")
        try payload.write(to: fixture)
        let checksum = try PyTorchEnvironmentInstaller.digest(fixture)
        let portFile = serverWorkspace.root.appendingPathComponent("port")
        let script = #"""
import http.server, pathlib, sys, time
payload = pathlib.Path(sys.argv[1]).read_bytes()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path not in ('/installer.sh', '/slow.sh'):
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        try:
            if self.path == '/slow.sh':
                for offset in range(0, len(payload), 4096):
                    self.wfile.write(payload[offset:offset + 4096])
                    self.wfile.flush()
                    time.sleep(0.03)
            else:
                self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()
"""#
        let server = Task {
            try await SetupCommand.run("/usr/bin/python3", arguments: ["-I", "-B", "-u", "-c", script, fixture.path, portFile.path],
                                       workspace: serverWorkspace, timeout: 60)
        }
        defer { server.cancel() }
        for _ in 0..<100 where !fm.fileExists(atPath: portFile.path) { try await Task.sleep(for: .milliseconds(25)) }
        try expect(fm.fileExists(atPath: portFile.path), "download fixture server did not start")
        let port = try String(contentsOf: portFile, encoding: .utf8)
        func distribution(_ name: String, _ hash: String? = nil) -> MinicondaDistribution {
            .init(url: URL(string: "http://127.0.0.1:\(port)/\(name)")!, sha256: hash ?? checksum, requiresSpaceFreePrefix: false)
        }
        let workspace = WorkspaceLayout(root.appendingPathComponent("download with spaces").path)
        let updates = DownloadUpdates()
        let logFile = workspace.root.appendingPathComponent("logs/0-download.log")
        let cached = try await PyTorchEnvironmentInstaller.downloadInstaller(distribution("installer.sh"), workspace: workspace, logFile: logFile) { updates.append($0) }
        try expect(updates.logs.first?.hasPrefix("Equivalent download command: curl -L ") == true, "download must show its command before progress")
        try expect(updates.logs.contains { $0.contains("SHA-256 verified") }, "download verification result missing")
        let savedLog = try String(contentsOf: logFile, encoding: .utf8)
        try expect(savedLog.contains("Download URL: ") && savedLog.contains(cached.path) && savedLog.contains(checksum), "download log missing URL, destination or checksum")
        let received = try Data(contentsOf: cached)
        try expect(received == payload, "download changed installer bytes")
        try expect(updates.hasByteProgress, "download did not stream byte progress")
        let reused = try await PyTorchEnvironmentInstaller.downloadInstaller(distribution("installer.sh"), workspace: workspace) { _ in }
        try expect(reused == cached, "valid cached installer not reused")

        let invalid = WorkspaceLayout(root.appendingPathComponent("invalid download").path)
        do {
            _ = try await PyTorchEnvironmentInstaller.downloadInstaller(distribution("installer.sh", String(repeating: "0", count: 64)), workspace: invalid) { _ in }
            throw Failure(message: "incorrect checksum was accepted")
        } catch let error as Failure { throw error }
        catch { try expect(error.localizedDescription.contains("verification failed"), "checksum failure diagnostic lost") }
        try expect(!fm.fileExists(atPath: invalid.root.appendingPathComponent("cache/miniconda/installer.sh").path), "unverified installer retained as cache")
        let checksumTemporaryFiles = try fm.contentsOfDirectory(atPath: invalid.temporary.path)
        try expect(checksumTemporaryFiles.isEmpty, "checksum failure left a temporary download")
        do {
            _ = try await PyTorchEnvironmentInstaller.downloadInstaller(distribution("missing.sh"), workspace: invalid) { _ in }
            throw Failure(message: "HTTP 404 was accepted")
        } catch let error as Failure { throw error }
        catch { try expect(error.localizedDescription.contains("download failed"), "HTTP failure diagnostic lost") }
        let httpTemporaryFiles = try fm.contentsOfDirectory(atPath: invalid.temporary.path)
        try expect(httpTemporaryFiles.isEmpty, "HTTP failure left a temporary download")

        let slowWorkspace = WorkspaceLayout(root.appendingPathComponent("cancelled download").path)
        let slowUpdates = DownloadUpdates()
        let downloading = Task {
            try await PyTorchEnvironmentInstaller.downloadInstaller(distribution("slow.sh"), workspace: slowWorkspace) { slowUpdates.append($0) }
        }
        defer { downloading.cancel() }
        for _ in 0..<100 where !slowUpdates.hasByteProgress { try await Task.sleep(for: .milliseconds(25)) }
        try expect(slowUpdates.hasByteProgress, "slow download did not start")
        downloading.cancel()
        var cancelled = false
        do { _ = try await downloading.value } catch is CancellationError { cancelled = true }
        try expect(cancelled, "download cancellation was not reported")
        let cancelledTemporaryFiles = try fm.contentsOfDirectory(atPath: slowWorkspace.temporary.path)
        try expect(cancelledTemporaryFiles.isEmpty, "cancelled download left a temporary file")
        try expect(!fm.fileExists(atPath: slowWorkspace.root.appendingPathComponent("cache/miniconda/slow.sh").path), "cancelled installer was cached")
        server.cancel()
        _ = try? await server.value
    }
}
