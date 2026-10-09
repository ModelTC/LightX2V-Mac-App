import Foundation
import LightX2VCore

/// A single owned subprocess. Reading never blocks SwiftUI's main thread.
final class ProcessRunner {
    private let process = Process()
    private let pipe = Pipe()
    private let queue = DispatchQueue(label: "app.lightx2v.process.\(UUID().uuidString)")
    var isRunning: Bool { process.isRunning }

    func start(python: String, bridge: String, mode: String, request: String, workspace: String,
               onEvent: @escaping ([String: Any]) -> Void, onExit: @escaping (Int32) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", bridge, mode, request]
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let layout = WorkspaceLayout(workspace)
        try layout.prepare()
        process.currentDirectoryURL = layout.root
        var env = ProcessInfo.processInfo.environment.merging(layout.environment) { _, new in new }
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        process.environment = env
        try process.run()
        queue.async { [self] in
            var pending = Data()
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    deliver(line, to: onEvent)
                }
            }
            if !pending.isEmpty { deliver(pending, to: onEvent) }
            process.waitUntilExit()
            let code = process.terminationStatus
            try? pipe.fileHandleForReading.close()
            DispatchQueue.main.async { onExit(code) }
        }
    }

    private func deliver(_ data: Data, to callback: @escaping ([String: Any]) -> Void) {
        let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            ?? ["type": "log", "message": String(decoding: data, as: UTF8.self)]
        DispatchQueue.main.async { callback(event) }
    }

    func stop() { if process.isRunning { process.terminate() } }
}
