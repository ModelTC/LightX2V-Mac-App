import Foundation
import LightX2VCore

struct Failure: Error { let message: String }
func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}
func rejects(_ body: () throws -> Void) throws {
    var failed = false
    do { try body() } catch { failed = true }
    try expect(failed, "operation should have failed")
}

@main struct SetupChecks {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LightX2V setup checks \(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        if CommandLine.arguments.contains("--download") {
            let workspace = WorkspaceLayout(root.path)
            let result = try await SourceDownloader.download(workspace: workspace) { print($0) }
            try expect(fm.fileExists(atPath: result.directory + "/lightx2v/infer.py"), "real download missing source")
            try expect(!fm.fileExists(atPath: result.directory + "/.git"), "download contains git history")
            let second = try await SourceDownloader.download(workspace: workspace) { print($0) }
            try expect(second.commit == result.commit, "repeat download not reused")
            print("PASS real GitHub download and reuse: \(result.commit)")
            return
        }
        if CommandLine.arguments.contains("--search") {
            let found = try await PythonEnvironmentSearch.search(workspace: WorkspaceLayout(root.path), repository: "/Users/yongyang/Documents/x2v/LightX2V", selected: "") { _, done, total in print("\(done)/\(total)") }
            for env in found { print("\(env.executable) | Python \(env.pythonVersion) | PyTorch \(env.torchVersion) | \(env.detail)") }
            try expect(found.contains { $0.mpsAvailable }, "no real MPS environment discovered on this Mac")
            print("PASS local environment search")
            return
        }
        try workspaceSwitching(root)
        print("PASS empty history on workspace switch, unchanged original data and macOS locator")
        try migrationFailure(root)
        print("PASS destination collision and failed locator rollback")
        try archiveValidation()
        print("PASS SHA parsing, pinned archive paths, traversal/history rejection")
        try discovery(root)
        print("PASS separate venv identities and alias deduplication")
        try await commands(root)
        print("PASS probe result parsing, missing torch, timeout and cancellation")
        print("5 setup checks passed")
    }

