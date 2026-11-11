import Foundation
import Darwin

public enum UninstallCategory: String, CaseIterable, Codable, Sendable {
    case application, models, sources, environment, history, caches, settings

    public var title: String {
        switch self {
        case .application: return "Application"
        case .models: return "Models"
        case .sources: return "Generation program files"
        case .environment: return "Managed Python environments"
        case .history: return "Generated images"
        case .caches: return "Caches and logs"
        case .settings: return "Settings and history"
        }
    }
}

/// User-facing choices map onto the detailed filesystem plan used by the helper.
public enum UninstallGroup: String, CaseIterable, Identifiable, Sendable {
    case models, workspace, application
    public var id: Self { self }
    public var title: String {
        switch self {
        case .models: return "Remove model weights"
        case .workspace: return "Remove workspace data"
        case .application: return "Remove app and settings"
        }
    }
    public var detail: String {
        switch self {
        case .models: return "Image generation and prompt enhancement model weights."
        case .workspace: return "Generated images, history, program files, managed Python environments, caches and logs."
        case .application: return "The app, preferences, workspace location records and application caches."
        }
    }
}

public struct UninstallItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let category: UninstallCategory
    public let isExternal: Bool
    public let defaultSelected: Bool
    public let preferenceDomain: String?

    public init(path: String, category: UninstallCategory, isExternal: Bool = false,
                defaultSelected: Bool = true, preferenceDomain: String? = nil) {
        self.path = path; self.category = category
        self.isExternal = isExternal; self.defaultSelected = defaultSelected
        self.preferenceDomain = preferenceDomain
    }
}

public struct AppUninstallPlan: Codable, Sendable {
    public let items: [UninstallItem]
    public let workspaceRoots: [URL]
    public let applicationURL: URL
    public let supportRoot: URL
    public let homeDirectory: URL
    public let preferenceDomains: [String]

    public init(items: [UninstallItem], workspaceRoots: [URL], applicationURL: URL,
                supportRoot: URL, homeDirectory: URL, preferenceDomains: [String]) {
        self.items = items; self.workspaceRoots = workspaceRoots; self.applicationURL = applicationURL
        self.supportRoot = supportRoot; self.homeDirectory = homeDirectory
        self.preferenceDomains = preferenceDomains
    }

    public func items(in group: UninstallGroup) -> [UninstallItem] {
        items.filter { self.group(for: $0) == group }
    }

    public func selectedIDs(for groups: Set<UninstallGroup>) -> Set<String> {
        Set(items.filter { groups.contains(group(for: $0)) }.map(\.id))
    }

    private func group(for item: UninstallItem) -> UninstallGroup {
        switch item.category {
        case .models: return .models
        case .application: return .application
        case .sources, .environment, .history: return .workspace
        case .settings, .caches:
            let inWorkspace = workspaceRoots.contains { item.path == $0.path || item.path.hasPrefix($0.path + "/") }
            return inWorkspace ? .workspace : .application
        }
    }

}

public struct AppUninstallSelection: Codable, Sendable {
    public let deletionURLs: [URL]
    public let retainedURLs: [URL]
    public let emptyParentURLs: [URL]
    public let preferenceDomains: [String]
    public let homeDirectory: URL

    public init(deletionURLs: [URL], retainedURLs: [URL], emptyParentURLs: [URL],
                preferenceDomains: [String], homeDirectory: URL) {
        self.deletionURLs = deletionURLs; self.retainedURLs = retainedURLs
        self.emptyParentURLs = emptyParentURLs; self.preferenceDomains = preferenceDomains
        self.homeDirectory = homeDirectory
    }
}

public enum AppUninstaller {
    public static let bundleIdentifier = "app.lightx2v.desktop"

