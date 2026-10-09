import SwiftUI
import AppKit
import LightX2VCore

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var guideAnimation
    @State var settings: AppSettings
    @State private var setupProgress = GeneralSetupProgress()
    @State private var saveError: String?
    @State private var downloadMessage = ""
    @State private var downloading = false
    @State private var showEnvironments = false
    @State private var searching = false
    @State private var environments: [PythonEnvironment] = []
    @State private var checkedCount = 0
    @State private var totalCount = 0
    @State private var searchError: String?
    @State private var searchCancelled = false
    @State private var operationID: UUID?

    private var layout: WorkspaceLayout { WorkspaceLayout(normalized(settings.workingDirectory)) }
    private var hasWorkDirectory: Bool { (try? WorkspaceLayout.validate(normalized(settings.workingDirectory))) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandMark(size: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.needsGeneralSetup ? "欢迎使用 LightX2V" : "通用设置")
                        .font(.system(size: 20, weight: .semibold))
                    Text(store.needsGeneralSetup ? "仅需首次配置，后续无需重复填写。" : "配置已保存，可随时在此修改。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Text("已填写 \(setupProgress.completed.count) / 3")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Palette.muted)
                    HStack(spacing: 4) {
                        ForEach(GeneralSetupStep.allCases, id: \.self) { step in
                            Capsule().fill(setupProgress.completed.contains(step) ? Palette.ink : Palette.line)
                                .frame(width: 22, height: 3)
                        }
                    }.accessibilityHidden(true)
                }.accessibilityLabel("通用设置已填写 \(setupProgress.completed.count) 项，共 3 项")
            }.padding(26)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsSection(step: .workspace, progress: setupProgress, animation: guideAnimation,
                                        title: "LightX2V 工作目录", subtitle: "配置、历史、图片、日志和缓存都保存在这里。") {
                            pathRow("LightX2V 工作目录", value: $settings.workingDirectory, directory: true, create: true)
                            if !store.generations.isEmpty && normalized(settings.workingDirectory) != store.settings.workingDirectory {
                                Text("更换后从空历史开始，原有记录与作品留在旧目录。")
                                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }
                        }.id(GeneralSetupStep.workspace)
                        SettingsSection(step: .source, progress: setupProgress, animation: guideAnimation,
                                        title: "LightX2V 源码目录", subtitle: "选择已有源码，或自动下载 GitHub main 的最新版本。") {
                            pathRow("LightX2V 源码目录", value: $settings.repository, directory: true,
                                    placeholder: "选择已有源码文件夹，或点击下方自动下载")
                            HStack(spacing: 10) {
                                Button { downloadSource() } label: {
                                    Label("自动下载", systemImage: "arrow.down.to.line")
                                }.disabled(store.busy || !hasWorkDirectory)
                                Text("存入工作目录 / code · 不含 Git 历史")
                                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                                Spacer(minLength: 0)
                            }.font(.system(size: 11))
                            if !downloadMessage.isEmpty {
                                HStack(spacing: 8) {
                                    if downloading { ProgressView().controlSize(.mini) }
                                    Text(downloadMessage).font(.system(size: 10)).foregroundStyle(Palette.muted)
                                    Spacer()
                                    if downloading { Button("取消下载") { store.setupTask?.cancel() }.font(.system(size: 10)) }
                                }
                            }
                        }.id(GeneralSetupStep.source)
                        SettingsSection(step: .python, progress: setupProgress, animation: guideAnimation,
                                        title: "PyTorch 环境", subtitle: "搜索已安装的 Python 环境，选择支持 Apple Silicon MPS 的一项。") {
                            pathRow("PyTorch 环境", value: $settings.python, directory: false)
                            HStack(spacing: 10) {
                                Button { startSearch() } label: { Label("搜索", systemImage: "magnifyingglass") }
                                    .disabled(store.busy || !hasWorkDirectory)
                                Text("检测 PyTorch 与 MPS · 不会安装或修改环境")
                                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                                Spacer(minLength: 0)
                            }.font(.system(size: 11))
                        }.id(GeneralSetupStep.python)
                    }.padding(.horizontal, 26).padding(.bottom, 22).subtleScrollbars()
                }.frame(maxHeight: 490)
                .onChange(of: setupProgress.current) { _, step in
                    if let step {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                            scroll.scrollTo(step, anchor: .center)
                        }
                    }
                }
            }
            if let error = saveError ?? (store.needsGeneralSetup ? store.errorMessage : nil) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(Palette.accent).lineLimit(3).help(error)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.horizontal, 26).padding(.bottom, 12)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 10) {
                if store.isPreparingWorkspace {
                    ProgressView().controlSize(.small)
                    Text("正在保存工作区…").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if store.needsGeneralSetup {
                    Button("退出") { NSApp.terminate(nil) }
                } else {
                    Button("取消") { store.setupTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                        .disabled(store.isPreparingWorkspace)
                }
                Button(store.needsGeneralSetup ? "保存并开始" : "保存设置") { save() }
                    .buttonStyle(SettingsActionStyle(prominent: true))
                    .keyboardShortcut(.defaultAction).disabled(store.busy || !settings.hasGeneralPaths)
            }.padding(.horizontal, 26).padding(.vertical, 18)
        }.frame(width: 660).background(Palette.canvas).foregroundStyle(Palette.ink)
            .buttonStyle(SettingsActionStyle())
            .onAppear { updateGuide(animated: false) }
            .onChange(of: settings) { _, _ in saveError = nil }
            .onDisappear { store.setupTask?.cancel() }
            .sheet(isPresented: $showEnvironments, onDismiss: { if searching { store.setupTask?.cancel() } }) {
                environmentPicker
            }
    }

    private func pathRow(_ title: String, value: Binding<String>, directory: Bool, create: Bool = false,
                         placeholder: String? = nil) -> some View {
        HStack(spacing: 4) {
            PathInputField(title: title,
                           placeholder: placeholder ?? (directory ? "选择文件夹，或粘贴完整路径" : "选择环境中的 bin/python，或点击下方搜索"),
                           symbol: directory ? "folder" : "terminal", text: value,
                           onCommit: { updateGuide() })
            Button(directory ? "选择…" : "手动选择…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
                panel.canCreateDirectories = create; panel.allowsMultipleSelection = false
                panel.title = directory ? "选择\(title)" : "选择 PyTorch 环境中的 Python 可执行文件"
                panel.directoryURL = value.wrappedValue.isEmpty ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: normalized(value.wrappedValue)).deletingLastPathComponent()
                if panel.runModal() == .OK, let url = panel.url {
                    value.wrappedValue = url.path
                    updateGuide()
                }
            }.font(.system(size: 11)).accessibilityLabel("选择\(title)")
                .padding(.trailing, 10)
        }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1))
            .disabled(store.busy)
    }

    private var environmentPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("选择 PyTorch 环境").font(.system(size: 18, weight: .semibold))
                    Text(searching ? "正在检测 \(checkedCount) / \(totalCount) 个环境…" : "\(searchCancelled ? "搜索已停止" : "检测完成") · 找到 \(environments.filter(\.mpsAvailable).count) 个可用环境")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if searching { ProgressView().controlSize(.small) }
            }
            ScrollView {
                VStack(spacing: 8) {
                    if environments.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "terminal").font(.system(size: 25)).foregroundStyle(Palette.muted)
                            Text(searching ? "正在查找 Conda、venv、pyenv 等常见环境" : "没有找到 Python 环境")
                                .font(.system(size: 12))
                        }.frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                    ForEach(environments) { environment in
                        Button {
                            settings.python = environment.executable
                            updateGuide()
                            store.setupTask?.cancel(); showEnvironments = false
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: environment.mpsAvailable ? "checkmark.circle.fill" : "minus.circle")
                                    .foregroundStyle(environment.mpsAvailable ? Palette.green : Palette.muted).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(environment.name).font(.system(size: 12, weight: .semibold))
                                        Spacer()
                                        if environment.mpsAvailable {
                                            Text("MPS 可用").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.green)
                                        }
                                    }
                                    Text(environment.executable).font(.system(size: 10, design: .monospaced))
                                        .lineLimit(2).foregroundStyle(Palette.muted).multilineTextAlignment(.leading)
                                    Text([environment.pythonVersion.isEmpty ? "" : "Python \(environment.pythonVersion)", environment.torchVersion.isEmpty ? "" : "PyTorch \(environment.torchVersion)", environment.mpsAvailable ? "" : environment.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.system(size: 10)).foregroundStyle(Palette.muted).multilineTextAlignment(.leading)
                                }
                            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(HoverButtonStyle(radius: 10, border: true, dimsWhenDisabled: false)).disabled(!environment.mpsAvailable).help(environment.detail)
                    }
                }.subtleScrollbars()
            }.frame(height: 290)
            if let searchError { Text(searchError).font(.system(size: 11)).foregroundStyle(Palette.accent) }
            Text("只搜索常见环境位置。未找到时，可返回手动选择环境中的 bin/python。")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            HStack {
                if searching { Button("停止搜索") { store.setupTask?.cancel() } }
                else { Button("重新搜索") { startSearch() }.disabled(store.busy) }
                Spacer()
                Button("返回") { store.setupTask?.cancel(); showEnvironments = false }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 610).background(Palette.canvas).foregroundStyle(Palette.ink)
            .buttonStyle(SettingsActionStyle())
    }

    private func normalized(_ value: String) -> String {
        (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    private func updateGuide(animated: Bool = true) {
        let progress = GeneralSetupProgress(settings: settings)
        guard progress != setupProgress else { return }
        withAnimation(animated && !reduceMotion ? .easeInOut(duration: 0.28) : nil) {
            setupProgress = progress
        }
    }

    private func downloadSource() {
        guard !store.busy else { return }
        saveError = nil; downloading = true; store.isPreparingResources = true
        let workspace = layout; let token = UUID(); operationID = token
        store.setupTask = Task {
            defer { downloading = false; operationID = nil; store.finishSetupTask() }
            do {
                let result = try await SourceDownloader.download(workspace: workspace) { message in
                    Task { @MainActor in if operationID == token { downloadMessage = message } }
                }
                settings.repository = result.directory
                updateGuide()
                downloadMessage = "已就绪 · main · \(result.commit.prefix(8))"
            } catch {
                if Task.isCancelled { downloadMessage = "下载已取消，可随时重试。" }
                else { downloadMessage = ""; saveError = "下载失败：\(error.localizedDescription)" }
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

    private func save() {
        updateGuide()
        Task {
            do {
                let wasSetup = store.needsGeneralSetup
                try await store.applyGeneralSettings(settings)
                if !wasSetup { dismiss() }
            } catch { saveError = error.localizedDescription }
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let step: GeneralSetupStep
    let progress: GeneralSetupProgress
    let animation: Namespace.ID
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    private var isCurrent: Bool { progress.current == step }
    private var isComplete: Bool { progress.completed.contains(step) }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 9) {
                Text(String(step.rawValue)).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCurrent ? Palette.onButton : Palette.muted)
                    .frame(width: 24, height: 24)
                    .background(isCurrent ? Palette.ink : Palette.selection, in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(Palette.muted)
                }.padding(.top, 2)
                Spacer(minLength: 4)
                Group {
                    if isComplete {
                        Image(systemName: "checkmark").accessibilityLabel("已填写")
                    } else if isCurrent {
                        Text(step == .workspace ? "从这里开始" : "下一步")
                    }
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted).padding(.top, 5)
            }
            content
        }
        .padding(14)
        .background(isCurrent ? Palette.surfaceSubtle.opacity(0.65) : Palette.canvas,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isCurrent ? Palette.borderStrong : Palette.line.opacity(0.7), lineWidth: 1))
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule().fill(Palette.ink).frame(width: 3, height: 22)
                    .matchedGeometryEffect(id: "current-setup-step", in: animation)
                    .padding(.leading, -1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}
