import SwiftUI
import AppKit
import LightX2VCore

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @FocusState private var headerFocused: Bool
    @State private var focusStep: GeneralSetupStep?
    @State private var focusRequest = 0
    @State var settings: AppSettings
    @State private var setupProgress = GeneralSetupProgress()
    @State private var saveError: String?
    @StateObject var downloads = GeneralSettingsDownloads()
    @State private var showsSaveDetails = false
    @State private var showEnvironments = false
    @State private var searching = false
    @State private var environments: [PythonEnvironment] = []
    @State private var checkedCount = 0
    @State private var totalCount = 0
    @State private var searchError: String?
    @State private var searchCancelled = false
    @State private var operationID: UUID?
    @State private var showInstallInstructions = false
    @State private var showInstaller = false
    @State private var installing = false
    @State private var installProgress = EnvironmentInstallProgress(.download)
    @State private var installLines: [String] = []
    @State private var installError: String?
    @State private var installCancelled = false

    private var layout: WorkspaceLayout { WorkspaceLayout(normalized(settings.workingDirectory)) }
    private var hasWorkDirectory: Bool { (try? WorkspaceLayout.validate(normalized(settings.workingDirectory))) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: 8) {
                workspaceCard
                sourceCard
                pythonCard
                runtimeCard
            }.padding(.horizontal, 24).padding(.bottom, 12)
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 10) {
                footerSummary.frame(maxWidth: .infinity, alignment: .leading)
                Button("关闭") { store.closeGeneralSettings() }.keyboardShortcut(.cancelAction)
                    .disabled(store.isPreparingWorkspace)
                Button("保存设置") { save() }
                    .buttonStyle(SettingsActionStyle(prominent: true))
                    .keyboardShortcut(.defaultAction).disabled(store.busy || !settings.hasGeneralPaths)
            }.padding(.horizontal, 24).frame(height: 60)
        }.frame(width: 640).background(Palette.canvas).foregroundStyle(Palette.ink)
            .buttonStyle(SettingsActionStyle())
            // Present neutrally. AppKit otherwise focuses and selects the first
            // path automatically; subsequent clicks and Tab retain native focus.
            .defaultFocus($headerFocused, true, priority: .userInitiated)
            .onAppear { updateGuide() }
            .onChange(of: settings) { _, _ in saveError = nil }
            // Resource transfers belong to this page. The post-save dependency
            // check belongs to the workspace and must survive its dismissal.
            .onDisappear { if store.isPreparingResources { store.setupTask?.cancel() } }
            .sheet(isPresented: $showEnvironments, onDismiss: { if searching { store.setupTask?.cancel() } }) {
                environmentPicker
            }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandMark(size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.needsGeneralSetup ? "欢迎使用 LightX2V" : "通用设置")
                    .font(.system(size: 18, weight: .semibold))
                Text("共 4 项配置，填写一次即可。").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Text("已配置 \(setupProgress.completed.count) / 4")
                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Palette.muted)
                .accessibilityLabel("通用设置已配置 \(setupProgress.completed.count) 项，共 4 项")
        }.padding(.horizontal, 24).frame(height: 64)
            .focusable().focusEffectDisabled().focused($headerFocused)
    }

    private var workspaceCard: some View {
        SettingsSection(step: .workspace, current: setupProgress.current, title: "LightX2V 工作目录",
                        status: pathStatus(.workspace), details: workspaceMessage, hasActions: false) {
            pathRow("LightX2V 工作目录", value: $settings.workingDirectory, directory: true, create: true)
        } actions: {
            EmptyView()
        }
    }

    private var workspaceMessage: String {
        if !store.generations.isEmpty && normalized(settings.workingDirectory) != store.settings.workingDirectory {
            return "更换后从空历史开始，原有记录与作品留在旧目录。"
        }
        return "配置、历史、图片、日志和缓存都保存在这里。"
    }

    private var sourceCard: some View {
        SettingsSection(step: .source, current: setupProgress.current, title: "LightX2V 源码目录",
                        status: pathStatus(.source),
                        details: "点击自动下载源码，或选择手动下载",
                        command: SourceDownloader.manualCommand,
                        linkTitle: "打开LightX2V GitHub", linkURL: URL(string: "https://github.com/ModelTC/LightX2V")) {
            pathRow("LightX2V 源码目录", value: $settings.repository, directory: true,
                    placeholder: "选择已有源码文件夹，或自动下载")
        } actions: {
            downloadButton("自动下载 LightX2V 源码", action: downloadSource)
            SettingsStatusLine(message: downloads.sourceMessage,
                               running: downloads.sourceRunning, cancel: { store.setupTask?.cancel() })
        }
    }

    private var pythonCard: some View {
        SettingsSection(step: .python, current: setupProgress.current, title: "PyTorch 环境",
                        status: pythonStatus, statusColor: pythonMatchesSaved && store.environmentReady ? Palette.green : Palette.muted,
                        details: "先搜索本机环境，若没有符合要求的环境，可以根据提示手动安装或选择自动安装") {
            pathRow("PyTorch 环境", value: $settings.python, directory: false)
        } actions: {
            Button { startSearch() } label: { Label("搜索本机环境", systemImage: "magnifyingglass") }
                .disabled(store.busy || !hasWorkDirectory)
            Button("检查环境") { store.checkEnvironment() }
                .disabled(store.busy || !pythonMatchesSaved)
            SettingsStatusLine(message: pythonMatchesSaved && store.environmentMessage != "尚未检查运行环境" ? pythonMessage : "",
                               running: pythonMatchesSaved && store.isChecking,
                               color: pythonMatchesSaved && store.environmentReady ? Palette.green : Palette.muted)
        }
    }

    private var pythonMatchesSaved: Bool {
        !store.needsGeneralSetup && normalized(settings.python) == store.settings.python
            && normalized(settings.repository) == store.settings.repository
            && normalized(settings.workingDirectory) == store.settings.workingDirectory
    }

    private var pythonStatus: String {
        guard setupProgress.completed.contains(.python) else { return pathStatus(.python) }
        guard pythonMatchesSaved else { return "待检查" }
        if store.isChecking { return "检查中" }
        if store.environmentReady { return "检查通过" }
        return store.environmentMessage == "尚未检查运行环境" ? "待检查" : "检查未通过"
    }

    private var pythonMessage: String {
        pythonMatchesSaved ? store.environmentMessage : "保存设置后自动检查环境依赖与 MPS。"
    }

    private var runtimeCard: some View {
        SettingsSection(step: .llama, current: setupProgress.current, title: "llama.cpp 二进制文件目录",
                        status: pathStatus(.llama),
                        details: "点击自动下载，或选择手动下载",
                        linkTitle: "打开llama.cpp发布页面", linkURL: URL(string: "https://github.com/ggml-org/llama.cpp/releases")) {
            pathRow("llama.cpp 二进制文件目录", value: $settings.promptEnhancement.runtimeDirectory, directory: true,
                    placeholder: "选择二进制文件所在目录，或自动下载")
        } actions: {
            downloadButton("自动下载 llama.cpp", action: downloadRuntime)
            SettingsStatusLine(message: downloads.runtimeMessage,
                               running: downloads.runtimeRunning, cancel: { store.setupTask?.cancel() })
        }
    }

    private func downloadButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label("自动下载", systemImage: "arrow.down.to.line") }
            .disabled(store.busy || !hasWorkDirectory).accessibilityLabel(label)
    }

    private func pathStatus(_ step: GeneralSetupStep) -> String {
        if setupProgress.completed.contains(step) { return "已配置" }
        let value: String
        switch step {
        case .workspace: value = settings.workingDirectory
        case .source: value = settings.repository
        case .python: value = settings.python
        case .llama: value = settings.promptEnhancement.runtimeDirectory
        }
        return normalized(value).isEmpty ? "未配置" : "路径无效"
    }

    private var footerError: String? { saveError ?? (store.needsGeneralSetup ? store.errorMessage : nil) }

    private var footerSummary: some View {
        Group {
            if let error = footerError {
                Button { showsSaveDetails = true } label: {
                    Label(error, systemImage: "exclamationmark.circle").lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(HoverButtonStyle(radius: 4)).foregroundStyle(Palette.accent).help(error)
                    .accessibilityLabel("查看设置错误详情")
                    .popover(isPresented: $showsSaveDetails) { SettingsDetails(title: "设置错误", message: error) }
            } else if store.isPreparingWorkspace {
                Label("正在保存设置…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(Palette.muted)
            } else if let step = setupProgress.current {
                Button { focusStep = step; focusRequest += 1 } label: {
                    Label(remainingMessage, systemImage: "circle.dashed").lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(HoverButtonStyle(radius: 4)).foregroundStyle(Palette.muted)
                    .accessibilityLabel("配置下一项：\(stepTitle(step))")
                    .disabled(store.busy)
            } else {
                Text("四项配置已填写完整").foregroundStyle(Palette.muted)
            }
        }.font(.system(size: 11)).frame(height: 24, alignment: .leading)
    }

    private var remainingMessage: String {
        let missing = GeneralSetupStep.allCases.filter { !setupProgress.completed.contains($0) }
        guard let first = missing.first else { return "" }
        return missing.count == 1 ? "还需配置：\(stepTitle(first))" : "还需配置 \(missing.count) 项 · 从\(stepTitle(first))开始"
    }

    private func stepTitle(_ step: GeneralSetupStep) -> String {
        switch step {
        case .workspace: return "工作目录"
        case .source: return "LightX2V 源码"
        case .python: return "PyTorch 环境"
        case .llama: return "llama.cpp 二进制文件目录"
        }
    }

    private func inputTitle(_ step: GeneralSetupStep) -> String {
        switch step {
        case .workspace: return "LightX2V 工作目录"
        case .source: return "LightX2V 源码目录"
        case .python: return "PyTorch 环境"
        case .llama: return "llama.cpp 二进制文件目录"
        }
    }

    private func pathRow(_ title: String, value: Binding<String>, directory: Bool, create: Bool = false,
                         placeholder: String? = nil) -> some View {
        HStack(spacing: 0) {
            PathInputField(title: title,
                           placeholder: placeholder ?? (directory ? "选择文件夹，或粘贴完整路径" : "选择环境中的 bin/python，或搜索本机环境"),
                           symbol: nil, text: value,
                           onCommit: { updateGuide() },
                           focusRequest: focusStep.map { inputTitle($0) == title } == true ? focusRequest : 0)
            chooseButton(title, value: value, directory: directory, create: create)
                .padding(.trailing, 6)
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1).allowsHitTesting(false))
        .disabled(store.busy)
    }

    private func chooseButton(_ title: String, value: Binding<String>, directory: Bool, create: Bool = false) -> some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
            panel.canCreateDirectories = create; panel.allowsMultipleSelection = false
            panel.title = directory ? "选择\(title)" : "选择 PyTorch 环境中的 Python 可执行文件"
            panel.directoryURL = value.wrappedValue.isEmpty ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: normalized(value.wrappedValue)).deletingLastPathComponent()
            if panel.runModal() == .OK, let url = panel.url {
                value.wrappedValue = url.path
                updateGuide()
            }
        } label: {
            Image(systemName: "folder").font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.muted).frame(width: 32, height: 32)
        }
            .buttonStyle(HoverButtonStyle(radius: 6))
            .accessibilityLabel("浏览\(title)").help("浏览\(title)")
            .disabled(store.busy)
    }

    private var environmentPicker: some View {
        EnvironmentSearchView(environments: environments, searching: searching, cancelled: searchCancelled,
                              checked: checkedCount, total: totalCount, error: searchError,
                              managedInstallIssue: PyTorchEnvironmentInstaller.installationIssue(in: layout),
                              onSelect: { environment in
                                  guard environment.isCompatible else { return }
                                  settings.python = environment.executable
                                  updateGuide(); store.setupTask?.cancel(); showEnvironments = false
                              }, onSearch: startSearch, onStop: { store.setupTask?.cancel() },
                              onInstructions: { showInstallInstructions = true }, onInstall: startInstall,
                              onClose: { store.setupTask?.cancel(); showEnvironments = false })
            .sheet(isPresented: $showInstallInstructions) {
                EnvironmentInstallInstructions(onClose: { showInstallInstructions = false })
            }
            .sheet(isPresented: $showInstaller, onDismiss: { if installing { store.setupTask?.cancel() } }) {
                EnvironmentInstallView(workspace: layout, progress: installProgress, lines: installLines,
                                       installing: installing, cancelled: installCancelled, error: installError,
                                       onCancel: { store.setupTask?.cancel() }, onRetry: startInstall,
                                       onSearch: { showInstaller = false; startSearch() },
                                       onClose: { showInstaller = false })
            }
    }

    private func normalized(_ value: String) -> String {
        (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    private func updateGuide() {
        let progress = GeneralSetupProgress(settings: settings)
        guard progress != setupProgress else { return }
        setupProgress = progress
    }

    private func downloadSource() {
        guard !store.busy else { return }
        saveError = nil; downloads.sourceMessage = "正在连接 GitHub…"; downloads.sourceRunning = true; store.isPreparingResources = true
        let workspace = layout; let token = UUID(); operationID = token
        store.setupTask = Task {
            defer { downloads.sourceRunning = false; operationID = nil; store.finishSetupTask() }
            do {
                let result = try await SourceDownloader.download(workspace: workspace) { message in
                    Task { @MainActor in if operationID == token { downloads.sourceMessage = message } }
                }
                settings.repository = result.directory
                updateGuide()
                downloads.sourceMessage = "已就绪 · LightX2V \(SourceDownloader.version)"
            } catch {
                if Task.isCancelled { downloads.sourceMessage = "下载已取消，可随时重试。" }
                else { downloads.sourceMessage = "下载失败：\(error.localizedDescription)" }
            }
        }
    }

    private func startSearch() {
        guard !store.busy else { return }
        saveError = nil; searchError = nil; environments = []; checkedCount = 0; totalCount = 0
        searching = true; searchCancelled = false; showEnvironments = true; store.isPreparingResources = true
        let token = UUID(); operationID = token
        let workspace = layout; let repository = normalized(settings.repository); let selected = normalized(settings.python)
        store.setupTask = Task {
            defer { searching = false; operationID = nil; store.finishSetupTask() }
            do {
                environments = try await PythonEnvironmentSearch.search(workspace: workspace, repository: repository, selected: selected) { values, checked, total in
                    Task { @MainActor in if operationID == token { environments = values; checkedCount = checked; totalCount = total } }
                }
            } catch {
                if Task.isCancelled { searchCancelled = true }
                else { searchError = error.localizedDescription }
            }
        }
    }

    private func downloadRuntime() {
        guard !store.busy, hasWorkDirectory else { return }
        saveError = nil; downloads.runtimeMessage = "正在连接 GitHub · b11564…"; downloads.runtimeRunning = true; store.isPreparingResources = true
        let workspace = layout; let token = UUID(); operationID = token
        store.setupTask = Task {
            defer { downloads.runtimeRunning = false; operationID = nil; store.finishSetupTask() }
            do {
                let result = try await LlamaRuntimeDownloader.download(workspace: workspace) { message in
                    Task { @MainActor in if operationID == token { downloads.runtimeMessage = message } }
                }
                settings.promptEnhancement.runtimeDirectory = result.directory
                updateGuide()
                downloads.runtimeMessage = "已就绪 · \(result.version)"
            } catch {
                if Task.isCancelled { downloads.runtimeMessage = "下载已取消，可随时重试。" }
                else { downloads.runtimeMessage = "llama.cpp 下载失败：\(error.localizedDescription)" }
            }
        }
    }

    private var bundledRequirements: URL? {
        Bundle.main.url(forResource: "requirements", withExtension: "txt")
            ?? Bundle.module.url(forResource: "requirements", withExtension: "txt")
    }

    private func startInstall() {
        guard !store.busy else { return }
        guard let bundledRequirements else { searchError = "APP 中的依赖文件缺失，请重新下载 APP。"; return }
        showInstaller = true; installing = true; installError = nil; installCancelled = false
        installLines = []; installProgress = .init(.download); store.isPreparingResources = true
        let workspace = layout; let token = UUID(); operationID = token
        store.setupTask = Task {
            defer { installing = false; operationID = nil; store.finishSetupTask() }
            do {
                _ = try await PyTorchEnvironmentInstaller.install(workspace: workspace, requirements: bundledRequirements) { value in
                    Task { @MainActor in
                        guard operationID == token else { return }
                        if value.stage.rawValue >= installProgress.stage.rawValue {
                            if value.logLine == nil { installProgress = value }
                            else if value.stage != installProgress.stage { installProgress = .init(value.stage) }
                        }
                        if let line = value.logLine, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let clean = line.replacingOccurrences(of: #"\x1b\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
                                .replacingOccurrences(of: "\r", with: "")
                            installLines.append(clean)
                        }
                    }
                }
                installProgress = .init(.completed, detail: "TorchLightX2V 已就绪，请重新点击“搜索本机环境”。")
            } catch {
                if Task.isCancelled { installCancelled = true }
                else { installError = error.localizedDescription }
            }
        }
    }

    private func save() {
        updateGuide()
        Task {
            do {
                try await store.applyGeneralSettings(settings)
            } catch { saveError = error.localizedDescription }
        }
    }
}

/// Shared live transfer state also lets native layout checks sample real redraws.
final class GeneralSettingsDownloads: ObservableObject {
    @Published var sourceMessage = ""
    @Published var sourceRunning = false
    @Published var runtimeMessage = ""
    @Published var runtimeRunning = false
}

private struct SettingsSection<Content: View, Actions: View>: View {
    let step: GeneralSetupStep
    let current: GeneralSetupStep?
    let title: String
    let status: String
    var statusColor: Color = Palette.muted
    let details: String
    var command: String?
    var linkTitle: String?
    var linkURL: URL?
    var hasActions = true
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions
    @State private var showsDetails = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(String(step.rawValue)).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(current == step ? Palette.onButton : Palette.muted)
                    .frame(width: 22, height: 22)
                    .background(current == step ? Palette.ink : Palette.selection, in: Circle())
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Button { showsDetails = true } label: { Image(systemName: "info.circle").frame(width: 20, height: 20) }
                    .buttonStyle(HoverButtonStyle(radius: 4)).foregroundStyle(Palette.muted)
                    .accessibilityLabel("查看\(title)详情")
                    .help("查看说明和完整状态")
                    .popover(isPresented: $showsDetails) { SettingsDetails(title: title, message: details, command: command, linkTitle: linkTitle, linkURL: linkURL) }
                Spacer(minLength: 4)
                Text(status).font(.system(size: 11, weight: .medium)).foregroundStyle(statusColor)
                    .frame(width: 80, alignment: .trailing).lineLimit(1)
            }.frame(height: 24)
            content.padding(.top, 4).frame(height: 48)
            if hasActions {
                HStack(spacing: 8) { actions }.padding(.top, 4).frame(height: 30)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(current == step ? Palette.surfaceSubtle.opacity(0.65) : Palette.canvas,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(current == step ? Palette.borderStrong : Palette.line.opacity(0.7), lineWidth: 1))
    }
}

