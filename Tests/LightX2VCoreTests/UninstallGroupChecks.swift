import Foundation
import Darwin
import LightX2VCore

func uninstallGroupChecks() throws {
    let manager = FileManager.default
    guard let buffer = realpath(manager.temporaryDirectory.path, nil) else { throw AppError.message("Unable to resolve the test directory.") }
    let temporary = String(cString: buffer)
    free(buffer)
    let root = URL(fileURLWithPath: temporary, isDirectory: false).appendingPathComponent("uninstall-groups-" + UUID().uuidString, isDirectory: false)
    defer { try? manager.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let workspace = root.appendingPathComponent("workspace")
    let app = home.appendingPathComponent("Applications/LightX2V.app")
    let support = home.appendingPathComponent("Library/Application Support/LightX2V")
    let model = workspace.appendingPathComponent("cache/model/weights.bin")
    let output = workspace.appendingPathComponent("outputs/image.png")
    let external = root.appendingPathComponent("shared-model/weights.bin")
    let settings = workspace.appendingPathComponent("workspace.json")
    for path in [model, output, external, settings, support.appendingPathComponent("workspace_location.json")] {
        try manager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: path)
    }
    try manager.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": AppUninstaller.bundleIdentifier], format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let items: [UninstallItem] = [
        .init(path: model.deletingLastPathComponent().path, category: .models),
        .init(path: external.deletingLastPathComponent().path, category: .models, isExternal: true, defaultSelected: false),
        .init(path: workspace.appendingPathComponent("cache").path, category: .caches),
        .init(path: output.deletingLastPathComponent().path, category: .history),
        .init(path: settings.path, category: .settings),
        .init(path: workspace.appendingPathComponent("runtimes").path, category: .sources),
        .init(path: workspace.appendingPathComponent("environments").path, category: .environment),
        .init(path: app.path, category: .application),
        .init(path: support.path, category: .settings),
        .init(path: home.appendingPathComponent("Library/Caches/app.lightx2v.desktop").path, category: .caches)
    ]
    let plan = AppUninstallPlan(items: items, workspaceRoots: [workspace], applicationURL: app,
                                supportRoot: support, homeDirectory: home, preferenceDomains: [])
    let grouped = UninstallGroup.allCases.flatMap { plan.items(in: $0) }
    try expect(grouped.count == items.count && Set(grouped.map(\.id)) == Set(items.map(\.id)), "uninstall groups lost or duplicated paths")
    try expect(plan.items(in: .workspace).contains { $0.path == settings.path }, "workspace records grouped with app settings")
    try expect(plan.items(in: .application).contains { $0.path == support.path }, "app configuration grouped with workspace data")
    try expect(!plan.items(in: .models).allSatisfy(\.defaultSelected), "external models became a default selection")
    for mask in 0..<8 {
        let groups = Set(UninstallGroup.allCases.enumerated().compactMap { index, group in mask & (1 << index) != 0 ? group : nil })
        let selection = try AppUninstaller.selection(from: plan, selectedIDs: plan.selectedIDs(for: groups))
        if !groups.contains(.models) {
            for path in [model, external] {
                try expect(!selection.deletionURLs.contains { path.path == $0.path || path.path.hasPrefix($0.path + "/") }, "group selection deletes retained model weights")
            }
        }
    }
    let workspaceOnly = try AppUninstaller.selection(from: plan, selectedIDs: plan.selectedIDs(for: [.workspace]))
    for path in workspaceOnly.deletionURLs { try manager.removeItem(at: path) }
    try expect(manager.fileExists(atPath: model.path) && manager.fileExists(atPath: external.path), "workspace cleanup deleted model weights")
    try expect(manager.fileExists(atPath: app.path) && manager.fileExists(atPath: support.path), "workspace cleanup deleted app or preferences")
    try expect(!manager.fileExists(atPath: output.path) && !manager.fileExists(atPath: settings.path), "workspace cleanup retained selected images or records")
    let nestedWorkspace = support.appendingPathComponent("workspaces/session")
    let notes = nestedWorkspace.appendingPathComponent("notes.txt")
    let nestedModel = nestedWorkspace.appendingPathComponent("models/model/weights.bin")
    for path in [notes, nestedModel] {
        try manager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: path)
    }
    let nestedPlan = AppUninstallPlan(items: [
        .init(path: support.path, category: .settings),
        .init(path: nestedModel.deletingLastPathComponent().path, category: .models),
        .init(path: nestedWorkspace.appendingPathComponent("cache").path, category: .caches)
    ], workspaceRoots: [nestedWorkspace], applicationURL: app, supportRoot: support, homeDirectory: home, preferenceDomains: [])
    for groups: Set<UninstallGroup> in [[.application], [.application, .models], [.application, .workspace, .models]] {
        let selection = try AppUninstaller.selection(from: nestedPlan, selectedIDs: nestedPlan.selectedIDs(for: groups))
        try expect(!selection.deletionURLs.contains { notes.path == $0.path || notes.path.hasPrefix($0.path + "/") }, "app cleanup deletes unlisted workspace files")
        if groups.contains(.models) {
            try expect(selection.deletionURLs.contains { nestedModel.path == $0.path || nestedModel.path.hasPrefix($0.path + "/") }, "workspace boundary blocks explicitly selected models")
        }
    }
    let sharedRootPlan = AppUninstallPlan(items: [
        .init(path: support.path, category: .settings),
        .init(path: app.path, category: .application)
    ], workspaceRoots: [support], applicationURL: app, supportRoot: support, homeDirectory: home, preferenceDomains: [])
    try expect(sharedRootPlan.items(in: .workspace).contains { $0.path == support.path }, "shared support/workspace root grouped with app configuration")
    let appOnly = try AppUninstaller.selection(from: sharedRootPlan, selectedIDs: sharedRootPlan.selectedIDs(for: [.application]))
    try expect(!appOnly.deletionURLs.contains { notes.path == $0.path || notes.path.hasPrefix($0.path + "/") }, "app cleanup deletes a shared support/workspace root")
    print("PASS three uninstall groups, eight combinations, external defaults and retained nested models")
}
