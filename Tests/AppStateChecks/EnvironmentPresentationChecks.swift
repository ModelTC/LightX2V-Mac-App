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
    let snapshots = ProcessInfo.processInfo.environment["LIGHTX2V_SETUP_SNAPSHOTS"].map { URL(fileURLWithPath: $0) } ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LightX2V-Environment-UI-Snapshots")
    let capture = CommandLine.arguments.contains("--environment-snapshots") || ProcessInfo.processInfo.environment["LIGHTX2V_SETUP_SNAPSHOTS"] != nil
    if capture { try fm.createDirectory(at: snapshots, withIntermediateDirectories: true) }
    @discardableResult
    func render<Content: View>(_ name: String, _ view: Content) async throws -> NSSize {
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
        return size
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
    var selectedSource = EnvironmentInstallSource.pypi
    var installedSource: EnvironmentInstallSource?
    var instructionsOpened = false
    let sourceBinding = Binding(get: { selectedSource }, set: { selectedSource = $0 })
    let interactive = EnvironmentSearchView(environments: [ready], searching: false, cancelled: false, checked: 1, total: 1,
        error: nil, installSource: sourceBinding, onSelect: { _ in }, onSearch: {}, onStop: {}, onInstructions: { instructionsOpened = true },
        onInstall: { installedSource = selectedSource }, onClose: {})
    let hosting = NSHostingView(rootView: interactive.environment(\.colorScheme, .light))
    window.contentView = hosting; window.setContentSize(hosting.fittingSize)
    try await Task.sleep(for: .milliseconds(200))
    func sourcePicker(_ view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        return view.subviews.compactMap(sourcePicker).first
    }
    guard let picker = sourcePicker(hosting), picker.segmentCount == 2,
          picker.label(forSegment: 0) == "pypi.org", picker.label(forSegment: 1) == "pypi.tsinghua",
          selectedSource == .pypi else { throw AppError.message("Install source options/default are incorrect") }
    let originalSize = hosting.fittingSize
    picker.selectedSegment = 1
    guard let action = picker.action else { throw AppError.message("Install source picker action missing") }
    NSApp.sendAction(action, to: picker.target, from: picker)
    try await Task.sleep(for: .milliseconds(200))
    let pickerFrame = picker.convert(picker.bounds, to: hosting)
    let actionY = hosting.isFlipped ? pickerFrame.maxY + 34 : pickerFrame.minY - 34
    func click(_ point: NSPoint) {
        let location = hosting.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
    }
    click(NSPoint(x: pickerFrame.midX, y: actionY))
    try await Task.sleep(for: .milliseconds(200))
    guard selectedSource == .tsinghua && installedSource == .tsinghua && hosting.fittingSize == originalSize else {
        throw AppError.message("Native mirror choice failed to reach installation or changed layout")
    }
    click(NSPoint(x: hosting.bounds.midX / 2, y: actionY))
    try await Task.sleep(for: .milliseconds(200))
    guard instructionsOpened else { throw AppError.message("Clicking manual instructions did not open the instructions") }
    if capture, let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: snapshots.appendingPathComponent("source-selected.png"))
    }
    let busyHost = NSHostingView(rootView: EnvironmentInstallView(workspace: layout, source: sourceBinding, progress: .init(.download), lines: [],
        installing: true, cancelled: false, error: nil, onCancel: {}, onRetry: {}, onSearch: {}, onClose: {}).environment(\.colorScheme, .light))
    window.contentView = busyHost; window.setContentSize(busyHost.fittingSize)
    try await Task.sleep(for: .milliseconds(200))
    guard let locked = sourcePicker(busyHost), !locked.isEnabled else { throw AppError.message("Install source must be locked during installation") }
    print("PASS native install source selection, official default, real installation/instructions button clicks, fixed layout and installation lock")
    try await render("manual-instructions", EnvironmentInstallInstructions(onClose: {}))
    var installationSize: NSSize?
    for (name, progress, installing, cancelled, error) in [
        ("downloading", EnvironmentInstallProgress(.download, detail: "Downloading Miniconda…", fraction: 0.42), true, false, Optional<String>.none),
        ("installing", EnvironmentInstallProgress(.dependencies), true, false, Optional<String>.none),
        ("cancelled", EnvironmentInstallProgress(.dependencies), false, true, nil),
        ("failed", EnvironmentInstallProgress(.dependencies), false, false, "安装推理依赖失败。请检查网络后继续安装。"),
        ("installed", EnvironmentInstallProgress(.completed, detail: "TorchLightX2V 已就绪，请重新点击“搜索本机环境”。"), false, false, nil)
    ] {
        let size = try await render(name, EnvironmentInstallView(workspace: layout, progress: progress, lines: ["Collecting torch", "Installing collected packages"],
                          installing: installing, cancelled: cancelled, error: error, onCancel: {}, onRetry: {}, onSearch: {}, onClose: {}))
        if let installationSize, size != installationSize {
            throw AppError.message("Installation status changed sheet size: " + name)
        }
        installationSize = size
    }
    let previousLanguage = LanguagePreferences.shared.selection
    defer { LanguagePreferences.shared.selection = previousLanguage }
    for code in L10n.languageCodes {
        LanguagePreferences.shared.selection = code
        let idleSize = try await render("choices-" + code, search([ready]))
        let searchSize = try await render("searching-" + code, search([], searching: true))
        let issueSize = try await render("issue-" + code, EnvironmentSearchView(
            environments: [ready], searching: false, cancelled: true, checked: 1, total: 1,
            error: "Search stopped", managedInstallIssue: "Use a writable workspace to install the environment.",
            onSelect: { _ in }, onSearch: {}, onStop: {}, onInstructions: {}, onInstall: {}, onClose: {}))
        guard idleSize == searchSize, idleSize == issueSize else {
            throw AppError.message("Search status changed sheet size in " + code)
        }
    }
    print("PASS all nine localized choices and fixed search/installation status layout")
}