    public static func discover(settings: AppSettings, appURL: URL, supportRoot: URL,
                                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                additionalWorkspaceRoots: [URL] = [],
                                preferenceDomains: [String] = [bundleIdentifier]) throws -> AppUninstallPlan {
        try Task.checkCancellation()
        let fm = FileManager.default
        let home = normalized(homeDirectory.resolvingSymlinksInPath())
        var roots = additionalWorkspaceRoots + UninstallWorkspaceRegistry.roots(in: supportRoot)
        if !settings.workingDirectory.isEmpty { roots.append(WorkspaceLayout(settings.workingDirectory).root) }
        let configured = [settings.python, settings.repository, settings.promptEnhancement.runtimeDirectory,
                          settings.qwenImage21Turbo.modelDirectory, settings.qwenImage21TurboInt8.modelDirectory,
                          settings.qwenImage21Turbo.promptEnhancement.t2iDirectory, settings.qwenImage21Turbo.promptEnhancement.i2iDirectory,
                          settings.qwenImage21TurboInt8.promptEnhancement.t2iDirectory, settings.qwenImage21TurboInt8.promptEnhancement.i2iDirectory]
        var checkedCandidates = Set<String>()
        for path in configured where path.hasPrefix("/") {
            try Task.checkCancellation()
            var candidate = normalized(URL(fileURLWithPath: path)).deletingLastPathComponent()
            // Prior versions kept only the current workspace locator. Recover
            // older workspaces only through explicitly configured resources.
            for _ in 0..<8 {
                if checkedCandidates.insert(candidate.path).inserted,
                   (try? validateWorkspaceRoot(candidate, homeDirectory: home)) != nil,
                   let saved = try? JSONFile.read(WorkspaceData.self, from: candidate.appendingPathComponent("workspace.json")),
                   !saved.settings.workingDirectory.isEmpty,
                   normalized(WorkspaceLayout(saved.settings.workingDirectory).root).path == candidate.path {
                    roots.append(candidate)
                }
                let parent = candidate.deletingLastPathComponent()
                if parent == candidate { break }
                candidate = parent
            }
        }
        roots = Array(Set(roots.map { normalized($0.resolvingSymlinksInPath()) })).sorted { $0.path < $1.path }
        for root in roots { try validateWorkspaceRoot(root, homeDirectory: home) }
        var items: [UninstallItem] = []
        func add(_ url: URL, _ category: UninstallCategory, external: Bool = false,
                 preferenceDomain: String? = nil, includeMissing: Bool = false) throws {
            let target = normalized(url)
            guard includeMissing || exists(target) else { return }
            try validateSafePath(target, homeDirectory: home)
            guard !items.contains(where: { $0.path == target.path }) else { return }
            let shared = external || isLink(target)
            items.append(.init(path: target.path, category: category, isExternal: shared,
                               defaultSelected: !shared, preferenceDomain: preferenceDomain))
        }
        var savedSettings = [settings]
        var resourcePaths: [(String, UninstallCategory)] = []
        for root in roots {
            try Task.checkCancellation()
            let layout = WorkspaceLayout(root.path)
            if let saved = try? JSONFile.read(WorkspaceData.self, from: layout.state) {
                savedSettings.append(saved.settings)
                for job in saved.generations {
                    try Task.checkCancellation()
                    resourcePaths.append((job.request.model, .models))
                    resourcePaths.append((job.request.repository, .sources))
                    if let enhancement = job.request.promptEnhancement {
                        resourcePaths += [(enhancement.t2iDirectory, .models), (enhancement.i2iDirectory, .models),
                                          (enhancement.runtimeDirectory, .sources)]
                    }
                }
            }
            for folder in ["code", "runtimes"] { try add(root.appendingPathComponent(folder), .sources, includeMissing: true) }
            try add(root.appendingPathComponent("models"), .models, includeMissing: true)
            for resource in environmentResources(in: root.appendingPathComponent("environments")) {
                try add(resource, .environment, includeMissing: true)
            }
            for folder in ["outputs"] { try add(root.appendingPathComponent(folder), .history, includeMissing: true) }
            try add(layout.state, .settings, includeMissing: true)
            for folder in ["cache", "tmp", "logs"] { try add(root.appendingPathComponent(folder), .caches, includeMissing: true) }
        }
        for value in savedSettings {
            try Task.checkCancellation()
            for model in [value.qwenImage21Turbo, value.qwenImage21TurboInt8] {
                resourcePaths += [(model.modelDirectory, .models), (model.promptEnhancement.t2iDirectory, .models),
                                  (model.promptEnhancement.i2iDirectory, .models)]
            }
            resourcePaths += [(value.repository, .sources), (value.promptEnhancement.runtimeDirectory, .sources)]
            let python = URL(fileURLWithPath: value.python)
            let environmentFolder = (0..<5).reduce(python) { url, _ in url.deletingLastPathComponent() }
            if !value.python.isEmpty && environmentFolder.lastPathComponent == "environments" && ownsEnvironment(in: environmentFolder) {
                let external = !roots.contains { contains(environmentFolder, in: $0) }
                for resource in environmentResources(in: environmentFolder) {
                    try add(resource, .environment, external: external, includeMissing: true)
                }
            }
        }
        for (path, category) in resourcePaths where !path.isEmpty {
            try Task.checkCancellation()
            guard path.hasPrefix("/") else { throw AppError.message("An uninstall resource path is not absolute. Check its configuration.") }
            let original = URL(fileURLWithPath: path).standardizedFileURL
            // A link within an owned workspace is removed as a link, including
            // links to models stored elsewhere, without walking into its target.
            let url = firstWorkspaceLink(in: original, roots: roots) ?? original
            let target = normalized(url)
            guard !roots.contains(where: { $0.path == target.path }) else { throw AppError.message("A resource points at the entire workspace. Check its configuration before uninstalling.") }
            let external = isLink(target) || !roots.contains { contains(target, in: $0) }
            try add(target, category, external: external)
        }
        let app = normalized(appURL)
        if app.pathExtension == "app", exists(app) {
            try validateApplication(app)
            try add(app, .application)
        }
        let support = normalized(supportRoot)
        try add(support, .settings)
        let domains = Array(Set(preferenceDomains)).sorted()
        for domain in domains {
            try validatePreferenceDomain(domain)
            try add(home.appendingPathComponent("Library/Preferences/\(domain).plist"), .settings,
                    preferenceDomain: domain, includeMissing: true)
            let byHost = home.appendingPathComponent("Library/Preferences/ByHost")
            for url in (try? fm.contentsOfDirectory(at: byHost, includingPropertiesForKeys: nil)) ?? []
                where url.lastPathComponent.hasPrefix(domain + ".") && url.pathExtension == "plist" {
                try add(url, .settings)
            }
            try add(home.appendingPathComponent("Library/Caches/\(domain)"), .caches, includeMissing: true)
            try add(home.appendingPathComponent("Library/Saved Application State/\(domain).savedState"), .settings, includeMissing: true)
            try add(home.appendingPathComponent("Library/HTTPStorages/\(domain)"), .caches, includeMissing: true)
        }
        return .init(items: items.sorted { $0.path < $1.path }, workspaceRoots: roots,
                     applicationURL: app, supportRoot: support, homeDirectory: home, preferenceDomains: domains)
    }

