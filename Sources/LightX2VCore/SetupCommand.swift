import Foundation
import Darwin

public struct SetupCommandResult {
    public let status: Int32
    public let output: String
}

/// Bounded, cancellable subprocesses for discovery and archive extraction. No shell is used.
public enum SetupCommand {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func cancel() { lock.lock(); flag = true; lock.unlock() }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
    public static func run(_ executable: String, arguments: [String], workspace: WorkspaceLayout,
                           timeout: TimeInterval = 15) async throws -> SetupCommandResult {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let file = workspace.temporary.appendingPathComponent("process-\(UUID().uuidString).log")
                        FileManager.default.createFile(atPath: file.path, contents: nil)
                        defer { try? FileManager.default.removeItem(at: file) }
                        let output = try FileHandle(forWritingTo: file)
                        defer { try? output.close() }
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: executable)
                        process.arguments = arguments
                        process.standardInput = FileHandle.nullDevice
                        process.standardOutput = output; process.standardError = output
                        process.currentDirectoryURL = workspace.root
                        process.environment = ProcessInfo.processInfo.environment.merging(workspace.environment) { _, new in new }
                        if cancellation.cancelled { throw CancellationError() }
                        try process.run()
                        let deadline = Date().addingTimeInterval(timeout)
                        var stoppedAt: Date?
                        while process.isRunning {
                            if cancellation.cancelled || Date() > deadline {
                                if stoppedAt == nil { process.terminate(); stoppedAt = Date() }
                                else if Date().timeIntervalSince(stoppedAt!) > 1 { kill(process.processIdentifier, SIGKILL) }
                            }
                            Thread.sleep(forTimeInterval: 0.025)
                        }
                        process.waitUntilExit()
                        if cancellation.cancelled { throw CancellationError() }
                        if stoppedAt != nil { throw AppError.message("检测超时") }
                        let reader = try FileHandle(forReadingFrom: file)
                        defer { try? reader.close() }
                        let bytes = try reader.read(upToCount: 2_000_000) ?? Data()
                        continuation.resume(returning: SetupCommandResult(status: process.terminationStatus, output: String(decoding: bytes, as: UTF8.self)))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}