private struct SettingsStatusLine: View {
    let message: String
    var running = false
    var color: Color = Palette.muted
    var cancel: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            Group {
                if running { ProgressView().controlSize(.mini) }
                else { Color.clear.accessibilityHidden(true) }
            }.frame(width: 14, height: 14)
            Text(message).lineLimit(1).truncationMode(.middle).help(message)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("取消下载") { cancel?() }
                .buttonStyle(HoverButtonStyle(radius: 4)).frame(width: 60)
                .opacity(running && cancel != nil ? 1 : 0)
                .disabled(!running || cancel == nil).accessibilityHidden(!running || cancel == nil)
        }
        .font(.system(size: 10)).foregroundStyle(color).frame(height: 18)
    }
}

private struct SettingsDetails: View {
    let title: String
    let message: String
    var command: String?
    var linkTitle: String?
    var linkURL: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message).font(.system(size: 11)).textSelection(.enabled)
                    if let command {
                        Text("手动下载 LightX2V " + SourceDownloader.version).font(.system(size: 11, weight: .medium))
                        ScrollView(.horizontal) {
                            Text(command).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true).padding(10)
                        }.frame(height: CGFloat(command.components(separatedBy: "\n").count) * 13 + 32)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 220)
            if let linkTitle, let linkURL {
                Link(destination: linkURL) { Text(linkTitle).underline().padding(.trailing, 6).padding(.vertical, 5) }
                    .font(.system(size: 11)).buttonStyle(HoverButtonStyle(radius: 6))
            }
        }.padding(18).frame(width: 360).foregroundStyle(Palette.ink)
    }
}
