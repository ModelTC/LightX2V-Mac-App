import Foundation
import Darwin
import LightX2VCore

func appUninstallerChecks() throws {
    let fm = FileManager.default
    guard let buffer = realpath(fm.temporaryDirectory.path, nil) else { throw AppError.message("Unable to resolve the uninstall test directory.") }
    let temporary = String(cString: buffer)
    free(buffer)
    let root = URL(fileURLWithPath: temporary, isDirectory: false).appendingPathComponent("uninstall-checks-\(UUID().uuidString)", isDirectory: false)
    defer { try? fm.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let workspace = WorkspaceLayout(root.appendingPathComponent("workspace 中文 spaces").path)
    let support = home.appendingPathComponent("Library/Application Support/LightX2V APP")
    try workspace.prepare()
    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    let app = home.appendingPathComponent("Applications/LightX2V.app")
    try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let metadata = ["CFBundleIdentifier": AppUninstaller.bundleIdentifier]
    try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    func file(_ path: URL, contents: String = "fixture") throws {
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: path)
    }
    var settings = AppSettings.defaults
    settings.workingDirectory = workspace.root.path
    settings.python = "/usr/bin/python3"
    let external = root.appendingPathComponent("shared model")
    try file(external.appendingPathComponent("weights.bin"))
    settings.qwenImage21TurboInt8.modelDirectory = external.path
    let linked = workspace.root.appendingPathComponent("models/shared-link")
    try fm.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: linked, withDestinationURL: external)
    settings.model = linked.path
    let preserved = workspace.root.appendingPathComponent("cache/keep-model")
    try file(preserved.appendingPathComponent("weights.bin"), contents: "retained model")
    try file(workspace.root.appendingPathComponent("cache/discard.bin"))
    settings.promptEnhancement.t2iDirectory = preserved.path
    let managed = workspace.root.appendingPathComponent("environments")
    try file(managed.appendingPathComponent("miniconda3/bin/python"))
    try JSONFile.write(["prefix": managed.appendingPathComponent("miniconda3").path], to: managed.appendingPathComponent("miniconda-install.json"))
    let previous = WorkspaceLayout(root.appendingPathComponent("previous workspace").path)
    try previous.prepare()
    var previousSettings = settings
    previousSettings.workingDirectory = previous.root.path
    previousSettings.qwenImage21TurboInt8.modelDirectory = root.appendingPathComponent("historical model").path
    try file(URL(fileURLWithPath: previousSettings.qwenImage21TurboInt8.modelDirectory).appendingPathComponent("weights.bin"))
    try JSONFile.write(WorkspaceData(settings: previousSettings), to: previous.state)
    try UninstallWorkspaceRegistry.record(workspaceRoot: previous.root, supportRoot: support)
    try UninstallWorkspaceRegistry.record(workspaceRoot: workspace.root, supportRoot: support)
    try UninstallWorkspaceRegistry.record(workspaceRoot: previous.root, supportRoot: support)
    try expect(Set(UninstallWorkspaceRegistry.roots(in: support).map(\.path)) == Set([workspace.root.path, previous.root.path]), "uninstall registry lost or duplicated a workspace")
    let partialWorkspace = WorkspaceLayout(root.appendingPathComponent("partial installer").path)
    try partialWorkspace.prepare()
    let partialEnvironment = partialWorkspace.root.appendingPathComponent("environments")
    let scaffolding = ["install.lock", "requirements.txt", "condarc"].map { partialEnvironment.appendingPathComponent($0) }
    for path in scaffolding { try file(path) }
    let unownedPython = partialEnvironment.appendingPathComponent("miniconda3/bin/python")
    try file(unownedPython, contents: "shared Python")
    try UninstallWorkspaceRegistry.record(workspaceRoot: partialWorkspace.root, supportRoot: support)
    let partialPlan = try AppUninstaller.discover(settings: settings, appURL: app, supportRoot: support, homeDirectory: home)
    try expect(scaffolding.allSatisfy { path in partialPlan.items.contains { $0.path == path.path && $0.category == .environment } }, "uninstall missed cancelled installer files")
    try expect(!partialPlan.items.contains { $0.path == partialEnvironment.path || $0.path == unownedPython.deletingLastPathComponent().deletingLastPathComponent().path }, "partial installer discovery claimed an unmarked Python prefix")
    let partialSelection = try AppUninstaller.selection(from: partialPlan, selectedIDs: Set(scaffolding.map(\.path)))
    for path in partialSelection.deletionURLs { try fm.removeItem(at: path) }
    try expect(scaffolding.allSatisfy { !fm.fileExists(atPath: $0.path) } && fm.fileExists(atPath: unownedPython.path), "cancelled installer cleanup deleted shared Python or retained its scaffolding")
    let legacy = WorkspaceLayout(root.appendingPathComponent("unregistered previous workspace").path)
    try legacy.prepare()
    let legacyModel = legacy.root.appendingPathComponent("models/legacy/Model")
    try file(legacyModel.appendingPathComponent("weights.bin"))
    var legacySettings = AppSettings.defaults
    legacySettings.workingDirectory = legacy.root.path
    legacySettings.model = legacyModel.path
    try JSONFile.write(WorkspaceData(settings: legacySettings), to: legacy.state)
    var referencingLegacy = settings
    referencingLegacy.qwenImage21TurboInt8.modelDirectory = legacyModel.path
    let legacyPlan = try AppUninstaller.discover(settings: referencingLegacy, appURL: app, supportRoot: support, homeDirectory: home)
    try expect(legacyPlan.workspaceRoots.contains { $0.path == legacy.root.path } && legacyPlan.items.contains { $0.path == legacy.outputs.path && $0.defaultSelected }, "uninstaller missed a valid prior workspace referenced by configured resources")
    let unrelated = WorkspaceLayout(root.appendingPathComponent("shared unrelated directory").path)
    try unrelated.prepare()
    let unrelatedModel = unrelated.root.appendingPathComponent("models/Model")
    try file(unrelatedModel.appendingPathComponent("weights.bin"))
    try JSONFile.write(WorkspaceData(settings: legacySettings), to: unrelated.state)
    referencingLegacy.qwenImage21TurboInt8.modelDirectory = unrelatedModel.path
    let unrelatedPlan = try AppUninstaller.discover(settings: referencingLegacy, appURL: app, supportRoot: support, homeDirectory: home)
    try expect(!unrelatedPlan.workspaceRoots.contains { $0.path == unrelated.root.path } && unrelatedPlan.items.contains { $0.path == unrelatedModel.path && $0.isExternal && !$0.defaultSelected }, "a mismatched workspace record claimed a shared directory")
    let domain = "app.lightx2v.desktop"
    let preferences = home.appendingPathComponent("Library/Preferences/\(domain).plist")
    try file(preferences)
    let caseModel = workspace.root.appendingPathComponent("models/CaseModel")
    let caseAlias = workspace.root.appendingPathComponent("models/casemodel")
    try file(caseModel.appendingPathComponent("weights.bin"))
    var aliases = settings
    aliases.model = caseModel.path
    aliases.qwenImage21TurboInt8.modelDirectory = caseAlias.path
    if fm.fileExists(atPath: caseAlias.path) {
        let aliasPlan = try AppUninstaller.discover(settings: aliases, appURL: app, supportRoot: support, homeDirectory: home)
        let matching = aliasPlan.items.filter { $0.path.caseInsensitiveCompare(caseModel.path) == .orderedSame }
        try expect(matching.count == 1 && matching[0].path == caseModel.path, "case-insensitive model aliases produced conflicting uninstall choices")
        var selected = Set(aliasPlan.items.filter(\.defaultSelected).map(\.id))
        selected.remove(caseModel.path)
        let keepCaseModel = try AppUninstaller.selection(from: aliasPlan, selectedIDs: selected)
        try expect(!keepCaseModel.deletionURLs.contains { caseModel.path == $0.path || caseModel.path.hasPrefix($0.path + "/") }, "a kept model was deleted through another filename casing")
    } else {
        try file(caseAlias.appendingPathComponent("weights.bin"))
        let aliasPlan = try AppUninstaller.discover(settings: aliases, appURL: app, supportRoot: support, homeDirectory: home)
        try expect(aliasPlan.items.contains { $0.path == caseModel.path } && aliasPlan.items.contains { $0.path == caseAlias.path }, "case-sensitive model directories were incorrectly merged")
    }
    let blob = workspace.root.appendingPathComponent("cache/hf-blob")
    try file(blob, contents: "retained snapshot weights")
    let snapshot = workspace.root.appendingPathComponent("models/snapshot")
    try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: snapshot.appendingPathComponent("weights.safetensors"), withDestinationURL: blob)
    try fm.createSymbolicLink(at: snapshot.appendingPathComponent("loop"), withDestinationURL: snapshot)
    settings.qwenImage21TurboInt8.promptEnhancement.t2iDirectory = snapshot.path
    let keptLink = workspace.root.appendingPathComponent("kept-model-link")
    try fm.createSymbolicLink(at: keptLink, withDestinationURL: caseModel)
    settings.promptEnhancement.i2iDirectory = keptLink.path
    let plan = try AppUninstaller.discover(settings: settings, appURL: app, supportRoot: support, homeDirectory: home)
    var keepSnapshot = Set(plan.items.filter(\.defaultSelected).map(\.id))
    keepSnapshot.remove(snapshot.path)
    let snapshotSelection = try AppUninstaller.selection(from: plan, selectedIDs: keepSnapshot)
    try expect(snapshotSelection.retainedURLs.contains { $0.path == blob.path }, "retained snapshot weights did not protect their backing cache blob")
    try expect(!snapshotSelection.deletionURLs.contains { $0.path == blob.path || blob.path.hasPrefix($0.path + "/") }, "cache cleanup deleted retained model weight targets")
    let keepLinkSelection = try AppUninstaller.selection(from: plan, selectedIDs: Set(plan.items.filter(\.defaultSelected).map(\.id)))
    try expect(keepLinkSelection.retainedURLs.contains { $0.path == caseModel.path }, "a retained model link did not protect its resolved target")
    try expect(!keepLinkSelection.deletionURLs.contains { $0.path == caseModel.path || caseModel.path.hasPrefix($0.path + "/") }, "a selected models parent deleted the target of a kept link")
    try expect(plan.items.contains { $0.path == app.path && $0.category == .application }, "uninstaller missed application")
    try expect(plan.items.contains { $0.path == external.path && $0.isExternal && !$0.defaultSelected }, "external model must be an explicit choice")
    try expect(plan.items.contains { $0.path == linked.path && $0.isExternal && !$0.defaultSelected }, "model symlink must be an explicit choice")
    try expect(plan.items.contains { $0.path == managed.path && $0.category == .environment && $0.defaultSelected }, "uninstaller missed marker-owned environment")
    try expect(!plan.items.contains { $0.path.hasPrefix("/usr") }, "uninstaller inferred a shared Python installation")
    try expect(plan.items.contains { $0.path == previousSettings.qwenImage21TurboInt8.modelDirectory }, "registered workspace model was not discovered")
    try expect(plan.items.contains { $0.path == workspace.state.path && $0.category == .settings }, "workspace configuration and history were not grouped with settings")
    let deleteOne = workspace.root.appendingPathComponent("models/delete-only-this")
    let unknownSibling = workspace.root.appendingPathComponent("models/unconfigured-sibling")
    try file(deleteOne.appendingPathComponent("weights.bin"))
    try file(unknownSibling.appendingPathComponent("weights.bin"), contents: "keep sibling")
    var oneModel = settings
    oneModel.model = deleteOne.path
    let childPlan = try AppUninstaller.discover(settings: oneModel, appURL: app, supportRoot: support, homeDirectory: home)
    let childOnly = try AppUninstaller.selection(from: childPlan, selectedIDs: [deleteOne.path])
    try expect(childOnly.deletionURLs.map(\.path) == [deleteOne.path], "selecting one model expanded deletion into its parent")
    for path in childOnly.deletionURLs { try fm.removeItem(at: path) }
    try expect(fm.fileExists(atPath: unknownSibling.appendingPathComponent("weights.bin").path), "single-model cleanup deleted an unlisted sibling")
    let selectedAncestor = workspace.root.appendingPathComponent("code/nested-selection")
    let keptParent = selectedAncestor.appendingPathComponent("kept-parent")
    let selectedChild = keptParent.appendingPathComponent("selected-child")
    let keptSibling = keptParent.appendingPathComponent("unknown-sibling")
    let removedSibling = selectedAncestor.appendingPathComponent("selected-by-ancestor")
    for path in [selectedChild, keptSibling, removedSibling] { try file(path.appendingPathComponent("data")) }
    let nestedPlan = AppUninstallPlan(items: [.init(path: selectedAncestor.path, category: .sources),
                                            .init(path: keptParent.path, category: .sources, defaultSelected: false),
                                            .init(path: selectedChild.path, category: .sources)],
                                      workspaceRoots: [workspace.root], applicationURL: app, supportRoot: support,
                                      homeDirectory: home, preferenceDomains: [])
    let nested = try AppUninstaller.selection(from: nestedPlan, selectedIDs: [selectedAncestor.path, selectedChild.path])
    for path in nested.deletionURLs { try fm.removeItem(at: path) }
    try expect(!fm.fileExists(atPath: selectedChild.path) && !fm.fileExists(atPath: removedSibling.path)
               && fm.fileExists(atPath: keptSibling.appendingPathComponent("data").path), "nested child selection discarded kept parent contents or skipped an explicit child")
    let latePaths = [home.appendingPathComponent("Library/Caches/\(domain)"),
                     home.appendingPathComponent("Library/Saved Application State/\(domain).savedState"),
                     home.appendingPathComponent("Library/HTTPStorages/\(domain)")]
    for path in latePaths { try file(path.appendingPathComponent("created-on-exit")) }
    let lateSelection = try AppUninstaller.selection(from: plan, selectedIDs: Set(plan.items.filter(\.defaultSelected).map(\.id)))
    try expect(latePaths.allSatisfy { path in lateSelection.deletionURLs.contains { $0.path == path.path } }, "uninstall missed app data created after the preview")
    let decoded = try JSONDecoder().decode(AppUninstallPlan.self, from: JSONEncoder().encode(plan))
    try expect(decoded.items == plan.items, "uninstall plan did not survive helper serialization")

    let cache = workspace.root.appendingPathComponent("cache")
    let partial = try AppUninstaller.selection(from: plan, selectedIDs: [cache.path])
    try expect(!partial.deletionURLs.contains { preserved.path.hasPrefix($0.path + "/") || $0.path == preserved.path }, "uninstall parent included kept nested model")
    for url in partial.deletionURLs { try fm.removeItem(at: url) }
    try expect(fm.fileExists(atPath: preserved.appendingPathComponent("weights.bin").path), "uninstall deleted deselected nested model")
    try expect(!fm.fileExists(atPath: cache.appendingPathComponent("discard.bin").path), "uninstall failed to clean selected siblings")

    var defaults = Set(plan.items.filter(\.defaultSelected).map(\.id))
    defaults.remove(preferences.path)
    let keepPreferences = try AppUninstaller.selection(from: plan, selectedIDs: defaults)
    try expect(keepPreferences.preferenceDomains.isEmpty, "support-folder selection deleted a deselected preference domain")
    try expect(!keepPreferences.deletionURLs.contains { $0.path == external.path }, "default uninstall included shared model")
    defaults.insert(linked.path)
    let removeLink = try AppUninstaller.selection(from: plan, selectedIDs: defaults)
    for url in removeLink.deletionURLs where url.path == linked.path || url.path == linked.deletingLastPathComponent().path { try fm.removeItem(at: url) }
    try expect(!fm.fileExists(atPath: linked.path) && fm.fileExists(atPath: external.appendingPathComponent("weights.bin").path), "uninstall followed a model link into shared data or retained the selected link")

    func rejected(_ action: () throws -> Void) throws {
        var failed = false
        do { try action() } catch { failed = true }
        try expect(failed, "uninstall accepted an unsafe selection")
    }
    for path in ["/", "/Applications", "/System/Library", "/opt/homebrew", "/dev", home.path, home.appendingPathComponent("Documents").path] {
        try rejected {
            try AppUninstaller.validateDeletionTargets(.init(deletionURLs: [URL(fileURLWithPath: path)], retainedURLs: [], emptyParentURLs: [], preferenceDomains: [], homeDirectory: home))
        }
    }
    let mountLink = root.appendingPathComponent("dev-volume-link")
    try fm.createSymbolicLink(atPath: mountLink.path, withDestinationPath: "/dev")
    try AppUninstaller.validateDeletionTargets(.init(deletionURLs: [mountLink], retainedURLs: [], emptyParentURLs: [],
                                                     preferenceDomains: [], homeDirectory: home))
    let mountContainer = URL(fileURLWithPath: "/dev", isDirectory: false)
    let mountSupport = root.appendingPathComponent("mount-container-support")
    try UninstallWorkspaceRegistry.record(workspaceRoot: mountContainer, supportRoot: mountSupport)
    let mountFixture = workspace.root.appendingPathComponent("mount-container-fixture")
    try file(mountFixture.appendingPathComponent("data"))
    var mountSettings = AppSettings.defaults
    mountSettings.workingDirectory = workspace.root.path
    mountSettings.repository = mountFixture.path
    mountSettings.python = "/usr/bin/python3"
    let mountPlan = try AppUninstaller.discover(settings: mountSettings, appURL: app, supportRoot: mountSupport,
                                               homeDirectory: home, preferenceDomains: [])
    let mountSelection = try AppUninstaller.selection(from: mountPlan, selectedIDs: [mountFixture.path])
    try expect(mountPlan.workspaceRoots.contains { $0.path == mountContainer.path }, "uninstall rejected a mounted workspace container")
    try expect(mountSelection.deletionURLs.map(\.path) == [mountFixture.path], "mounted container changed the selected fixture deletion")
    try expect(!mountSelection.emptyParentURLs.contains { $0.path == mountContainer.path }, "uninstall scheduled an empty mounted workspace root for deletion")
    try rejected {
        try AppUninstaller.validateDeletionTargets(.init(deletionURLs: [], retainedURLs: [], emptyParentURLs: [mountContainer],
                                                         preferenceDomains: [], homeDirectory: home))
    }
    try rejected {
        try AppUninstaller.validateDeletionTargets(.init(deletionURLs: [], retainedURLs: [], emptyParentURLs: [], preferenceDomains: ["com.apple.finder"], homeDirectory: home))
    }
    let changed = workspace.root.appendingPathComponent("changing-parent")
    let original = changed.appendingPathComponent("models")
    try file(original.appendingPathComponent("model.bin"))
    let changedPlan = AppUninstallPlan(items: [.init(path: original.path, category: .models)], workspaceRoots: [workspace.root], applicationURL: app, supportRoot: support, homeDirectory: home, preferenceDomains: [])
    try fm.removeItem(at: changed)
    try fm.createSymbolicLink(at: changed, withDestinationURL: external)
    try rejected { _ = try AppUninstaller.selection(from: changedPlan, selectedIDs: [original.path]) }
    print("PASS uninstall discovery, registered workspaces, explicit shared models, managed environments, retained nested files, preferences, symlinks and protected paths")
}
