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
        if let index = CommandLine.arguments.firstIndex(of: "--llama-download"), CommandLine.arguments.count > index + 1 {
            let workspace = WorkspaceLayout(CommandLine.arguments[index + 1])
            let result = try await LlamaRuntimeDownloader.download(workspace: workspace) { print($0) }
            try LlamaRuntimeDownloader.validateRuntime(result.directory)
            let second = try await LlamaRuntimeDownloader.download(workspace: workspace) { print($0) }
            try expect(second.directory == result.directory, "real runtime was not reused")
            for name in ["llama-completion", "llama-mtmd-cli"] {
                let version = try await SetupCommand.run(result.directory + "/" + name, arguments: ["--version"], workspace: workspace, timeout: 30)
                try expect(version.status == 0 && version.output.contains("11564"), "real runtime version check failed: " + version.output)
            }
            print("PASS official llama.cpp download, shared libraries, both CLI versions and reuse: " + result.directory)
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--install-real"), CommandLine.arguments.count > index + 2 {
            let workspace = WorkspaceLayout(CommandLine.arguments[index + 1])
            let requirements = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            let value = try await PyTorchEnvironmentInstaller.install(workspace: workspace, requirements: requirements) { update in
                if let line = update.logLine { print(line) } else { print("\(update.stage.title) \(update.detail)") }
            }
            try expect(value.isCompatible, "real installed environment incompatible")
            print("PASS real managed installation: \(value.executable) | \(value.compatibilityDetail)")
            return
        }
        if CommandLine.arguments.contains("--download") {
            let workspace = WorkspaceLayout(root.path)
            let result = try await SourceDownloader.download(workspace: workspace) { print($0) }
            try expect(fm.fileExists(atPath: result.directory + "/lightx2v/infer.py"), "real download missing source")
            try expect(result.commit == SourceDownloader.revision && URL(fileURLWithPath: result.directory).lastPathComponent == "LightX2V-0.6.0", "download did not use version 0.6.0")
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
        try setupGuide(root)
        print("PASS setup guide ordering, path validation, clearing and reopening")
        try locatorOnlyStartup(root)
        try workspaceSwitching(root)
        print("PASS empty history on workspace switch, unchanged original data and macOS locator")
        try expect(PyTorchRequirements.summary.contains("modelscope"), "dependency hint must include modelscope")
        try migrationFailure(root)
        try workspaceReconnection(root)
        print("PASS destination collision and failed locator rollback")
        try archiveValidation()
        print("PASS SHA parsing, pinned archive paths, traversal/history rejection")
        try discovery(root)
        print("PASS separate venv identities and alias deduplication")
        try await commands(root)
        print("PASS probe result parsing, missing torch, timeout and cancellation")
        try environmentVersions()
        print("PASS all dependency minimums, numeric versions, local builds and prereleases")
        try await environmentDownload(root)
        print("PASS installer byte progress, cache reuse, checksum rejection, HTTP failure and download cancellation")
        try await environmentInstallation(root)
        print("PASS managed installation, requirements, discovery, reuse, rejection, retry and process-group cancellation")
        try await llamaRuntimeDownload(root)
        print("PASS llama.cpp download, dynamic libraries, reuse, checksum, HTTP, archive rejection, cancellation and retry")
        try await modelDownloadChecks(root)
        try modelDownloadProgressChecks()
        print("12 setup checks passed")
    }

    static func setupGuide(_ root: URL) throws {
        let fm = FileManager.default
        let workspace = root.appendingPathComponent("guide workspace")
        let source = root.appendingPathComponent("guide source")
        let python = root.appendingPathComponent("guide python")
        try fm.createDirectory(at: source.appendingPathComponent("lightx2v"), withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("lightx2v/infer.py"))
        try Data("#!/bin/sh\n".utf8).write(to: python)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        var settings = AppSettings.defaults
        var progress = GeneralSetupProgress(settings: settings)
        try expect(progress.current == .workspace && progress.completed.isEmpty, "first launch must start at step 1")
        settings.workingDirectory = workspace.path
        // Taking a snapshot on commit keeps partially typed input from moving the guide.
        try expect(progress.current == .workspace, "draft text changed committed progress")
        progress = GeneralSetupProgress(settings: settings)
        try expect(progress.current == .python && progress.completed == [.workspace], "workspace should advance to Python")
        try expect(!fm.fileExists(atPath: workspace.path), "guide must not create folders")
        settings.repository = root.path
        try expect(GeneralSetupProgress(settings: settings).current == .python, "hidden source must not change setup progress")
        settings.repository = source.path
        progress = GeneralSetupProgress(settings: settings)
        try expect(progress.current == .python && progress.completed.count == 1, "bundled source must not count as a user setting")
        let runtime = root.appendingPathComponent("guide bin")
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        for name in ["llama-completion", "llama-mtmd-cli"] { try fm.copyItem(at: python, to: runtime.appendingPathComponent(name)) }
        settings.promptEnhancement.runtimeDirectory = runtime.path
        progress = GeneralSetupProgress(settings: settings)
        try expect(progress.current == .python && progress.completed.count == 1 && !settings.hasGeneralPaths,
                   "llama.cpp should advance to the final PyTorch setting")
        settings.python = source.path
        try expect(GeneralSetupProgress(settings: settings).current == .python, "directory accepted as Python")
        settings.python = python.path
        try settings.validateGeneralPaths()
        let complete = GeneralSetupProgress(settings: settings)
        try expect(complete.current == nil && complete.completed.count == 2, "two complete paths should end guide")
        let reopened = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        try expect(GeneralSetupProgress(settings: reopened) == complete, "reopening must not replay completed steps")
        settings.repository = ""
        progress = GeneralSetupProgress(settings: settings)
        try expect(progress.current == nil && progress.completed == [.workspace, .python], "clearing source should retain Python and llama.cpp")
        settings.workingDirectory = ""
        try expect(GeneralSetupProgress(settings: settings).current == .workspace, "out-of-order entries should still guide to earliest missing step")
        settings.repository = source.path
        settings.workingDirectory = "relative/path"
        try expect(GeneralSetupProgress(settings: settings).current == .workspace, "relative workspace accepted")
        settings.workingDirectory = "/"
        try expect(GeneralSetupProgress(settings: settings).current == .workspace, "root accepted as workspace")
        settings.workingDirectory = " \(workspace.path)\n"
        settings.repository = " \(source.path) "
        settings.python = "\n\(python.path) "
        settings.promptEnhancement.runtimeDirectory = " \(runtime.path)\n"
        try expect(GeneralSetupProgress(settings: settings) == complete, "guide normalization differs from Save")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: python.path)
        try expect(GeneralSetupProgress(settings: settings).current == .python, "non-executable Python accepted")
        try fm.removeItem(at: source.appendingPathComponent("lightx2v/infer.py"))
        try expect(GeneralSetupProgress(settings: settings).current == .python, "hidden source must not change Python validation")
    }

    static func locatorOnlyStartup(_ root: URL) throws {
        let support = root.appendingPathComponent("locator-only support")
        let legacyState = support.appendingPathComponent("workspace.json")
        let legacyLocation = support.appendingPathComponent("location.json")
        let fm = FileManager.default
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let broken = Data("invalid old configuration".utf8)
        try broken.write(to: legacyState)
        try broken.write(to: legacyLocation)
        let invalidOldURL = try WorkspaceStorage.stateURL(locatorRoot: support)
        try expect(invalidOldURL == nil, "missing locator read invalid old configuration")
        let old = try JSONEncoder().encode(WorkspaceData(settings: AppSettings.defaults, hasCompletedGeneralSetup: true))
        try old.write(to: legacyState)
        let validOldURL = try WorkspaceStorage.stateURL(locatorRoot: support)
        try expect(validOldURL == nil, "missing locator read valid old configuration")
        var snapshot = WorkspaceData()
        snapshot.settings.workingDirectory = root.appendingPathComponent("first configured workspace").path
        let saved = try WorkspaceStorage.save(snapshot, previousState: nil, locatorRoot: support)
        let url = try WorkspaceStorage.stateURL(locatorRoot: support)
        try expect(url == WorkspaceLayout(saved.settings.workingDirectory).state, "first save did not create the current workspace locator")
        let retainedState = try Data(contentsOf: legacyState)
        let retainedLocation = try Data(contentsOf: legacyLocation)
        try expect(retainedState == old && retainedLocation == broken, "first save changed ignored old configuration")
        try Data("invalid locator".utf8).write(to: support.appendingPathComponent("workspace_location.json"))
        try rejects { _ = try WorkspaceStorage.stateURL(locatorRoot: support) }
        print("PASS locator-only startup ignores valid/corrupt old files, preserves them and saves a new workspace")
    }

    static func workspaceSwitching(_ root: URL) throws {
        let fm = FileManager.default
        let support = root.appendingPathComponent("support")
        let oldOutput = root.appendingPathComponent("old output/job")
        try fm.createDirectory(at: oldOutput, withIntermediateDirectories: true)
        let image = Data([1,2,3,4]); try image.write(to: oldOutput.appendingPathComponent("image.png"))
        try Data("log".utf8).write(to: oldOutput.appendingPathComponent("inference.log"))
        let originalLayout = WorkspaceLayout(root.appendingPathComponent("original workspace").path)
        try originalLayout.prepare()
        let previous = originalLayout.state
        var originalSettings = AppSettings.defaults
        originalSettings.workingDirectory = originalLayout.root.path
        var job = Generation(request: try InferenceRequest(settings: originalSettings, prompt: "中文", width: 1024, height: 1024, seed: 7, output: oldOutput.appendingPathComponent("image.png").path))
        job.status = .completed
        let old = WorkspaceData(settings: originalSettings, generations: [job], hasCompletedGeneralSetup: true)
        try JSONFile.write(old, to: previous)
        var snapshot = old
        snapshot.settings.workingDirectory = root.appendingPathComponent("new workspace").path
        snapshot.hasCompletedGeneralSetup = true
        let saved = try WorkspaceStorage.save(snapshot, previousState: previous, locatorRoot: support)
        guard let location = try WorkspaceStorage.stateURL(locatorRoot: support) else { throw Failure(message: "saved locator missing") }
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
        // Old manually downloaded source/runtime folders are not migrated to new workspaces.
        let managed = WorkspaceLayout(saved.settings.workingDirectory).code.appendingPathComponent("LightX2V-abc")
        try fm.createDirectory(at: managed, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: managed.appendingPathComponent("config.json"))
        var next = same; next.settings.repository = managed.path; next.settings.config = managed.appendingPathComponent("config.json").path
        let runtime = WorkspaceLayout(saved.settings.workingDirectory).runtimes.appendingPathComponent("llama.cpp-b11564")
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("runtime".utf8).write(to: runtime.appendingPathComponent("llama-completion"))
        next.settings.promptEnhancement.runtimeDirectory = runtime.path
        try JSONFile.write(next, to: location)
        next.settings.workingDirectory = root.appendingPathComponent("second workspace").path
        let moved = try WorkspaceStorage.save(next, previousState: location, locatorRoot: support)
        try expect(!fm.fileExists(atPath: WorkspaceLayout(moved.settings.workingDirectory).code.appendingPathComponent("LightX2V-abc").path), "old source was automatically copied")
        try expect(fm.fileExists(atPath: managed.path), "original source removed")
        try expect(!fm.fileExists(atPath: WorkspaceLayout(moved.settings.workingDirectory).runtimes.appendingPathComponent("llama.cpp-b11564").path), "old runtime was automatically copied")
        try expect(fm.fileExists(atPath: runtime.appendingPathComponent("llama-completion").path), "original runtime removed")
        try expect(moved.generations.isEmpty, "later workspace switch kept old records")
        let previousAfterSwitch = try JSONFile.read(WorkspaceData.self, from: location)
        try expect(previousAfterSwitch.generations.first?.id == job.id, "switch modified previous workspace history")
        let secondOutputs = try fm.contentsOfDirectory(atPath: moved.settings.outputDirectory)
        try expect(secondOutputs.isEmpty, "later workspace switch copied images")
        let unchanged = try WorkspaceStorage.save(moved, previousState: WorkspaceLayout(moved.settings.workingDirectory).state, locatorRoot: support)
        try expect(unchanged.generations.isEmpty, "empty history changed on repeated save")
        try expect(WorkspaceLayout(moved.settings.workingDirectory).environment.values.filter { $0 != "1" }.allSatisfy { $0.hasPrefix(moved.settings.workingDirectory + "/") }, "cache outside workspace")
    }

    static func workspaceReconnection(_ root: URL) throws {
        let layout = WorkspaceLayout(root.appendingPathComponent("existing workspace").path)
        try layout.prepare()
        var settings = AppSettings.defaults
        settings.workingDirectory = layout.root.path
        settings.repository = "/original/source"; settings.python = "/original/python"
        settings.model = "/original/model"
        let image = layout.outputs.appendingPathComponent("retained.png")
        try Data([1, 2, 3]).write(to: image)
        var job = Generation(request: try InferenceRequest(settings: settings, prompt: "retained prompt", width: 1024, height: 1024, seed: 7, output: image.path))
        job.status = .completed
        let original = WorkspaceData(settings: settings, generations: [job], hasCompletedGeneralSetup: true)
        try JSONFile.write(original, to: layout.state)
        let bytes = try Data(contentsOf: layout.state)
        let support = root.appendingPathComponent("reconnect support")
        var incoming = WorkspaceData(); incoming.settings.workingDirectory = layout.root.path
        let loaded = try WorkspaceStorage.save(incoming, previousState: nil, locatorRoot: support)
        try expect(loaded.settings == settings && loaded.generations.map(\.id) == [job.id], "reconnection lost settings or history")
        let retained = try Data(contentsOf: layout.state)
        try expect(retained == bytes, "reconnection rewrote original workspace")
        let retainedImage = try Data(contentsOf: image)
        try expect(retainedImage == Data([1, 2, 3]), "reconnection changed image")
        let restoredURL = try WorkspaceStorage.stateURL(locatorRoot: support)
        try expect(restoredURL == layout.state, "reconnection did not persist locator")
        let before = try Data(contentsOf: support.appendingPathComponent("workspace_location.json"))
        let invalid = WorkspaceLayout(root.appendingPathComponent("broken workspace").path)
        try invalid.prepare(); try Data("broken".utf8).write(to: invalid.state)
        incoming.settings.workingDirectory = invalid.root.path
        try rejects { _ = try WorkspaceStorage.save(incoming, previousState: layout.state, locatorRoot: support) }
        let after = try Data(contentsOf: support.appendingPathComponent("workspace_location.json"))
        try expect(after == before, "invalid workspace changed locator")
        let blocked = root.appendingPathComponent("blocked reconnect locator")
        try Data().write(to: blocked)
        incoming.settings.workingDirectory = layout.root.path
        try rejects { _ = try WorkspaceStorage.save(incoming, previousState: invalid.state, locatorRoot: blocked) }
        let afterFailure = try Data(contentsOf: layout.state)
        try expect(afterFailure == bytes, "failed locator write changed workspace")
        print("PASS existing workspace reconnection preserves settings, history, images and original bytes")
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
        try expect(SourceDownloader.archiveURL.absoluteString == "https://github.com/ModelTC/LightX2V/archive/refs/tags/0.6.0.zip", "source must download the official 0.6.0 ZIP")
        try expect(SourceDownloader.manualCommand.contains("/refs/tags/0.6.0.zip") && !SourceDownloader.manualCommand.contains("git clone"), "manual download must use 0.6.0 without history")
        try SourceDownloader.validateArchivePaths("LightX2V-0.6.0/lightx2v/infer.py\n", commit: SourceDownloader.version)
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
        try Data("#!/bin/sh\nprintf '%s\\n' 'LIGHTX2V_ENV:{\"python\":\"3.11\",\"torch\":\"2.9\",\"diffusers\":\"0.41.0\",\"mps\":true,\"detail\":\"ready\"}'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let probe = try await PythonEnvironmentSearch.probe(executable.path, workspace: layout)
        try expect(probe.mpsAvailable && probe.torchVersion == "2.9" && probe.diffusersVersion == "0.41.0", "probe JSON lost")
        try Data("#!/bin/sh\nprintf '%s\\n' 'LIGHTX2V_ENV:{\"python\":\"3.11\",\"torch\":\"\",\"mps\":false,\"detail\":\"未安装 PyTorch\"}'\n".utf8).write(to: executable)
        let missing = try await PythonEnvironmentSearch.probe(executable.path, workspace: layout)
        try expect(!missing.mpsAvailable && missing.detail == "未安装 PyTorch", "missing torch result lost")
        try expect(missing.diffusersVersion.isEmpty && missing.versionIssues.contains("Missing diffusers"), "missing diffusers result lost")
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
