import SwiftUI
import AppKit

@main
struct LightX2VApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        Window("LightX2V APP", id: "main") {
            Group {
                if store.needsGeneralSetup { FirstLaunchSetupView() }
                else { WorkspaceView() }
            }.environmentObject(store)
                .preferredColorScheme(.light)
                .background(ScreenFittingWindow())
                .onAppear { delegate.store = store; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建创作") { store.newGeneration() }.keyboardShortcut("n", modifiers: .command).disabled(store.isImportingImages)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.showSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("生成") {
                Button("生成图片") { store.generate() }.keyboardShortcut(.return, modifiers: .command).disabled(!store.canGenerate)
                Button("停止生成") { store.stop() }.keyboardShortcut(".", modifiers: .command).disabled(!store.isRunning || store.isStopping)
                Divider()
                Button("显示运行日志") { store.showLogs.toggle() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("显示模型准备与生成参数") { store.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
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
            alert.messageText = "停止生成并退出？"
            alert.informativeText = "当前图片尚未生成完成。退出会停止推理并释放模型内存，已完成的作品会保留。"
            alert.addButton(withTitle: "停止并退出"); alert.addButton(withTitle: "继续生成")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        store.prepareToTerminate { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
