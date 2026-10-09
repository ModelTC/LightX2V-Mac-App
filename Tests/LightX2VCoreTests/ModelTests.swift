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
        try resolutionPresets()
        print("PASS all 14 resolution presets and tier switches")
        try sizeSelectionAndRestoration()
        print("PASS default, orientation, custom sizes and history restoration")
        print("6 core checks passed")
    }
    static func invalidRequests() throws {
        for (prompt, width, height, seed) in [("", 1024, 1024, Int64(42)), ("test", 720, 1280, 42),
                                            ("test", 256, 2784, 42), ("test", 224, 1024, 42), ("test", 1024, 1024, -1),
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

    static func resolutionPresets() throws {
        let expected: [(ImageAspectRatio, Int, Int, Int, Int)] = [
            (.square, 1024, 1024, 2048, 2048),
            (.landscape43, 1184, 896, 2400, 1792),
            (.portrait34, 896, 1184, 1792, 2400),
            (.landscape32, 1248, 832, 2528, 1696),
            (.portrait23, 832, 1248, 1696, 2528),
            (.landscape169, 1376, 768, 2752, 1536),
            (.portrait916, 768, 1376, 1536, 2752),
        ]
        try expect(ImageAspectRatio.allCases.count == expected.count, "missing aspect ratio")
        for (ratio, w1, h1, w2, h2) in expected {
            var selection = GenerationSize()
            selection.selectAspectRatio(ratio)
            try expect(selection.dimensions == ImageDimensions(width: w1, height: h1), "incorrect 1K \(ratio)")
            selection.selectResolution(.twoK)
            try expect(selection.dimensions == ImageDimensions(width: w2, height: h2), "incorrect 2K \(ratio)")
            try expect(selection.aspectRatio == ratio, "tier switch lost ratio")
            selection.selectResolution(.oneK)
            try expect(selection.dimensions == ImageDimensions(width: w1, height: h1), "tier round trip changed size")
            for (width, height) in [(w1, h1), (w2, h2)] {
                let request = try InferenceRequest(settings: .defaults, prompt: "preset", width: width, height: height, seed: 42, output: "/tmp/image.png")
                let decoded = try JSONDecoder().decode(InferenceRequest.self, from: JSONEncoder().encode(request))
                let restored = GenerationSize(width: decoded.width, height: decoded.height)
                try expect(restored.aspectRatio == ratio, "history ratio not restored")
                try expect(restored.resolution == (width == w1 ? .oneK : .twoK), "history tier not restored")
            }
        }
    }

    static func sizeSelectionAndRestoration() throws {
        var selection = GenerationSize()
        try expect(selection.resolution == .oneK && selection.aspectRatio == .square, "default is not 1K 1:1")
        selection.selectResolution(.twoK)
        selection.selectAspectRatio(.landscape169)
        selection.swapOrientation()
        try expect(selection.aspectRatio == .portrait916 && selection.resolution == .twoK, "orientation did not preserve 2K")
        try expect(selection.dimensions == ImageDimensions(width: 1536, height: 2752), "orientation swapped incorrectly")
        selection.setDimensions(width: 896, height: 1184)
        try expect(selection.resolution == .oneK && selection.aspectRatio == .portrait34, "manual preset not recognized")
        selection = GenerationSize(width: 512, height: 768)
        try expect(selection.aspectRatio == nil && selection.dimensions == ImageDimensions(width: 512, height: 768), "custom history was snapped")
        selection.swapOrientation()
        try expect(selection.aspectRatio == nil && selection.dimensions == ImageDimensions(width: 768, height: 512), "custom orientation changed size")
        selection.selectResolution(.twoK)
        try expect(selection.aspectRatio == .landscape32, "custom tier switch did not choose nearest ratio")
        try expect(selection.dimensions == ImageDimensions(width: 2528, height: 1696), "custom tier switch has wrong dimensions")
        selection.setDimensions(width: 720, height: 1280)
        try expect(!selection.dimensions.isValid && selection.aspectRatio == nil, "unaligned size accepted or highlighted")
    }
}
