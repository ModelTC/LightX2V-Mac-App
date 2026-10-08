import Foundation
import LightX2VCore

struct CheckFailure: Error { let message: String }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}

@main
struct CoreChecks {
    static func main() throws {
        try invalidRequests()
        print("PASS invalid request validation")
        try requestRoundTrip()
        print("PASS Unicode, seed and dimensions round trip")
        try crashRecovery()
        print("PASS interrupted history recovery")
        try persistentHistory()
        print("PASS atomic history persistence")
        print("4 core checks passed")
    }
    static func invalidRequests() throws {
        for (prompt, width, height, seed) in [("", 1024, 1024, Int64(42)), ("test", 720, 1280, 42),
                                            ("test", 256, 2080, 42), ("test", 1024, 1024, -1),
                                            ("test", 1024, 1024, 4294967296)] {
            var rejected = false
            do { _ = try InferenceRequest(settings: .defaults, prompt: prompt, width: width, height: height, seed: seed, output: "/tmp/image.png") }
            catch { rejected = true }
            try expect(rejected, "invalid request accepted")
        }
    }
    static func requestRoundTrip() throws {
        let request = try InferenceRequest(settings: .defaults, prompt: "你好 'quotes' $HOME\nsecond line", width: 1536, height: 864, seed: 4294967295, output: "/tmp/space here/image.png")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(InferenceRequest.self, from: data)
        try expect(decoded.prompt == request.prompt, "prompt changed")
        try expect(decoded.width == 1536 && decoded.height == 864, "dimensions changed")
        try expect(decoded.seed == 4294967295, "seed truncated")
    }
    static func crashRecovery() throws {
        let request = try InferenceRequest(settings: .defaults, prompt: "test", width: 512, height: 512, seed: 42, output: "/tmp/image.png")
        let active = Generation(request: request)
        var completed = Generation(request: request); completed.status = .completed
        var failed = Generation(request: request); failed.status = .failed; failed.error = "original failure"
        var workspace = WorkspaceData(generations: [active, completed, failed])
        workspace.recoverInterrupted()
        try expect(workspace.generations.map(\.status) == [.interrupted, .completed, .failed], "recovery changed wrong status")
        try expect(workspace.generations[2].error == "original failure", "failure detail lost")
        try expect(workspace.generations[0].error != nil, "interrupted run missing reason")
    }
    static func persistentHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspace.json")
        let request = try InferenceRequest(settings: .defaults, prompt: "history", width: 512, height: 768, seed: 17, output: dir.appendingPathComponent("image.png").path)
        let workspace = WorkspaceData(generations: [Generation(request: request)])
        try JSONFile.write(workspace, to: url)
        let loaded = try JSONFile.read(WorkspaceData.self, from: url)
        try expect(loaded.generations[0].id == workspace.generations[0].id, "history identity changed")
        try expect(loaded.generations[0].request.height == 768, "history parameters changed")
        try expect(loaded.settings == workspace.settings, "settings changed")
    }
}
