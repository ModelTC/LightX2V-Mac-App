import SwiftUI
import AppKit
import LightX2VCore

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var settings: AppSettings
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
                    Text("一个工作目录，收纳你的创作与运行数据。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
            }.padding(26)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsSection(number: "1", title: "LightX2V 工作目录", subtitle: "配置、历史、图片、日志和缓存都保存在这里。") {
                        pathRow("LightX2V 工作目录", value: $settings.workingDirectory, directory: true, create: true)
                        if !store.generations.isEmpty && normalized(settings.workingDirectory) != store.settings.workingDirectory {
                            Text("更换后从空历史开始，原有记录与作品留在旧目录。")
                                .font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                    }
                    SettingsSection(number: "2", title: "LightX2V 源码目录", subtitle: "选择已有源码，或自动下载 GitHub main 的最新版本。") {
                        pathRow("LightX2V 源码目录", value: $settings.repository, directory: true)
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
                    }
                    SettingsSection(number: "3", title: "PyTorch 环境", subtitle: "搜索已安装的 Python 环境，选择支持 Apple Silicon MPS 的一项。") {
                        pathRow("PyTorch 环境", value: $settings.python, directory: false)
                        HStack(spacing: 10) {
                            Button { startSearch() } label: { Label("搜索", systemImage: "magnifyingglass") }
                                .disabled(store.busy || !hasWorkDirectory)
                            Text("检测 PyTorch 与 MPS · 不会安装或修改环境")
                                .font(.system(size: 10)).foregroundStyle(Palette.muted)
                            Spacer(minLength: 0)
                        }.font(.system(size: 11))
                    }
                    if !hasWorkDirectory {
                        Text("先选择工作目录，即可下载源码和搜索环境。")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Text("模型权重与 Config 配置可在主界面右侧的「模型准备」中设置。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.padding(.horizontal, 26).padding(.bottom, 22).subtleScrollbars()
            }.frame(maxHeight: 490)
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
                    .buttonStyle(.borderedProminent).tint(Palette.button)
                    .keyboardShortcut(.defaultAction).disabled(store.busy || !settings.hasGeneralPaths)
            }.padding(.horizontal, 26).padding(.vertical, 18)
        }.frame(width: 660).background(Palette.canvas).foregroundStyle(Palette.ink)
            .onChange(of: settings) { _, _ in saveError = nil }
            .onDisappear { store.setupTask?.cancel() }
            .sheet(isPresented: $showEnvironments, onDismiss: { if searching { store.setupTask?.cancel() } }) {
                environmentPicker
            }
    }

    private func pathRow(_ title: String, value: Binding<String>, directory: Bool, create: Bool = false) -> some View {
        HStack(spacing: 9) {
            Image(systemName: directory ? "folder" : "terminal").foregroundStyle(Palette.muted).font(.system(size: 12))
            TextField(directory ? "选择文件夹，或粘贴完整路径" : "选择环境中的 bin/python，或点击下方搜索", text: value)
                .textFieldStyle(.plain).font(.system(size: 11)).accessibilityLabel(title).help(value.wrappedValue)
                .dismissEditingOnOutsideClick()
            Button(directory ? "选择…" : "手动选择…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
                panel.canCreateDirectories = create; panel.allowsMultipleSelection = false
                panel.title = directory ? "选择\(title)" : "选择 PyTorch 环境中的 Python 可执行文件"
                panel.directoryURL = value.wrappedValue.isEmpty ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: normalized(value.wrappedValue)).deletingLastPathComponent()
                if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path }
            }.font(.system(size: 11)).accessibilityLabel("选择\(title)")
        }.padding(10).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1)).disabled(store.busy)
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
                        }.buttonStyle(EnvironmentRowButtonStyle()).disabled(!environment.mpsAvailable).help(environment.detail)
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
    }

    private func normalized(_ value: String) -> String {
        (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
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
    let number: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 9) {
                Text(number).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                    .frame(width: 21, height: 21).background(Palette.selection, in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(Palette.muted)
                }.padding(.top, 2)
            }
            content
        }
    }
}

private struct EnvironmentRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}