    public static func selection(from plan: AppUninstallPlan, selectedIDs: Set<String>) throws -> AppUninstallSelection {
        let fm = FileManager.default
        guard selectedIDs.isSubset(of: Set(plan.items.map(\.id))) else { throw AppError.message("The uninstall selection contains an unknown item.") }
        for root in plan.workspaceRoots { try validateWorkspaceRoot(root, homeDirectory: plan.homeDirectory) }
        for item in plan.items {
            guard item.path.hasPrefix("/") else { throw AppError.message("An uninstall resource path is not absolute.") }
            let url = URL(fileURLWithPath: item.path, isDirectory: false)
            try validateSafePath(url, homeDirectory: plan.homeDirectory)
            guard url.path == normalized(url).path else { throw AppError.message("An uninstall path changed. Reopen the uninstall options.") }
            if item.category == .application && selectedIDs.contains(item.id) && exists(url) { try validateApplication(url) }
            if let domain = item.preferenceDomain {
                try validatePreferenceDomain(domain)
                guard item.category == .settings,
                      item.path == plan.homeDirectory.appendingPathComponent("Library/Preferences/\(domain).plist").path else {
                    throw AppError.message("An uninstall preference path is invalid.")
                }
            }
        }
        let selected = plan.items.filter { selectedIDs.contains($0.id) }.map { URL(fileURLWithPath: $0.path, isDirectory: false) }
            .sorted { $0.pathComponents.count < $1.pathComponents.count }
        let unselected = plan.items.filter { !selectedIDs.contains($0.id) }.map { URL(fileURLWithPath: $0.path, isDirectory: false) }
        var choices = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.path, selectedIDs.contains($0.id)) })
        // A workspace nested inside app configuration still owns its unlisted
        // files. Only explicitly selected resources inside it inherit deletion.
        for root in plan.workspaceRoots where choices[root.path] == nil {
            choices[root.path] = false
        }
        // A kept container can contain an explicitly selected child. Its other
        // contents are retained during traversal instead of blocking that child.
        var retained = unselected.filter { parent in
            !selected.contains { child in child.path != parent.path && contains(child, in: parent) }
        }
        for link in unselected.filter(isLink) {
            let target = normalized(link.resolvingSymlinksInPath())
            if target.path != link.path, (try? validateSafePath(target, homeDirectory: plan.homeDirectory)) != nil { retained.append(target) }
        }
        retained += try modelLinkTargets(in: plan.items, selectedIDs: selectedIDs, homeDirectory: plan.homeDirectory)
        retained = Array(Set(retained))
        var targets: [URL] = []
        var visited = Set<String>()
        func include(_ url: URL, inheritedSelection: Bool) throws {
            guard visited.insert(url.path).inserted,
                  !retained.contains(where: { contains(url, in: $0) }) else { return }
            let remove = choices[url.path] ?? inheritedSelection
            let changesBelow = choices.contains { path, selected in
                path != url.path && path.hasPrefix(url.path + "/") && selected != remove
            }
            let keepsBelow = retained.contains { contains($0, in: url) }
            if !changesBelow && !keepsBelow {
                if remove {
                    if exists(url) { targets.append(url) }
                } else { retained.append(url) }
                return
            }
            // Keep ambiguous descendants of a link without walking its target.
            guard !isLink(url) else { retained.append(url); return }
            guard exists(url) else { return }
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try include(normalized(child), inheritedSelection: remove)
            }
        }
        for url in selected where !targets.contains(where: { contains(url, in: $0) }) {
            try include(url, inheritedSelection: true)
        }
        var parents = Set<URL>()
        for target in targets {
            for root in plan.workspaceRoots where contains(target, in: root) {
                var parent = target.deletingLastPathComponent()
                while contains(parent, in: root) {
                    if !retained.contains(where: { contains(parent, in: $0) }),
                       !unselected.contains(where: { contains(parent, in: $0) }),
                       (try? validateSafePath(parent, homeDirectory: plan.homeDirectory)) != nil { parents.insert(parent) }
                    if parent.path == root.path { break }
                    parent.deleteLastPathComponent()
                }
            }
        }
        let domains = plan.items.compactMap { selectedIDs.contains($0.id) ? $0.preferenceDomain : nil }
        let result = AppUninstallSelection(deletionURLs: targets, retainedURLs: retained,
                                          emptyParentURLs: parents.sorted { $0.pathComponents.count > $1.pathComponents.count },
                                          preferenceDomains: domains, homeDirectory: plan.homeDirectory)
        try validateDeletionTargets(result)
        return result
    }

    public static func validateDeletionTargets(_ selection: AppUninstallSelection) throws {
        for domain in selection.preferenceDomains { try validatePreferenceDomain(domain) }
        for url in selection.deletionURLs + selection.emptyParentURLs {
            try validateSafePath(url, homeDirectory: selection.homeDirectory)
            guard url.path == normalized(url).path else { throw AppError.message("An uninstall path changed. Reopen the uninstall options.") }
        }
        for target in selection.deletionURLs {
            guard !selection.retainedURLs.contains(where: { contains(target, in: $0) || contains($0, in: target) }) else {
                throw AppError.message("The uninstall selection includes files marked for keeping.")
            }
        }
    }

    static func validateSafePath(_ url: URL, homeDirectory: URL) throws {
        try validateSafePath(url, homeDirectory: homeDirectory, allowsVolumeRoot: false)
    }

    static func validateWorkspaceRoot(_ url: URL, homeDirectory: URL) throws {
        try validateSafePath(url, homeDirectory: homeDirectory, allowsVolumeRoot: true)
    }

    private static func validateSafePath(_ url: URL, homeDirectory: URL, allowsVolumeRoot: Bool) throws {
        let path = url.standardizedFileURL.path
        let safetyPath = path.lowercased()
        let system = ["/", "/Users", "/Applications", "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/opt", "/Volumes", "/tmp", "/private/tmp", "/private/var", "/private/var/folders", "/private/var/db", "/private/var/root", "/private/var/mobile", "/private/var/log", "/private/var/tmp", "/opt/homebrew"]
        let homeFolders = ["", "Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies", "Library", "Applications", ".Trash", ".ssh", ".aws", "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Preferences/ByHost", "Library/Saved Application State", "Library/HTTPStorages"]
        let homes = [homeDirectory, FileManager.default.homeDirectoryForCurrentUser]
        let protected = Set((system + homes.flatMap { home in homeFolders.map { home.appendingPathComponent($0).standardizedFileURL.path } }).map { $0.lowercased() })
        guard url.isFileURL, url.path.hasPrefix("/"), !path.utf8.contains(0), !protected.contains(safetyPath),
              !(url.pathComponents.count == 3 && url.pathComponents[1].lowercased() == "users"), !safetyPath.hasPrefix("/system/"), !safetyPath.hasPrefix("/usr/"),
              !safetyPath.hasPrefix("/bin/"), !safetyPath.hasPrefix("/sbin/"), !safetyPath.hasPrefix("/library/"),
              !safetyPath.hasPrefix("/private/etc/"), !safetyPath.hasPrefix("/private/var/db/") else {
            throw AppError.message("Refusing to uninstall a system or general-purpose directory: " + path)
        }
        // A mounted volume can live outside /Volumes. Removing a mount point
        // may erase its contents before the final directory removal fails.
        if !allowsVolumeRoot && !isLink(url) {
            let descriptor = Darwin.open(url.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor >= 0 {
                defer { close(descriptor) }
                var volume = statfs()
                guard fstatfs(descriptor, &volume) == 0 else {
                    throw AppError.message("Unable to inspect the uninstall volume: " + path)
                }
                let mountPath = withUnsafePointer(to: &volume.f_mntonname) { value in
                    value.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                guard normalized(url).path != normalized(URL(fileURLWithPath: mountPath)).path else {
                    throw AppError.message("Refusing to uninstall a mounted volume: " + path)
                }
            } else if errno != ENOENT && errno != ENOTDIR {
                throw AppError.message("Unable to inspect the uninstall volume: " + path)
            }
        }
    }

    static func normalized(_ url: URL) -> URL {
        let absolute = url.standardizedFileURL
        let parent = absolute.deletingLastPathComponent()
        guard parent.path != absolute.path else { return absolute }
        let resolvedParent: URL
        if let buffer = realpath(parent.path, nil) {
            defer { free(buffer) }
            resolvedParent = URL(fileURLWithPath: String(cString: buffer), isDirectory: false)
        } else {
            resolvedParent = normalized(parent)
        }
        // Use the actual leaf casing without following a final symlink. A
        // fixed directory hint keeps this identity stable before/after creation.
        let canonical = try? absolute.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        let leaf = canonical.map { URL(fileURLWithPath: $0, isDirectory: false).lastPathComponent } ?? absolute.lastPathComponent
        return resolvedParent.appendingPathComponent(leaf, isDirectory: false)
    }
    private static func contains(_ child: URL, in parent: URL) -> Bool {
        child.standardizedFileURL.path == parent.standardizedFileURL.path || child.standardizedFileURL.path.hasPrefix(parent.standardizedFileURL.path + "/")
    }
    private static func isLink(_ url: URL) -> Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil }
    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) || isLink(url) }
    private static func validatePreferenceDomain(_ domain: String) throws {
        guard (domain == bundleIdentifier || domain.hasPrefix("app.lightx2v.") || domain.hasPrefix("local.lightx2v.")),
              domain.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else {
            throw AppError.message("The uninstall preference domain is invalid.")
        }
    }
    private static func validateApplication(_ url: URL) throws {
        guard url.pathExtension == "app", let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier else { throw AppError.message("The uninstall target is not a LightX2V application.") }
    }
    private static func modelLinkTargets(in items: [UninstallItem], selectedIDs: Set<String>, homeDirectory: URL) throws -> [URL] {
        let fm = FileManager.default
        let models = items.filter { $0.category == .models && !selectedIDs.contains($0.id) }
            .map { normalized(URL(fileURLWithPath: $0.path).resolvingSymlinksInPath()) }
            .sorted { $0.pathComponents.count < $1.pathComponents.count }
        var inspected = Set<String>()
        var targets: [URL] = []
        for model in models {
            guard (try? validateSafePath(model, homeDirectory: homeDirectory)) != nil,
                  !inspected.contains(model.path) else { continue }
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: model.path, isDirectory: &directory), directory.boolValue else { continue }
            inspected.insert(model.path)
            var enumerationError: Error?
            guard let files = fm.enumerator(at: model, includingPropertiesForKeys: [.isSymbolicLinkKey], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw AppError.message("Unable to inspect retained model links: " + model.path) }
            for case let entry as URL in files {
                let file = normalized(entry)
                if selectedIDs.contains(file.path) {
                    files.skipDescendants()
                    continue
                }
                inspected.insert(file.path)
                if isLink(file) {
                    files.skipDescendants()
                    let target = normalized(file.resolvingSymlinksInPath())
                    if target.path != file.path, (try? validateSafePath(target, homeDirectory: homeDirectory)) != nil { targets.append(target) }
                }
            }
            if let enumerationError { throw enumerationError }
        }
        return targets
    }

    private static func environmentResources(in folder: URL) -> [URL] {
        let manager = folder.appendingPathComponent("miniconda3")
        let managerRecord = try? JSONFile.read([String: String].self, from: folder.appendingPathComponent("miniconda-install.json"))
        if managerRecord?["prefix"] == manager.path { return [folder] }
        // These files are written before a managed prefix is created. Listing
        // them individually also covers cancelled and rejected installations.
        var resources = ["install.lock", "requirements.txt", "condarc", "miniconda-install.json", "torchlightx2v-install.json"]
            .map { folder.appendingPathComponent($0) }
        let environment = manager.appendingPathComponent("envs/TorchLightX2V")
        let environmentRecord = try? JSONFile.read([String: String].self, from: folder.appendingPathComponent("torchlightx2v-install.json"))
        if environmentRecord?["prefix"] == environment.path { resources.append(environment) }
        return resources
    }

    private static func ownsEnvironment(in folder: URL) -> Bool {
        let manager = folder.appendingPathComponent("miniconda3")
        let markers = [("miniconda-install.json", manager), ("torchlightx2v-install.json", manager.appendingPathComponent("envs/TorchLightX2V"))]
        return markers.contains { name, prefix in
            let value = try? JSONFile.read([String: String].self, from: folder.appendingPathComponent(name))
            return value?["prefix"] == prefix.path
        }
    }
    private static func firstWorkspaceLink(in url: URL, roots: [URL]) -> URL? {
        for root in roots where contains(url, in: root) {
            var cursor = root
            for component in url.pathComponents.dropFirst(root.pathComponents.count) {
                cursor.appendPathComponent(component)
                if isLink(cursor) { return cursor }
            }
        }
        return nil
    }
}