    static func workspaceSwitching(_ root: URL) throws {
        let fm = FileManager.default
        let support = root.appendingPathComponent("support")
        let oldOutput = root.appendingPathComponent("old output/job")
        try fm.createDirectory(at: oldOutput, withIntermediateDirectories: true)
        let image = Data([1,2,3,4]); try image.write(to: oldOutput.appendingPathComponent("image.png"))
        try Data("log".utf8).write(to: oldOutput.appendingPathComponent("inference.log"))
        let previous = support.appendingPathComponent("workspace.json")
        let legacyJSON = #"{"settings":{"repository":"/old/repo","model":"/old/model","config":"/old/config","python":"/old/python","outputDirectory":"/old/output"},"generations":[],"hasCompletedGeneralSetup":true}"#
        let legacy = try JSONDecoder().decode(WorkspaceData.self, from: Data(legacyJSON.utf8))
        try expect(legacy.settings.workingDirectory.isEmpty && !legacy.settings.hasGeneralPaths, "legacy failed to request a workspace")
        var job = Generation(request: try InferenceRequest(settings: legacy.settings, prompt: "中文", width: 1024, height: 1024, seed: 7, output: oldOutput.appendingPathComponent("image.png").path))
        job.status = .completed
        var old = legacy; old.generations = [job]
        try JSONFile.write(old, to: previous)
        var snapshot = old
        snapshot.settings.workingDirectory = root.appendingPathComponent("new workspace").path
        snapshot.hasCompletedGeneralSetup = true
        let saved = try WorkspaceStorage.save(snapshot, previousState: previous, locatorRoot: support)
        let location = try WorkspaceStorage.stateURL(locatorRoot: support)
        let reopened = try JSONFile.read(WorkspaceData.self, from: location)
        try expect(reopened.settings.outputDirectory == saved.settings.workingDirectory + "/outputs", "outputs not derived")
        try expect(reopened.generations.isEmpty && saved.generations.isEmpty, "old history was imported into new workspace")
        let outputFiles = try fm.contentsOfDirectory(atPath: saved.settings.outputDirectory)
        try expect(outputFiles.isEmpty, "old outputs were copied")
        let originalImage = try Data(contentsOf: URL(fileURLWithPath: job.request.output))
        try expect(originalImage == image, "original image changed")
        let originalLog = try String(contentsOf: oldOutput.appendingPathComponent("inference.log"), encoding: .utf8)
        try expect(originalLog == "log", "original log changed")
        let originalHistory = try JSONFile.read(WorkspaceData.self, from: previous)
        try expect(originalHistory.generations.first?.id == job.id, "old workspace history was changed")
        let locator = try JSONFile.read(WorkspaceLocation.self, from: support.appendingPathComponent("workspace_location.json"))
        try expect(locator.workingDirectory == saved.settings.workingDirectory, "system app directory lost workspace pointer")
        let expectedSupport = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LightX2V APP")
        try expect(WorkspaceStorage.applicationSupportRoot.standardizedFileURL == expectedSupport.standardizedFileURL, "locator is not in macOS user app information")
        // Saving in the same workspace preserves its own history, even if an old output is unavailable.
        var withHistory = saved
        withHistory.generations = [job]
        let same = try WorkspaceStorage.save(withHistory, previousState: location, locatorRoot: support)
        try expect(same.generations.first?.id == job.id && same.generations.first?.request.output == job.request.output, "same-directory save changed history")
        // A later workspace change also carries its downloaded source/config with it.
        let managed = WorkspaceLayout(saved.settings.workingDirectory).code.appendingPathComponent("LightX2V-abc")
        try fm.createDirectory(at: managed, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: managed.appendingPathComponent("config.json"))
        var next = same; next.settings.repository = managed.path; next.settings.config = managed.appendingPathComponent("config.json").path
        try JSONFile.write(next, to: location)
        next.settings.workingDirectory = root.appendingPathComponent("second workspace").path
        let moved = try WorkspaceStorage.save(next, previousState: location, locatorRoot: support)
        try expect(moved.settings.repository.hasPrefix(next.settings.workingDirectory + "/code/"), "managed source not moved")
        try expect(fm.fileExists(atPath: moved.settings.config), "config not rebased")
        try expect(fm.fileExists(atPath: managed.path), "original source removed")
        try expect(moved.generations.isEmpty, "later workspace switch kept old records")
        let previousAfterSwitch = try JSONFile.read(WorkspaceData.self, from: location)
        try expect(previousAfterSwitch.generations.first?.id == job.id, "switch modified previous workspace history")
        let secondOutputs = try fm.contentsOfDirectory(atPath: moved.settings.outputDirectory)
        try expect(secondOutputs.isEmpty, "later workspace switch copied images")
        let unchanged = try WorkspaceStorage.save(moved, previousState: WorkspaceLayout(moved.settings.workingDirectory).state, locatorRoot: support)
        try expect(unchanged.generations.isEmpty, "empty history changed on repeated save")
        try expect(WorkspaceLayout(moved.settings.workingDirectory).environment.values.filter { $0 != "1" }.allSatisfy { $0.hasPrefix(moved.settings.workingDirectory + "/") }, "cache outside workspace")
    }

    static func migrationFailure(_ root: URL) throws {
        let fm = FileManager.default
        let target = WorkspaceLayout(root.appendingPathComponent("conflict").path)
        try target.prepare()
        let original = Data("important".utf8); try original.write(to: target.state)
        var data = WorkspaceData(); data.settings.workingDirectory = target.root.path
        try rejects { _ = try WorkspaceStorage.save(data, previousState: root.appendingPathComponent("other.json"), locatorRoot: root.appendingPathComponent("locator")) }
        let retained = try Data(contentsOf: target.state)
        try expect(retained == original, "existing workspace overwritten")
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        data.settings.workingDirectory = root.appendingPathComponent("rollback").path
        try rejects { _ = try WorkspaceStorage.save(data, previousState: root.appendingPathComponent("other.json"), locatorRoot: blocked) }
        try expect(!fm.fileExists(atPath: WorkspaceLayout(data.settings.workingDirectory).state.path), "failed commit left active state")
        let unavailable = root.appendingPathComponent("unavailable")
        try JSONFile.write(WorkspaceLocation(workingDirectory: root.appendingPathComponent("missing").path), to: unavailable.appendingPathComponent("workspace_location.json"))
        try rejects { _ = try WorkspaceStorage.stateURL(locatorRoot: unavailable) }
    }

