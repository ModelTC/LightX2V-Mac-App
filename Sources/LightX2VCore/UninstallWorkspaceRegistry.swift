import Foundation
import Darwin

public enum UninstallWorkspaceRegistry {
    public static func roots(in supportRoot: URL) -> [URL] {
        let paths = (try? JSONFile.read([String].self, from: supportRoot.appendingPathComponent("workspaces.json"))) ?? []
        return paths.filter { $0.hasPrefix("/") }.map { AppUninstaller.normalized(URL(fileURLWithPath: $0).resolvingSymlinksInPath()) }
    }

    public static func record(workspaceRoot: URL, supportRoot: URL) throws {
        let root = AppUninstaller.normalized(workspaceRoot.resolvingSymlinksInPath())
        try AppUninstaller.validateSafePath(root, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        let fm = FileManager.default
        try fm.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        let lock = supportRoot.appendingPathComponent(".workspaces.lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AppError.message("Unable to record the workspace for uninstall cleanup.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw AppError.message("Unable to lock the workspace cleanup registry.") }
        defer { flock(descriptor, LOCK_UN) }
        let paths = Array(Set(roots(in: supportRoot).map(\.path) + [root.path])).sorted()
        try JSONFile.write(paths, to: supportRoot.appendingPathComponent("workspaces.json"))
    }
}
