import AppKit
import SwiftUI
import LightX2VCore

@MainActor
func creationSettingsChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("creation-settings-" + UUID().uuidString)
    let previous = ProcessInfo.processInfo.environment["LIGHTX2V_APP_STATE_DIR"]
    let support = root.appendingPathComponent("support")
    setenv("LIGHTX2V_APP_STATE_DIR", support.path, 1)
    defer {
        if let previous { setenv("LIGHTX2V_APP_STATE_DIR", previous, 1) } else { unsetenv("LIGHTX2V_APP_STATE_DIR") }
        try? fm.removeItem(at: root)
    }
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AppError.message(message) }; print("PASS " + message)
    }
    let layout = WorkspaceLayout(root.appendingPathComponent("workspace").path)
    try layout.prepare()
    var settings = AppSettings.defaults
    settings.workingDirectory = layout.root.path; settings.python = "/usr/bin/false"
    settings.promptEnhancement.enabled = false
    let firstID = UUID(), secondID = UUID()
    let firstRequest = try InferenceRequest(settings: settings, prompt: "First", width: 512, height: 512, seed: 11, output: layout.outputs.appendingPathComponent("first/image.png").path)
    let secondRequest = try InferenceRequest(settings: settings, prompt: "Second", width: 1024, height: 1024, seed: 22, output: layout.outputs.appendingPathComponent("second/image.png").path)
    var first = Generation(creationID: firstID, request: firstRequest); first.status = .completed
    var second = Generation(creationID: secondID, request: secondRequest); second.status = .completed
    var firstSize = GenerationSize(); firstSize.selectResolution(.fiveTwelve); firstSize.selectAspectRatio(.landscape32)
    var secondSize = GenerationSize(); secondSize.selectResolution(.twoK); secondSize.selectAspectRatio(.portrait916)
    let profiles = [firstID.uuidString: CreationSettings(size: firstSize, enhancementEnabled: false), secondID.uuidString: CreationSettings(size: secondSize, enhancementEnabled: true)]
    try JSONFile.write(WorkspaceData(settings: settings, generations: [second, first], hasCompletedGeneralSetup: true, creationSettings: profiles, activeCreationID: firstID), to: layout.state)
    try JSONFile.write(WorkspaceLocation(workingDirectory: layout.root.path), to: support.appendingPathComponent("workspace_location.json"))
    let store = AppStore()
    try check(store.selectedID == first.id && store.generationSize.resolution == .fiveTwelve && store.generationSize.aspectRatio == .landscape32 && !store.settings.promptEnhancement.enabled,
              "startup restores the active creation's last edits instead of its generation snapshot")
    store.generationSize.selectResolution(.oneK); store.generationSize.selectAspectRatio(.portrait34)
    var saved = try JSONFile.read(WorkspaceData.self, from: layout.state)
    try check(saved.creationSettings[firstID.uuidString]?.parameters == CreationSettings(size: store.generationSize).parameters,
              "each resolution and ratio edit immediately reaches workspace.json")
    store.setPromptEnhancementEnabled(true)
    saved = try JSONFile.read(WorkspaceData.self, from: layout.state)
    try check(saved.creationSettings[firstID.uuidString]?.promptEnhancement.enabled == true, "PE switch is saved per creation immediately")
    store.selectedID = second.id
    try check(store.generationSize.resolution == .twoK && store.generationSize.aspectRatio == .portrait916 && store.settings.promptEnhancement.enabled,
              "history selection restores its own size, ratio and PE state")
    store.setPromptEnhancementEnabled(false)
    store.selectedID = first.id
    try check(store.generationSize.resolution == .oneK && store.generationSize.aspectRatio == .portrait34 && store.settings.promptEnhancement.enabled,
              "returning to a creation restores edits made after its last generation")
    var sibling = Generation(creationID: firstID, request: firstRequest); sibling.status = .completed
    store.generations.append(sibling); store.selectedID = sibling.id
    try check(store.generationSize.resolution == .oneK && store.generationSize.aspectRatio == .portrait34,
              "selecting another run within the same creation never restores an old run's parameters")
    store.selectedID = second.id
    try check(!store.settings.promptEnhancement.enabled, "PE choices do not leak between creations")
    let reopened = AppStore()
    try check(reopened.selectedID == second.id && reopened.generationSize.resolution == .twoK && !reopened.settings.promptEnhancement.enabled,
              "relaunch restores the last visited creation and its edited parameters")
    let host = NSHostingView(rootView: GenerationParametersView().environmentObject(store).preferredColorScheme(.light).frame(width: 280).padding(16))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 312, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.contentView = nil }
    host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100))
    func segmented(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        return view.subviews.lazy.compactMap { segmented(in: $0) }.first
    }
    guard let control = segmented(in: host), control.segmentCount == 3, let action = control.action else { throw AppError.message("Resolution control missing") }
    control.selectedSegment = 0
    NSApplication.shared.sendAction(action, to: control.target, from: control)
    saved = try JSONFile.read(WorkspaceData.self, from: layout.state)
    try check(store.generationSize.resolution == .fiveTwelve && saved.creationSettings[secondID.uuidString]?.parameters.resolution == 512,
              "native resolution control saves its change immediately")
    store.selectedID = first.id; store.selectedID = second.id
    host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100))
    try check(control.selectedSegment == 0 && store.generationSize.aspectRatio == .portrait916, "native parameter panel displays restored creation state")
    store.newGeneration()
    let draftID = store.currentCreationID
    try check(draftID != firstID && draftID != secondID && store.generationSize.resolution == .oneK && store.generationSize.aspectRatio == nil && store.settings.promptEnhancement.enabled,
              "new creation starts with 1K, adaptive and PE enabled")
    store.generationSize.selectResolution(.fiveTwelve); store.generationSize.selectAspectRatio(.square)
    store.setPromptEnhancementEnabled(false)
    let restoredDraft = AppStore()
    try check(restoredDraft.selectedID == nil && restoredDraft.currentCreationID == draftID && restoredDraft.generationSize.resolution == .fiveTwelve && restoredDraft.generationSize.aspectRatio == .square && !restoredDraft.settings.promptEnhancement.enabled,
              "an ungenerated draft's parameters survive relaunch")
    store.selectedID = first.id
    store.removeFromHistory(first)
    saved = try JSONFile.read(WorkspaceData.self, from: layout.state)
    try check(saved.creationSettings[firstID.uuidString] == nil && !saved.generations.contains { $0.creationID == firstID }, "deleting a creation removes its profile and its history together")
    try check(saved.generations.first?.request.seed == second.request.seed && saved.generations.first?.request.width == 1024,
              "editor changes never rewrite another run's parameter snapshot")
    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: layout.state)) as! [String: Any]
    json.removeValue(forKey: "creationSettings")
    var rejected = false
    do { _ = try JSONDecoder().decode(WorkspaceData.self, from: JSONSerialization.data(withJSONObject: json)) } catch { rejected = true }
    try check(rejected, "workspaces without the new creation dictionary are rejected without migration")
}
