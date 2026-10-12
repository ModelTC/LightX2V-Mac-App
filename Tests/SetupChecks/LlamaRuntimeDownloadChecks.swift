import Foundation
import LightX2VCore

private final class RuntimeUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func append(_ text: String) { lock.lock(); messages.append(text); lock.unlock() }
    var hasBytes: Bool { lock.lock(); defer { lock.unlock() }; return messages.contains { $0.contains("MB") } }
}

extension SetupChecks {
    static func llamaRuntimeDownload(_ root: URL) async throws {
        let fm = FileManager.default
        let serverWorkspace = WorkspaceLayout(root.appendingPathComponent("llama-server").path)
        try serverWorkspace.prepare()
        let portFile = serverWorkspace.root.appendingPathComponent("port")
        let script = #"""
import http.server, io, pathlib, random, sys, tarfile, time
root = pathlib.Path(sys.argv[1])
for name in ('runtime', 'unsafe', 'incomplete'):
    with tarfile.open(root / (name + '.tar.gz'), 'w:gz') as archive:
        for binary in ('llama-completion', 'llama-mtmd-cli'):
            if name == 'incomplete' and binary == 'llama-mtmd-cli': continue
            info = tarfile.TarInfo('llama-b11564/' + binary); info.mode = 0o755
            content = b'#!/bin/sh\nexit 0\n'; info.size = len(content); archive.addfile(info, io.BytesIO(content))
        info = tarfile.TarInfo('llama-b11564/libtest.0.dylib')
        content = random.Random(42).randbytes(1048576); info.size = len(content); archive.addfile(info, io.BytesIO(content))
        link = tarfile.TarInfo('llama-b11564/libtest.dylib'); link.type = tarfile.SYMTYPE
        link.linkname = '../../outside' if name == 'unsafe' else 'libtest.0.dylib'; archive.addfile(link)
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        name = 'runtime' if self.path in ('/runtime', '/slow') else self.path.lstrip('/')
        file = root / (name + '.tar.gz')
        if not file.exists(): self.send_error(404); return
        payload = file.read_bytes()
        self.send_response(200); self.send_header('Content-Length', str(len(payload))); self.end_headers()
        try:
            for offset in range(0, len(payload), 4096):
                self.wfile.write(payload[offset:offset + 4096]); self.wfile.flush()
                if self.path == '/slow': time.sleep(.02)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()
"""#
        let server = Task {
            try await SetupCommand.run("/usr/bin/python3", arguments: ["-I", "-B", "-u", "-c", script, serverWorkspace.root.path, portFile.path],
                                       workspace: serverWorkspace, timeout: 60)
        }
        defer { server.cancel() }
        for _ in 0..<200 where !fm.fileExists(atPath: portFile.path) { try await Task.sleep(for: .milliseconds(25)) }
        try expect(fm.fileExists(atPath: portFile.path), "llama download server did not start")
        let port = try String(contentsOf: portFile, encoding: .utf8)
        func distribution(_ name: String, hash: String? = nil) throws -> LlamaRuntimeDistribution {
            let file = serverWorkspace.root.appendingPathComponent((name == "slow" || name == "missing" ? "runtime" : name) + ".tar.gz")
            return .init(version: "b11564", url: URL(string: "http://127.0.0.1:\(port)/\(name)")!,
                         sha256: try hash ?? PyTorchEnvironmentInstaller.digest(file))
        }
        let workspace = WorkspaceLayout(root.appendingPathComponent("llama download 中文 spaces").path)
        let updates = RuntimeUpdates()
        let result = try await LlamaRuntimeDownloader.download(distribution("runtime"), workspace: workspace) { updates.append($0) }
        try LlamaRuntimeDownloader.validateRuntime(result.directory)
        try expect(result.directory == workspace.runtimes.appendingPathComponent("llama.cpp-b11564/bin").path,
                   "runtime escaped the selected workspace")
        try expect(updates.hasBytes, "llama download did not report byte progress")
        let library = URL(fileURLWithPath: result.directory).appendingPathComponent("libtest.dylib")
        let linkedLibrary = try fm.destinationOfSymbolicLink(atPath: library.path)
        try expect(linkedLibrary == "libtest.0.dylib", "runtime dynamic library link was lost")
        let before = try fm.attributesOfItem(atPath: library.deletingLastPathComponent().appendingPathComponent("llama-completion").path)[.modificationDate] as! Date
        let reused = try await LlamaRuntimeDownloader.download(distribution("missing"), workspace: workspace) { _ in }
        let after = try fm.attributesOfItem(atPath: URL(fileURLWithPath: reused.directory).appendingPathComponent("llama-completion").path)[.modificationDate] as! Date
        try expect(reused.directory == result.directory && before == after, "complete runtime was not reused without downloading")
        for name in ["checksum", "missing", "unsafe", "incomplete"] {
            let failed = WorkspaceLayout(root.appendingPathComponent("llama-failed-" + name).path)
            var rejected = false
            do {
                let release = try name == "checksum" ? distribution("runtime", hash: String(repeating: "0", count: 64)) : distribution(name)
                _ = try await LlamaRuntimeDownloader.download(release, workspace: failed) { _ in }
            } catch { rejected = true }
            try expect(rejected, "\(name) runtime download was accepted")
            let temporary = try fm.contentsOfDirectory(atPath: failed.temporary.path)
            try expect(temporary.isEmpty && !fm.fileExists(atPath: failed.runtimes.appendingPathComponent("llama.cpp-b11564").path),
                       "\(name) left a partial runtime installation")
        }
        let cancelled = WorkspaceLayout(root.appendingPathComponent("llama-cancelled").path)
        let slow = RuntimeUpdates()
        let downloading = Task { try await LlamaRuntimeDownloader.download(distribution("slow"), workspace: cancelled) { slow.append($0) } }
        for _ in 0..<200 where !slow.hasBytes { try await Task.sleep(for: .milliseconds(25)) }
        try expect(slow.hasBytes, "llama slow download did not start")
        downloading.cancel()
        var stopped = false
        do { _ = try await downloading.value } catch { stopped = true }
        try expect(stopped, "llama download ignored cancellation")
        let leftovers = try fm.contentsOfDirectory(atPath: cancelled.temporary.path)
        try expect(leftovers.isEmpty, "cancelled llama download left temporary files")
        _ = try await LlamaRuntimeDownloader.download(distribution("runtime"), workspace: cancelled) { _ in }
        for bad in ["/outside", "llama-b11564/../../outside", "another/runtime", ""] {
            try rejects { try LlamaRuntimeDownloader.validateArchive(paths: bad, details: "", version: "b11564") }
        }
        server.cancel(); _ = try? await server.value
    }
}
