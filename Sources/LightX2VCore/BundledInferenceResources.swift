import Foundation

/// Offline, versioned resources. Never replace user-managed source or runtime folders.
public enum BundledInferenceResources {
    public static let sourceArchive = "LightX2V-0.6.0.tar.gz"
    public static let runtimeArchive = "llama-b11583-bin-macos-arm64.tar.gz"
    public static let hashes = [
        sourceArchive: "2c070a2ee55248a4294572f9271f051e3b00129d24de83eb94352636a7d48cb6",
        runtimeArchive: "d23832f4b847a722a64c9bf57e518c3df81dfab325942182ff17792d5d33351f"
    ]
    public static func directory(in workspace: WorkspaceLayout) -> URL {
        workspace.runtimes.appendingPathComponent("bundled-LightX2V-0.6.0-llama-b11583")
    }
    public static func configure(_ settings: inout AppSettings) {
        guard !settings.workingDirectory.isEmpty else { return }
        let root = directory(in: WorkspaceLayout(settings.workingDirectory))
        settings.repository = root.appendingPathComponent("LightX2V-0.6.0").path
        settings.promptEnhancement.runtimeDirectory = root.appendingPathComponent("llama-b11583").path
    }
    public static func resource(_ name: String) throws -> URL {
        for bundle in [Bundle.main, Bundle.module] {
            if let url = bundle.resourceURL?.appendingPathComponent("Bundled").appendingPathComponent(name),
               FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw AppError.message("Bundled inference archive is missing: \(name)")
    }
    public static func prepare(in workspace: WorkspaceLayout) async throws {
        try workspace.prepare(); try Task.checkCancellation()
        let fm = FileManager.default
        let destination = directory(in: workspace)
        func validate(_ root: URL) throws {
            guard fm.fileExists(atPath: root.appendingPathComponent("LightX2V-0.6.0/lightx2v/infer.py").path) else {
                throw AppError.message("Bundled LightX2V source is incomplete.")
            }
            try LlamaRuntimeDownloader.validateRuntime(root.appendingPathComponent("llama-b11583").path)
        }
        if fm.fileExists(atPath: destination.path) {
            guard let marker = try? JSONFile.read([String: String].self, from: destination.appendingPathComponent(".bundled-resources.json")), marker == hashes else {
                throw AppError.message("The bundled runtime directory already contains unmanaged data. Original files were preserved: \(destination.path)")
            }
            try validate(destination); return
        }
        let staging = workspace.temporary.appendingPathComponent("bundled-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for name in [sourceArchive, runtimeArchive] {
            let archive = try resource(name)
            let digest = try await Task.detached(priority: .utility) { try PyTorchEnvironmentInstaller.digest(archive) }.value
            guard digest == hashes[name] else { throw AppError.message("Bundled archive checksum failed: \(name)") }
            let listing = try await SetupCommand.run("/usr/bin/tar", arguments: ["-tzf", archive.path], workspace: workspace, timeout: 60)
            let details = try await SetupCommand.run("/usr/bin/tar", arguments: ["-tvzf", archive.path], workspace: workspace, timeout: 60)
            guard listing.status == 0, details.status == 0 else { throw AppError.message("Unable to read bundled archive: \(name)") }
            // Both packages have one root; identical safety rules apply to source files and dylib links.
            let root = name == sourceArchive ? "LightX2V-0.6.0" : "llama-b11583"
            try LlamaRuntimeDownloader.validateArchive(paths: listing.output, details: details.output, version: "b11583", expectedRoot: root)
            let extraction = try await SetupCommand.run("/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", staging.path], workspace: workspace, timeout: 120)
            guard extraction.status == 0 else { throw AppError.message("Unable to extract bundled archive: \(name)") }
            try Task.checkCancellation()
        }
        try validate(staging)
        try JSONFile.write(hashes, to: staging.appendingPathComponent(".bundled-resources.json"))
        try Task.checkCancellation()
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: destination)
    }
}