    static func archiveValidation() throws {
        let sha = String(repeating: "a", count: 40)
        try expect(SourceDownloader.commit(in: "{\"sha\":\"\(sha)\"}") == sha, "API SHA parse")
        try expect(SourceDownloader.commit(in: "{\"sha\":\"\(String(repeating: "b", count: 40))\",\"currentOid\":\"\(sha)\"}") == sha, "HTML main revision precedence")
        try expect(SourceDownloader.commit(in: "{\"sha\":\"main\"}") == nil, "non-SHA accepted")
        try SourceDownloader.validateArchivePaths("LightX2V-\(sha)/\nLightX2V-\(sha)/lightx2v/infer.py\n", commit: sha)
        for invalid in ["/tmp/evil", "LightX2V-\(sha)/../evil", "LightX2V-\(sha)/.git/config", "LightX2V-wrong/infer.py", ""] {
            try rejects { try SourceDownloader.validateArchivePaths(invalid, commit: sha) }
        }
    }

    static func discovery(_ root: URL) throws {
        let fm = FileManager.default
        let home = root.appendingPathComponent("fake home")
        let envs = [home.appendingPathComponent(".virtualenvs/one/bin"), home.appendingPathComponent(".virtualenvs/two/bin")]
        for env in envs {
            try fm.createDirectory(at: env, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: env.appendingPathComponent("python"), withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
            try fm.createSymbolicLink(at: env.appendingPathComponent("python3"), withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        }
        let found = PythonEnvironmentSearch.candidates(home: home, path: "", repository: "", workspace: "", selected: envs[0].appendingPathComponent("python").path)
        try expect(found.filter { $0.hasPrefix(home.path) }.count == 2, "venvs sharing a base Python collapsed, or aliases duplicated")
    }

    static func commands(_ root: URL) async throws {
        let layout = WorkspaceLayout(root.appendingPathComponent("commands").path)
        try layout.prepare()
        let executable = layout.root.appendingPathComponent("fake python")
        try Data("#!/bin/sh\nprintf '%s\\n' 'LIGHTX2V_ENV:{\"python\":\"3.11\",\"torch\":\"2.9\",\"mps\":true,\"detail\":\"ready\"}'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let probe = try await PythonEnvironmentSearch.probe(executable.path, workspace: layout)
        try expect(probe.mpsAvailable && probe.torchVersion == "2.9", "probe JSON lost")
        try Data("#!/bin/sh\nprintf '%s\\n' 'LIGHTX2V_ENV:{\"python\":\"3.11\",\"torch\":\"\",\"mps\":false,\"detail\":\"未安装 PyTorch\"}'\n".utf8).write(to: executable)
        let missing = try await PythonEnvironmentSearch.probe(executable.path, workspace: layout)
        try expect(!missing.mpsAvailable && missing.detail == "未安装 PyTorch", "missing torch result lost")
        var timedOut = false
        do { _ = try await SetupCommand.run("/bin/sleep", arguments: ["5"], workspace: layout, timeout: 0.1) } catch { timedOut = true }
        try expect(timedOut, "timeout did not stop process")
        let task = Task { try await SetupCommand.run("/bin/sleep", arguments: ["10"], workspace: layout) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date(); task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true }
        try expect(cancelled && Date().timeIntervalSince(start) < 3, "cancellation not prompt")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: layout.temporary.path)
        try expect(leftovers.isEmpty, "probe temporary files left behind")
    }
}
