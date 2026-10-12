import Foundation
import Darwin
import LightX2VCore

private final class InstallationLogUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: EnvironmentInstallProgress) {
        guard let line = value.logLine else { return }
        lock.lock(); storage.append(line); lock.unlock()
    }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

extension SetupChecks {
    static func environmentVersions() throws {
        for (actual, minimum, accepted) in [
            ("2.14.1", "2.14.1", true), ("2.14.1+cpu", "2.14.1", true), ("2.14.1.post1", "2.14.1", true),
            ("2.14.1rc1", "2.14.1", false), ("2.14.1.dev1", "2.14.1", false), ("2.15.0rc1", "2.14.1", true),
            ("2.9.9", "2.14.1", false), ("2.100.0", "2.14.1", true), ("0.29.0", "0.29.1", false),
            ("5.19", "5.19.0", true), ("5.18.99", "5.19.0", false), ("invalid", "2.14.1", false),
            ("", "2.14.1", false), ("2.14.1malware", "2.14.1", false)] {
            try expect(PyTorchRequirements.meetsMinimum(actual, minimum) == accepted, "version comparison incorrect: \(actual) >= \(minimum)")
        }
        var env = PythonEnvironment(executable: "/fixture/bin/python")
        env.architecture = "arm64"; env.mpsAvailable = true; env.torchVersion = "2.14.1"
        env.torchvisionVersion = "0.29.1"; env.torchaudioVersion = "2.11.0"; env.transformersVersion = "5.19.0"
        env.diffusersVersion = "0.41.0"
        let present = PyTorchRequirements.dependencies.filter { $0.minimum == nil }.map(\.name)
        try expect(present == ["loguru", "imageio", "imageio_ffmpeg", "safetensors", "einops", "gguf", "opencv-python", "prometheus_client", "pydantic"],
                   "presence-only dependency list changed")
        env.packageVersions = Dictionary(uniqueKeysWithValues: present.map { ($0, "0.0.1.dev1") })
        try expect(env.isCompatible, "exact minimums should qualify")
        for package in present {
            env.packageVersions[package] = ""
            try expect(!env.isCompatible && env.versionIssues == ["缺少 \(package)"], "missing \(package) was accepted or not explained")
            env.packageVersions[package] = "any-installed-version"
            try expect(env.isCompatible, "presence-only dependency \(package) incorrectly requires a version")
        }
        for version in ["", "0.40.99", "0.41.0rc1", "0.41.0.dev1"] {
            env.diffusersVersion = version
            let issue = version.isEmpty ? "缺少 diffusers" : "diffusers \(version)，需要 ≥ 0.41.0"
            try expect(!env.isCompatible && env.compatibilityDetail.contains(issue), "missing or old diffusers was accepted or not explained: \(version)")
        }
        for version in ["0.41.0", "0.41.1", "0.42.0"] {
            env.diffusersVersion = version
            try expect(env.isCompatible, "qualifying diffusers rejected: \(version)")
        }
        env.diffusersVersion = "0.41.0"
        env.transformersVersion = "4.57.3"
        try expect(!env.isCompatible && env.compatibilityDetail.contains("transformers 4.57.3"), "old transformers was accepted or not explained")
        env.transformersVersion = "5.20.0"; env.torchaudioVersion = ""
        try expect(!env.isCompatible && env.versionIssues.contains("缺少 torchaudio"), "missing torchaudio was accepted")
        env.torchaudioVersion = "2.11.0"; env.mpsAvailable = false
        try expect(!env.isCompatible, "MPS unavailable was accepted")
        env.mpsAvailable = true; env.architecture = "x86_64"
        try expect(!env.isCompatible, "Intel environment was accepted")
    }

