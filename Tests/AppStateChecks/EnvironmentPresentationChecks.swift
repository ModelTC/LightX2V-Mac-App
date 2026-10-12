import AppKit
import SwiftUI
import LightX2VCore

@MainActor
func environmentPresentationChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("environment-ui-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let layout = WorkspaceLayout(root.appendingPathComponent("LightX2V 工作目录 with spaces").path)
    try layout.prepare()
    var old = PythonEnvironment(executable: "/opt/miniconda3/envs/torch/bin/python")
    old.pythonVersion = "3.11.14"; old.architecture = "arm64"; old.mpsAvailable = true
    old.torchVersion = "2.14.1"; old.torchvisionVersion = "0.29.1"; old.torchaudioVersion = "2.11.0"; old.transformersVersion = "4.57.3"
    old.diffusersVersion = "0.41.0"
    old.packageVersions = Dictionary(uniqueKeysWithValues: PyTorchRequirements.dependencies.filter { $0.minimum == nil }.map { ($0.name, "0.1.0") })
    var ready = old; ready.transformersVersion = "5.19.0"
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 650, height: 720),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.orderOut(nil); window.contentView = nil }
    let snapshots = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LightX2V-Environment-UI-Snapshots")
    let capture = CommandLine.arguments.contains("--environment-snapshots")
    if capture { try fm.createDirectory(at: snapshots, withIntermediateDirectories: true) }
    func render<Content: View>(_ name: String, _ view: Content) async throws {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        let size = hosting.fittingSize
        guard size.width <= 660 && size.height <= 710 else {
            throw AppError.message("Environment \(name) exceeds the settings sheet: \(size)")
        }
        window.contentView = hosting; window.setContentSize(size); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        hosting.layoutSubtreeIfNeeded()
        if capture, let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Snapshot failed") }
            try data.write(to: snapshots.appendingPathComponent(name + ".png"))
        }
        print("PASS environment \(name) fits compact settings sheet (\(Int(size.height)) pt)")
    }
    func search(_ values: [PythonEnvironment], searching: Bool = false) -> EnvironmentSearchView {
        EnvironmentSearchView(environments: values, searching: searching, cancelled: false, checked: values.count, total: 4,
                              error: nil, onSelect: { _ in }, onSearch: {}, onStop: {}, onInstructions: {}, onInstall: {}, onClose: {})
    }
    try await render("searching", search([], searching: true))
    try await render("no-matching-environment", search([old]))
    try await render("ready-environment", search([ready]))
    var missingDiffusers = ready; missingDiffusers.diffusersVersion = ""
    try await render("missing-diffusers", search([missingDiffusers]))
    var oldDiffusers = ready; oldDiffusers.diffusersVersion = "0.40.0"
    try await render("old-diffusers", search([oldDiffusers]))
    var missingPackage = ready; missingPackage.packageVersions["imageio_ffmpeg"] = ""
    try await render("missing-imageio-ffmpeg", search([missingPackage]))
    try await render("manual-instructions", EnvironmentInstallInstructions(onClose: {}))
    for (name, progress, installing, cancelled, error) in [
        ("installing", EnvironmentInstallProgress(.dependencies), true, false, Optional<String>.none),
        ("cancelled", EnvironmentInstallProgress(.dependencies), false, true, nil),
        ("failed", EnvironmentInstallProgress(.dependencies), false, false, "安装推理依赖失败。请检查网络后继续安装。"),
        ("installed", EnvironmentInstallProgress(.completed, detail: "TorchLightX2V 已就绪，请重新点击“搜索本机环境”。"), false, false, nil)
    ] {
        try await render(name, EnvironmentInstallView(workspace: layout, progress: progress, lines: ["Collecting torch", "Installing collected packages"],
                          installing: installing, cancelled: cancelled, error: error, onCancel: {}, onRetry: {}, onSearch: {}, onClose: {}))
    }
}
