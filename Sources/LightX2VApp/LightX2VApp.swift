import LightX2VCore
import SwiftUI
import AppKit

@main
struct LightX2VApplication: App {
    @ObservedObject private var language = LanguagePreferences.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        Window("LightX2V APP", id: "main") {
            Group {
                if store.showStartupSettings { FirstLaunchSetupView() }
                else { WorkspaceView() }
            }.environmentObject(store)
                .environment(\.locale, language.locale)
                .environment(\.layoutDirection, language.direction)
                .preferredColorScheme(.light)
                .background(ScreenFittingWindow())
                .onAppear { delegate.store = store; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); store.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("New creation")) { store.newGeneration() }.keyboardShortcut("n", modifiers: .command).disabled(store.isImportingImages)
            }
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("Settings…")) { store.showSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu(L10n.text("Generate")) {
                Button(L10n.text("Generate image")) { store.generate() }.keyboardShortcut(.return, modifiers: .command).disabled(!store.canGenerate)
                Button(L10n.text("Stop generation")) { store.stop() }.keyboardShortcut(".", modifiers: .command).disabled(!store.isRunning || store.isStopping)
                Divider()
                Button(L10n.text("Show run log")) { store.showLogs.toggle() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button(L10n.text("Show model preparation and generation settings")) { store.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.busy else { store?.persist(); store?.clearInputImages(); return .terminateNow }
        if store.isRunning {
            let alert = NSAlert()
            alert.messageText = L10n.text("Stop generation and quit?")
            alert.informativeText = L10n.text("The current image is unfinished. Quitting stops inference and releases model memory. Completed images are preserved.")
            alert.addButton(withTitle: L10n.text("Stop and quit")); alert.addButton(withTitle: L10n.text("Continue generating"))
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        store.prepareToTerminate { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