    static func environmentInstallation(_ root: URL) async throws {
        let fm = FileManager.default
        let layout = WorkspaceLayout(root.appendingPathComponent("managed ' 环境 with spaces").path)
        try layout.prepare()
        let requirements = root.appendingPathComponent("requirements.txt")
        try Data("torch==2.14.1\ntorchvision==0.29.1\ntorchaudio==2.11.0\ntransformers==5.19.0\ndiffusers==0.41.0\n".utf8).write(to: requirements)
        let cache = layout.root.appendingPathComponent("cache/miniconda")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let installer = cache.appendingPathComponent("fixture.sh")
        let shell = #"""
#!/bin/bash
set -eu
while [ "$#" -gt 0 ]; do
    if [ "$1" = '-p' ]; then prefix="$2"; shift 2; else shift; fi
done
mkdir -p "$prefix/bin"
printf '%s\n' installed >> manager-installs.txt
cat > "$prefix/bin/conda" <<'CONDA'
#!/bin/bash
set -eu
while [ "$#" -gt 0 ]; do
    if [ "$1" = '--prefix' ]; then prefix="$2"; shift 2; else shift; fi
done
mkdir -p "$prefix/bin"
cp fixture-python "$prefix/bin/python"
printf '%s\n' created >> environment-creates.txt
CONDA
chmod +x "$prefix/bin/conda"
"""#
        try Data(shell.utf8).write(to: installer)
        try expect(PyTorchEnvironmentInstaller.installationIssue(in: layout) != nil, "official Miniconda space restriction not detected")
        let distribution = MinicondaDistribution(url: URL(string: "https://fixture.invalid/fixture.sh")!, sha256: try PyTorchEnvironmentInstaller.digest(installer), requiresSpaceFreePrefix: false)
        let fakePython = layout.root.appendingPathComponent("fixture-python")
        let script = #"""
#!/bin/bash
set -eu
if [ "${3:-}" = '-m' ]; then
    if [ "${5:-}" = 'install' ]; then
        printf '%s\n' 'installing dependencies'
        if [ -f fail-install ]; then printf '%s\n' 'fixture dependency conflict'; exit 6; fi
        if [ -f slow-install ]; then
            sleep 30 &
            printf '%s' "$!" > child.pid
            wait
        fi
    fi
    exit 0
fi
printf '%s\n' 'LIGHTX2V_ENV:{"python":"3.11.14","architecture":"arm64","torch":"2.14.1","torchvision":"0.29.1","torchaudio":"2.11.0","transformers":"5.19.0","diffusers":"0.41.0","loguru":"0.0.1","imageio":"0.0.1","imageio_ffmpeg":"0.0.1","safetensors":"0.0.1","einops":"0.0.1","gguf":"0.0.1","opencv-python":"0.0.1","prometheus_client":"0.0.1","pydantic":"0.0.1","mps":true,"detail":"ready"}'
"""#
        try Data(script.utf8).write(to: fakePython)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePython.path)
        let logUpdates = InstallationLogUpdates()
        let installed = try await PyTorchEnvironmentInstaller.install(workspace: layout, requirements: requirements, distribution: distribution) { logUpdates.append($0) }
        let commands = logUpdates.lines.filter { $0.hasPrefix("$ ") }
        try expect(commands.count == 5, "installation must stream every command, including final environment probe")
        try expect(commands.contains { $0.contains("'pip' 'install'") } && commands.contains { $0.contains("'pip' 'check'") }, "pip commands missing from installation log")
        try expect(logUpdates.lines.contains("installing dependencies"), "command logging replaced process output")
        let logFiles = try fm.contentsOfDirectory(at: layout.root.appendingPathComponent("logs"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("environment-") }
            .flatMap { try fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { !$0.lastPathComponent.hasPrefix("0-") }
        try expect(logFiles.count == 5, "installation must retain all command log files")
        for file in logFiles {
            let log = try String(contentsOf: file, encoding: .utf8)
            try expect(log.hasPrefix("$ ") && commands.contains { log.hasPrefix($0 + "\n") }, "saved installation log missing the executed command")
        }
        try expect(installed.isCompatible && installed.pythonVersion == "3.11.14", "installation did not validate all versions")
        try expect(installed.executable == PyTorchEnvironmentInstaller.executable(in: layout).path, "installation chose a different environment")
        let copied = layout.root.appendingPathComponent("environments/requirements.txt")
        let copiedData = try Data(contentsOf: copied), expectedData = try Data(contentsOf: requirements)
        try expect(copiedData == expectedData, "requirements were changed or not copied")
        let candidates = PythonEnvironmentSearch.candidates(home: root, path: "", repository: "", workspace: layout.root.path, selected: "")
        try expect(candidates.contains(installed.executable), "new managed environment not discovered")
        _ = try await PyTorchEnvironmentInstaller.install(workspace: layout, requirements: requirements, distribution: distribution) { _ in }
        let managerInstalls = try String(contentsOf: layout.root.appendingPathComponent("manager-installs.txt"))
        let environmentCreates = try String(contentsOf: layout.root.appendingPathComponent("environment-creates.txt"))
        try expect(managerInstalls == "installed\n", "retry reinstalled Miniconda")
        try expect(environmentCreates == "created\n", "retry recreated Python")
        try Data().write(to: layout.root.appendingPathComponent("fail-install"))
        do {
            _ = try await PyTorchEnvironmentInstaller.install(workspace: layout, requirements: requirements, distribution: distribution) { _ in }
            throw Failure(message: "failed pip installation was accepted")
        } catch let error as Failure { throw error }
        catch { try expect(error.localizedDescription.contains("fixture dependency conflict"), "pip failure diagnostic lost") }
        try fm.removeItem(at: layout.root.appendingPathComponent("fail-install"))
        _ = try await PyTorchEnvironmentInstaller.install(workspace: layout, requirements: requirements, distribution: distribution) { _ in }
        let unrelated = WorkspaceLayout(root.appendingPathComponent("unrelated").path)
        try unrelated.prepare()
        try fm.createDirectory(at: PyTorchEnvironmentInstaller.manager(in: unrelated), withIntermediateDirectories: true)
        let sentinel = PyTorchEnvironmentInstaller.manager(in: unrelated).appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        do {
            _ = try await PyTorchEnvironmentInstaller.install(workspace: unrelated, requirements: requirements, distribution: distribution) { _ in }
            throw Failure(message: "unrelated existing directory overwritten")
        } catch let error as Failure { throw error }
        catch { try expect(fm.fileExists(atPath: sentinel.path), "unrelated contents deleted") }
        try Data().write(to: layout.root.appendingPathComponent("slow-install"))
        let task = Task { try await PyTorchEnvironmentInstaller.install(workspace: layout, requirements: requirements, distribution: distribution) { _ in } }
        let pidFile = layout.root.appendingPathComponent("child.pid")
        for _ in 0..<100 where !fm.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(25)) }
        try expect(fm.fileExists(atPath: pidFile.path), "slow installer did not start child")
        let pid = Int32(try String(contentsOf: pidFile))!
        task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true }
        try expect(cancelled, "installation did not report cancellation")
        try await Task.sleep(for: .milliseconds(200))
        try expect(kill(pid, 0) != 0, "cancel left an installation descendant running")
        try fm.removeItem(at: layout.root.appendingPathComponent("slow-install"))
        _ = try await PyTorchEnvironmentInstaller.install(workspace: layout, requirements: requirements, distribution: distribution) { _ in }
    }
}
