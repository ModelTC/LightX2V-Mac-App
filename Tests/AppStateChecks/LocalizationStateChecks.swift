import Foundation
import LightX2VCore

@MainActor
func languageTaskChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("language-task-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    setenv("LIGHTX2V_APP_STATE_DIR", root.path, 1)
    let store = AppStore()
    store.prompt = "Do not translate 中文"
    store.selectModel(.qwenImage21Turbo)
    store.activeModelDownload = .turbo; store.isPreparingResources = true
    let transfer = Task { _ = try? await Task.sleep(for: .seconds(30)) }
    store.setupTask = transfer
    defer { transfer.cancel(); LanguagePreferences.shared.selection = "en" }
    for code in L10n.languageCodes {
        LanguagePreferences.shared.selection = code
        store.showSettings = true
        store.closeGeneralSettings()
        try await Task.sleep(for: .milliseconds(10))
        guard !transfer.isCancelled, store.activeModelDownload == .turbo, store.isPreparingResources,
              store.prompt == "Do not translate 中文", store.selectedModel == .qwenImage21Turbo else {
            throw AppError.message("Language switch or settings dismissal interrupted transfer or inputs: " + code)
        }
    }
    transfer.cancel()
    store.activeModelDownload = nil; store.isPreparingResources = false; store.isChecking = true
    let probe = Task { _ = try? await Task.sleep(for: .seconds(30)) }
    store.setupTask = probe
    store.closeGeneralSettings()
    guard probe.isCancelled else { throw AppError.message("Closing settings no longer cancels its dependency probe") }
    print("PASS all nine language switches and settings dismissal preserve workspace transfers and raw inputs; owned dependency probes still cancel")
}
