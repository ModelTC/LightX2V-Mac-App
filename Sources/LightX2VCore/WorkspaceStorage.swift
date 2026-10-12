import Foundation

public struct WorkspaceLayout: Sendable {
    public let root: URL
    public init(_ path: String) { root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath() }
    public var state: URL { root.appendingPathComponent("workspace.json") }
    public var outputs: URL { root.appendingPathComponent("outputs") }
    public var code: URL { root.appendingPathComponent("code") }
    public var runtimes: URL { root.appendingPathComponent("runtimes") }
    public var temporary: URL { root.appendingPathComponent("tmp") }

    public static func validate(_ path: String) throws {
        guard !path.isEmpty else { throw AppError.message(L10n.english("Choose a LightX2V workspace first.")) }
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path != "/" else {
            throw AppError.message(L10n.english("Workspace must be an absolute path to a dedicated directory."))
        }
        let fm = FileManager.default
        var parent = URL(fileURLWithPath: path).standardizedFileURL
        while !fm.fileExists(atPath: parent.path), parent.path != "/" { parent.deleteLastPathComponent() }
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue, fm.isWritableFile(atPath: parent.path) else {
            throw AppError.message(L10n.english("Workspace is not writable. Choose a directory with write access."))
        }
    }

    public func prepare() throws {
        try Self.validate(root.path)
        for path in ["outputs", "code", "tmp", "logs", "cache/huggingface", "cache/torch", "cache/xdg", "cache/matplotlib", "cache/torch/inductor", "cache/triton", "cache/numba"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
    }

    public var environment: [String: String] {
        ["HF_HOME": root.appendingPathComponent("cache/huggingface").path,
         "HF_HUB_CACHE": root.appendingPathComponent("cache/huggingface/hub").path,
         "HUGGINGFACE_HUB_CACHE": root.appendingPathComponent("cache/huggingface/hub").path,
         "TORCH_HOME": root.appendingPathComponent("cache/torch").path,
         "TORCHINDUCTOR_CACHE_DIR": root.appendingPathComponent("cache/torch/inductor").path,
         "TRITON_CACHE_DIR": root.appendingPathComponent("cache/triton").path,
         "NUMBA_CACHE_DIR": root.appendingPathComponent("cache/numba").path,
         "XDG_CACHE_HOME": root.appendingPathComponent("cache/xdg").path,
         "MPLCONFIGDIR": root.appendingPathComponent("cache/matplotlib").path,
         "TMPDIR": temporary.path, "PYTHONDONTWRITEBYTECODE": "1"]
    }
}

/// Only this locator is stored in Application Support. All application data lives in the workspace.
public struct WorkspaceLocation: Codable {
    public var workingDirectory: String
    public init(workingDirectory: String) { self.workingDirectory = workingDirectory }
}

public enum WorkspaceStorage {
    /// macOS per-user app information; stores workspace_location.json so the workspace is remembered across launches.
    public static var applicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LightX2V APP")
    }

    public static func stateURL(locatorRoot: URL) throws -> URL {
        let locator = locatorRoot.appendingPathComponent("workspace_location.json")
        if FileManager.default.fileExists(atPath: locator.path) {
            let location = try JSONFile.read(WorkspaceLocation.self, from: locator)
            try WorkspaceLayout.validate(location.workingDirectory)
            let state = WorkspaceLayout(location.workingDirectory).state
            guard FileManager.default.fileExists(atPath: state.path) else {
                throw AppError.message(L10n.english("Workspace configuration unavailable: %@. Reconnect the disk and reopen the APP, or choose another directory.", [String(describing: location.workingDirectory)]))
            }
            return state
        }
        return locatorRoot.appendingPathComponent("workspace.json")
    }

    /// A different workspace starts with empty history. Original records and outputs stay in place.
    public static func save(_ snapshot: WorkspaceData, previousState: URL, locatorRoot: URL) throws -> WorkspaceData {
        let fm = FileManager.default
        var data = snapshot
        let layout = WorkspaceLayout(data.settings.workingDirectory)
        try layout.prepare()
        data.settings.workingDirectory = layout.root.path
        let switching = previousState.standardizedFileURL.resolvingSymlinksInPath() != layout.state
        if switching, fm.fileExists(atPath: layout.state.path) {
            throw AppError.message(L10n.english("This directory contains another workspace. Choose a different directory to preserve its settings and images."))
        }
        var created: [URL] = []
        let originalState = switching ? nil : try? Data(contentsOf: previousState)
        var wroteState = false
        do {
            if switching {
                if let previous = try? JSONFile.read(WorkspaceData.self, from: previousState),
                   !previous.settings.workingDirectory.isEmpty {
                    let old = WorkspaceLayout(previous.settings.workingDirectory)
                    let repository = URL(fileURLWithPath: data.settings.repository).standardizedFileURL.resolvingSymlinksInPath()
                    if repository.deletingLastPathComponent() == old.code {
                        guard !layout.root.path.hasPrefix(repository.path + "/") else {
                            throw AppError.message(L10n.english("Workspace cannot be inside the source directory being moved. Choose another directory."))
                        }
                        let target = layout.code.appendingPathComponent(repository.lastPathComponent)
                        guard !fm.fileExists(atPath: target.path) else {
                            throw AppError.message(L10n.english("New workspace already contains source with the same name. Select that source in settings or choose another workspace."))
                        }
                        // Track the destination before copying, so partial copies are removed on error.
                        created.append(target)
                        try fm.copyItem(at: repository, to: target)
                        data.settings.repository = target.path
                        if data.settings.config.hasPrefix(repository.path + "/") {
                            data.settings.config = target.path + data.settings.config.dropFirst(repository.path.count)
                        }
                    }
                    let runtime = URL(fileURLWithPath: data.settings.promptEnhancement.runtimeDirectory).standardizedFileURL.resolvingSymlinksInPath()
                    let installation = runtime.lastPathComponent == "bin" ? runtime.deletingLastPathComponent() : runtime
                    if installation.deletingLastPathComponent() == old.runtimes {
                        guard !layout.root.path.hasPrefix(installation.path + "/") else {
                            throw AppError.message(L10n.english("Workspace cannot be inside the llama.cpp directory being moved. Choose another directory."))
                        }
                        let target = layout.runtimes.appendingPathComponent(installation.lastPathComponent)
                        guard !fm.fileExists(atPath: target.path) else { throw AppError.message(L10n.english("New workspace already contains llama.cpp with the same name. Choose another directory.")) }
                        try fm.createDirectory(at: layout.runtimes, withIntermediateDirectories: true)
                        created.append(target)
                        try fm.copyItem(at: installation, to: target)
                        data.settings.promptEnhancement.runtimeDirectory = (runtime == installation ? target : target.appendingPathComponent("bin")).path
                    }
                }
            }
            if switching { data.generations = [] }
            try JSONFile.write(data, to: layout.state)
            wroteState = true
            // Commit the pointer last. A failed migration leaves the previous workspace usable.
            let locator = locatorRoot.appendingPathComponent("workspace_location.json")
            let current = try? JSONFile.read(WorkspaceLocation.self, from: locator)
            if current?.workingDirectory != layout.root.path {
                try JSONFile.write(WorkspaceLocation(workingDirectory: layout.root.path), to: locator)
            }
            return data
        } catch {
            if wroteState {
                if let originalState { try? originalState.write(to: layout.state, options: .atomic) }
                else { try? fm.removeItem(at: layout.state) }
            }
            for url in created { try? fm.removeItem(at: url) }
            throw error
        }
    }
}
