import Foundation
import Darwin

public struct SetupCommandResult {
    public let status: Int32
    public let output: String
}

/// Bounded, cancellable subprocess groups for discovery and installation.
/// Arguments are passed directly; user paths are never interpolated into shell code.
public enum SetupCommand {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func cancel() { lock.lock(); flag = true; lock.unlock() }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
    public static func run(_ executable: String, arguments: [String], workspace: WorkspaceLayout,
                           timeout: TimeInterval = 15, environment: [String: String] = [:], logFile: URL? = nil,
                           useWorkspaceEnvironment: Bool = true,
                           onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SetupCommandResult {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let file = logFile ?? workspace.temporary.appendingPathComponent("process-\(UUID().uuidString).log")
                        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        FileManager.default.createFile(atPath: file.path, contents: nil)
                        defer { if logFile == nil { try? FileManager.default.removeItem(at: file) } }
                        var actions: posix_spawn_file_actions_t?
                        var attributes: posix_spawnattr_t?
                        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
                        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
                        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
                        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, file.path, O_WRONLY | O_TRUNC, 0o600)
                        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
                        posix_spawn_file_actions_addchdir_np(&actions, workspace.root.path)
                        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
                        posix_spawnattr_setpgroup(&attributes, 0)
                        let variables = ProcessInfo.processInfo.environment.merging(useWorkspaceEnvironment ? workspace.environment : [:]) { _, new in new }
                            .merging(environment) { _, new in new }
                        let argv = ([executable] + arguments).map { strdup($0) }
                        let envp = variables.map { strdup("\($0.key)=\($0.value)") }
                        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
                        var spawnArguments = argv + [nil], spawnEnvironment = envp + [nil]
                        var pid: pid_t = 0
                        if cancellation.cancelled { throw CancellationError() }
                        let code = posix_spawn(&pid, executable, &actions, &attributes, &spawnArguments, &spawnEnvironment)
                        guard code == 0 else { throw AppError.message("无法运行 \(URL(fileURLWithPath: executable).lastPathComponent)：\(String(cString: strerror(code)))") }
                        var reaped = false
                        defer {
                            if !reaped { kill(-pid, SIGKILL); var ignored: Int32 = 0; waitpid(pid, &ignored, 0) }
                        }
                        let reader = try FileHandle(forReadingFrom: file)
                        defer { try? reader.close() }
                        var captured = Data(), pending = Data()
                        func readOutput() throws {
                            while let data = try reader.read(upToCount: 65536), !data.isEmpty {
                                captured.append(data); pending.append(data)
                                if captured.count > 2_000_000 { captured.removeFirst(captured.count - 2_000_000) }
                                while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                                    onOutput(String(decoding: pending[..<end], as: UTF8.self))
                                    pending.removeSubrange(...end)
                                }
                                if pending.count > 65536 {
                                    onOutput(String(decoding: pending, as: UTF8.self)); pending.removeAll(keepingCapacity: true)
                                }
                            }
                        }
                        let deadline = Date().addingTimeInterval(timeout)
                        var stoppedAt: Date?
                        var status: Int32 = 0
                        while true {
                            let waited = waitpid(pid, &status, WNOHANG)
                            if waited == pid { reaped = true; break }
                            if waited == -1 {
                                if errno == EINTR { continue }
                                throw AppError.message("无法获取安装进程的状态。")
                            }
                            try readOutput()
                            if cancellation.cancelled || Date() > deadline {
                                if stoppedAt == nil { kill(-pid, SIGTERM); stoppedAt = Date() }
                                else if Date().timeIntervalSince(stoppedAt!) > 1 { kill(-pid, SIGKILL) }
                            }
                            Thread.sleep(forTimeInterval: 0.025)
                        }
                        if stoppedAt != nil { kill(-pid, SIGKILL) }
                        try readOutput()
                        if !pending.isEmpty { onOutput(String(decoding: pending, as: UTF8.self)) }
                        if cancellation.cancelled { throw CancellationError() }
                        if stoppedAt != nil { throw AppError.message("操作超时，请检查网络后重试。") }
                        let exitCode = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                        continuation.resume(returning: SetupCommandResult(status: exitCode, output: String(decoding: captured, as: UTF8.self)))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}
