import AppKit
import SwiftUI
import LightX2VCore

struct ModelPreparationView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModelDownloadCard(resource: .turbo, path: $store.modelDirectory)
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Palette.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Prompt 增强").font(.system(size: 12, weight: .semibold))
                    Text(store.settings.promptEnhancement.enabled ? "按有无参考图自动切换模型" : "已关闭 · 无需增强模型路径")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 4)
                Toggle("Prompt 增强", isOn: Binding(get: { store.settings.promptEnhancement.enabled }, set: store.setPromptEnhancementEnabled))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Palette.button)
                    .disabled(store.configurationBusy).accessibilityLabel("Prompt 增强")
            }.frame(height: 36).padding(.horizontal, 2)
            ModelDownloadCard(resource: .t2i, path: $store.t2iDirectory)
            ModelDownloadCard(resource: .i2i, path: $store.i2iDirectory)
        }
        .onChange(of: store.modelDirectory) { _, _ in store.modelPathChanged(.turbo) }
        .onChange(of: store.t2iDirectory) { _, _ in store.modelPathChanged(.t2i) }
        .onChange(of: store.i2iDirectory) { _, _ in store.modelPathChanged(.i2i) }
        .allowsHitTesting(!store.isImportingImages)
    }
}

struct ModelPreparationFooter: View {
    @EnvironmentObject var store: AppStore
    @State private var showsEnvironment = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Group {
                    if store.isChecking { ProgressView().controlSize(.mini) }
                    else { Image(systemName: store.environmentReady ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(store.environmentReady ? Palette.green : Palette.accent) }
                }.frame(width: 14, height: 14)
                Text(store.isChecking ? "正在检查环境" : store.environmentReady ? "环境就绪" : "环境未就绪")
                Spacer(minLength: 4)
                Button("详情") { showsEnvironment = true }
                    .accessibilityLabel("查看环境检查详情")
                    .popover(isPresented: $showsEnvironment, arrowEdge: .leading) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("环境检查").font(.system(size: 13, weight: .semibold))
                            Text(store.environmentReady ? "环境依赖符合要求。" : "环境依赖不符合要求，请在通用设置中更改依赖环境。")
                                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        }.padding(18).frame(width: 320)
                    }
            }.font(.system(size: 10)).foregroundStyle(Palette.muted).buttonStyle(HoverButtonStyle(radius: 6)).frame(height: 22)
            HStack(spacing: 8) {
                Button("撤销") { store.discardModelSettings() }
                    .buttonStyle(SettingsActionStyle()).disabled(!store.hasUnsavedModelSettings || store.busy)
                Button("保存模型设置") { store.applyModelSettings() }
                    .frame(maxWidth: .infinity).buttonStyle(SettingsActionStyle(prominent: true))
                    .disabled(store.modelDirectory.isEmpty || store.busy)
            }.font(.system(size: 11)).frame(height: 32)
            Text("8 步生成 · 推理配置随每次任务保存")
                .font(.system(size: 10)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .center)
                .help("APP 使用内置 MPS 配置，无需手动选择。每个任务文件夹中的 config.json 可供查看。")
        }.padding(.vertical, 10)
    }
}

private struct ModelDownloadCard: View {
    @EnvironmentObject var store: AppStore
    let resource: ModelResource
    @Binding var path: String
    @State private var showsGuide = false
    @State private var copied = false
    private var optionalDisabled: Bool { resource != .turbo && !store.settings.promptEnhancement.enabled }
    private var downloading: Bool { store.activeModelDownload == resource }
    private var destination: String { resource.destination(in: WorkspaceLayout(store.settings.workingDirectory)).path }
    private var status: String {
        if optionalDisabled { return "已关闭 · 此项无需配置" }
        if let message = store.modelDownloadMessages[resource] { return message }
        if store.readyModelResources.contains(resource) { return "模型文件已就绪" }
        return path.isEmpty ? "选择已有文件夹，或自动下载" : store.modelResourceMessages[resource] ?? "正在确认模型文件…"
    }
    private var statusColor: Color {
        if store.modelDownloadErrors.contains(resource) { return Palette.accent }
        return !optionalDisabled && store.readyModelResources.contains(resource) && !downloading ? Palette.green : Palette.muted
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(resource == .turbo ? QwenImage21Turbo.title : resource == .t2i ? "文字增强 · PE-T2I" : "参考图增强 · PE-I2I").font(.system(size: 12, weight: .semibold)).help(resource.modelName)
                Spacer(minLength: 0)
                Text(resource == .turbo ? "必需" : "Q8_0").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Palette.muted).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Palette.surfaceSubtle, in: Capsule())
            }.frame(height: 20)
            HStack(spacing: 0) {
                PathInputField(title: resource.title + "目录", placeholder: "本地模型文件夹", symbol: nil, text: $path, minimumHeight: 36)
                Button(action: choose) {
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 30, height: 32)
                }.buttonStyle(HoverButtonStyle(radius: 6)).padding(.trailing, 4)
                    .help("选择" + resource.title + "目录").accessibilityLabel("选择" + resource.title + "目录")
            }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1).allowsHitTesting(false))
                .disabled(optionalDisabled || store.configurationBusy)
            HStack(spacing: 8) {
                Button {
                    if downloading { store.setupTask?.cancel() } else { store.downloadModel(resource) }
                } label: {
                    Label(downloading ? "停止" : "自动下载", systemImage: downloading ? "stop" : "arrow.down.to.line")
                }.disabled(optionalDisabled || (store.busy && !downloading))
                    .accessibilityLabel((downloading ? "停止下载" : "自动下载") + resource.title)
                Spacer(minLength: 0)
                Button { showsGuide = true; copied = false } label: { Label("下载指南", systemImage: "arrow.up.right.square") }
                    .accessibilityLabel(resource.title + "下载指南")
                    .popover(isPresented: $showsGuide, arrowEdge: .leading) { guide }
            }.font(.system(size: 10)).buttonStyle(HoverButtonStyle(radius: 6)).frame(height: 22)
            HStack(alignment: .top, spacing: 6) {
                Group {
                    if downloading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: optionalDisabled ? "minus.circle" : store.readyModelResources.contains(resource) ? "checkmark.circle" : "info.circle") }
                }.frame(width: 12, height: 12).padding(.top, 1)
                Text(status).font(.system(size: 9)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            }.foregroundStyle(statusColor).frame(height: 18, alignment: .top).help(status)
        }.padding(10).opacity(optionalDisabled ? 0.58 : 1)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(resource.title + "下载").font(.system(size: 15, weight: .semibold))
            Link(resource.repository, destination: resource.url).font(.system(size: 11)).textSelection(.enabled)
            Text("选择完整仓库文件夹。自动下载使用通用设置中的 Python 环境，将文件保存到工作目录的 models 下。")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Text(resource.command(destination: destination)).font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading).background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Link("打开 Hugging Face", destination: resource.url)
                Spacer()
                Button(copied ? "已复制" : "复制命令") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(resource.command(destination: destination), forType: .string); copied = true
                }.buttonStyle(SettingsActionStyle())
            }.font(.system(size: 11))
            Text("找不到 hf 时，在所选环境中运行：python -m pip install -U huggingface_hub。停止后重试会继续下载已有文件。")
                .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 430).foregroundStyle(Palette.ink)
    }

    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.title = "选择" + resource.title + "目录"
        panel.directoryURL = path.isEmpty ? URL(fileURLWithPath: store.settings.workingDirectory) : URL(fileURLWithPath: path).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}
