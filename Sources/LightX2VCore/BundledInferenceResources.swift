import Foundation

/// Offline, versioned resources. Never replace user-managed source or runtime folders.
public enum BundledInferenceResources {
    public static let sourceRevision = "0.6.1"
    public static let sourceRoot = "LightX2V-" + sourceRevision
    public static let sourceArchive = "LightX2V-0.6.1-minimal.tar.gz"
    public static let runtimeArchive = "llama-b11583-bin-macos-arm64.tar.gz"
    public static let hashes = [
        sourceArchive: "ab1a6271b262af2e2450ff1bc2d208f861b4a3a94188331257e49b0723dabc4c",
        runtimeArchive: "d23832f4b847a722a64c9bf57e518c3df81dfab325942182ff17792d5d33351f"
    ]
    public static func directory(in workspace: WorkspaceLayout) -> URL {
        workspace.runtimes.appendingPathComponent("bundled-LightX2V-0.6.1-minimal-v1-llama-b11583")
    }
    public static func configure(_ settings: inout AppSettings) {
        guard !settings.workingDirectory.isEmpty else { return }
        let root = directory(in: WorkspaceLayout(settings.workingDirectory))
        settings.repository = root.appendingPathComponent(sourceRoot).path
        settings.promptEnhancement.runtimeDirectory = root.appendingPathComponent("llama-b11583").path
    }
    public static func resource(_ name: String) throws -> URL {
        func find(in bundle: Bundle) -> URL? {
            guard let url = bundle.resourceURL?.appendingPathComponent("Bundled").appendingPathComponent(name),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        // Bundle.module traps when the development bundle is absent. A packaged
        // APP uses native Resources and must never initialize that fallback.
        if let url = find(in: Bundle.main) { return url }
        if Bundle.main.bundleURL.pathExtension != "app", let url = find(in: Bundle.module) { return url }
        throw AppError.message("Bundled inference archive is missing: \(name)")
    }
    public static func prepare(in workspace: WorkspaceLayout) async throws {
        try workspace.prepare(); try Task.checkCancellation()
        let fm = FileManager.default
        let destination = directory(in: workspace)
        func validate(_ root: URL) throws {
            for file in ["lightx2v/infer.py", "lightx2v_kernel/apple/python/lightx2v_kernel_apple/int8_gemm/gemm.py", "lightx2v_kernel/apple/pyproject.toml", "configs/platforms/mps/qwen_image_21_turbo_int8.json"] {
                guard fm.fileExists(atPath: root.appendingPathComponent(sourceRoot).appendingPathComponent(file).path) else {
                    throw AppError.message("Bundled LightX2V source is incomplete.")
                }
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
            let root = name == sourceArchive ? sourceRoot : "llama-b11583"
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
