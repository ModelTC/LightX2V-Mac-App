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
        print("PASS preset-only selection and legacy history normalization")
        try setupPersistenceAndMigration()
        print("PASS first-launch, incomplete, completed and legacy setup persistence")
        try generalSettingsValidation()
        print("PASS general path validation independent of model preparation")
        print("8 core checks passed")
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

    static func setupPersistenceAndMigration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspace.json")
        let fresh = WorkspaceData()
        try expect(!fresh.hasCompletedGeneralSetup && !fresh.settings.hasGeneralPaths, "new installation skipped setup")
        try expect([fresh.settings.repository, fresh.settings.python, fresh.settings.outputDirectory].allSatisfy(\.isEmpty), "new setup contains machine-specific defaults")
        try JSONFile.write(fresh, to: url)
        let unfinished = try JSONFile.read(WorkspaceData.self, from: url)
        try expect(!unfinished.hasCompletedGeneralSetup, "quitting before setup marked it complete")

        let settings = AppSettings(repository: "/custom/LightX2V", model: "", config: "", python: "/custom/env/bin/python", workingDirectory: "/custom/workspace")
        let request = try InferenceRequest(settings: settings, prompt: "保留历史", width: 1024, height: 1024, seed: 42, output: "/custom/images/image.png")
        let history = Generation(request: request)
        let completed = WorkspaceData(settings: settings, generations: [history], hasCompletedGeneralSetup: true)
        try JSONFile.write(completed, to: url)
        let reopened = try JSONFile.read(WorkspaceData.self, from: url)
        try expect(reopened.hasCompletedGeneralSetup && reopened.settings == settings, "reopening lost completed setup or paths")
        try expect(reopened.generations.first?.id == history.id, "saving setup lost history")

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(completed)) as! [String: Any]
        legacy.removeValue(forKey: "hasCompletedGeneralSetup")
        let migrated = try JSONDecoder().decode(WorkspaceData.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expect(migrated.hasCompletedGeneralSetup && migrated.settings == settings, "upgrade forced existing user through setup")
        try expect(migrated.generations.first?.id == history.id, "migration lost history")
        legacy["hasCompletedGeneralSetup"] = false
        let explicitIncomplete = try JSONDecoder().decode(WorkspaceData.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expect(!explicitIncomplete.hasCompletedGeneralSetup, "explicit incomplete flag was ignored")
        legacy.removeValue(forKey: "hasCompletedGeneralSetup")
        var partial = legacy["settings"] as! [String: Any]; partial["python"] = " "; legacy["settings"] = partial
        let incompleteLegacy = try JSONDecoder().decode(WorkspaceData.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expect(!incompleteLegacy.hasCompletedGeneralSetup, "incomplete legacy paths skipped setup")
    }

    static func generalSettingsValidation() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let repo = dir.appendingPathComponent("LightX2V")
        try fm.createDirectory(at: repo.appendingPathComponent("lightx2v"), withIntermediateDirectories: true)
        try Data().write(to: repo.appendingPathComponent("lightx2v/infer.py"))
        let python = dir.appendingPathComponent("python")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let output = dir.appendingPathComponent("new/images")
        let valid = AppSettings(repository: repo.path, model: "", config: "", python: python.path, workingDirectory: output.path)
        try valid.validateGeneralPaths()
        try expect(!fm.fileExists(atPath: output.path), "validation unexpectedly created output folders")
        let invalid: [(WritableKeyPath<AppSettings, String>, String)] = [
            (\.repository, ""), (\.python, ""), (\.workingDirectory, ""),
            (\.repository, "relative/repo"), (\.python, "relative/python"), (\.workingDirectory, "relative/output"),
            (\.repository, dir.path), (\.python, repo.path), (\.python, dir.appendingPathComponent("missing").path),
            (\.python, repo.appendingPathComponent("lightx2v/infer.py").path),
            (\.workingDirectory, python.path), (\.workingDirectory, python.appendingPathComponent("images").path)
        ]
        for (key, value) in invalid {
            var settings = valid; settings[keyPath: key] = value
            var rejected = false
            do { try settings.validateGeneralPaths() } catch { rejected = true }
            try expect(rejected, "invalid general path accepted: \(value)")
        }
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
                try expect(restored.dimensions == ImageDimensions(width: width, height: height), "preset history dimensions changed")
            }
        }
    }

    static func sizeSelectionAndRestoration() throws {
        var selection = GenerationSize()
        try expect(selection.resolution == .oneK && selection.aspectRatio == .square, "default is not 1K 1:1")
        selection.selectResolution(.twoK)
        selection.selectAspectRatio(.landscape169)
        selection.selectAspectRatio(.portrait916)
        try expect(selection.aspectRatio == .portrait916 && selection.resolution == .twoK, "orientation did not preserve 2K")
        try expect(selection.dimensions == ImageDimensions(width: 1536, height: 2752), "orientation swapped incorrectly")
        selection = GenerationSize(width: 512, height: 768)
        try expect(selection.resolution == .oneK && selection.aspectRatio == .portrait23, "legacy portrait history not normalized")
        try expect(selection.dimensions == ImageDimensions(width: 832, height: 1248), "legacy portrait dimensions are not a preset")
        selection.selectResolution(.twoK)
        try expect(selection.aspectRatio == .portrait23, "tier switch lost normalized ratio")
        try expect(selection.dimensions == ImageDimensions(width: 1696, height: 2528), "normalized tier switch has wrong dimensions")
        for (width, height, tier, ratio) in [
            (768, 512, ImageResolution.oneK, ImageAspectRatio.landscape32),
            (720, 1280, .oneK, .portrait916),
            (2560, 1440, .twoK, .landscape169),
            (0, 0, .oneK, .square)
        ] {
            let restored = GenerationSize(width: width, height: height)
            try expect(restored.resolution == tier && restored.aspectRatio == ratio, "legacy history chose wrong preset")
            try expect(restored.dimensions.isValid, "legacy history produced invalid dimensions")
        }
    }
}
