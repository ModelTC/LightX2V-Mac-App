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
        .allowsHitTesting(!store.isImportingImages)
    }
}

private struct ModelDownloadCard: View {
    @EnvironmentObject var store: AppStore
    let resource: ModelResource
    @Binding var path: String
    @State private var showsGuide = false
    @State private var copied = false
    @State private var statusPinned = false
    @State private var statusHovered = false
    private var showsStatus: Bool { statusPinned || statusHovered }
    private var optionalDisabled: Bool { resource != .turbo && !store.settings.promptEnhancement.enabled }
    private var downloading: Bool { store.activeModelDownload == resource }
    private var ready: Bool { store.readyModelResources.contains(resource) && !store.modelDownloadErrors.contains(resource) && !downloading }
    private var status: String {
        if optionalDisabled { return "Prompt 增强已关闭，无需配置" }
        if downloading { return (store.modelDownloadProgress[resource] ?? ModelDownloadProgress()).detail(at: Date()) }
        if store.modelDownloadErrors.contains(resource) { return "下载失败 · " + concise(store.modelDownloadMessages[resource] ?? "请重试") }
        if ready { return "模型文件已就绪" }
        if let message = store.modelDownloadMessages[resource] { return concise(message) }
        return path.isEmpty ? "尚未选择模型文件夹" : concise(store.modelResourceMessages[resource] ?? "正在确认模型文件…")
    }
    private var statusColor: Color {
        optionalDisabled || downloading ? Palette.muted : ready ? Palette.green : Palette.accent
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(resource == .turbo ? QwenImage21Turbo.title : resource.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).help(resource.modelName)
                Spacer(minLength: 0)
                Button { showsGuide = true; copied = false } label: { Text("下载指南") }
                    .font(.system(size: 10)).buttonStyle(HoverButtonStyle(radius: 6))
                    .accessibilityLabel(resource.title + "下载指南")
                    .popover(isPresented: $showsGuide, arrowEdge: .leading) { guide }
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
            HStack(spacing: 6) {
                Button {
                    if downloading { store.setupTask?.cancel() } else { store.downloadModel(resource) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: downloading ? "stop" : "arrow.down.to.line")
                        Text(downloading ? "停止" : "自动下载").lineLimit(1)
                    }.fixedSize().frame(width: 56, alignment: .leading)
                }.disabled(optionalDisabled || (store.busy && !downloading))
                    .accessibilityLabel((downloading ? "停止下载" : "自动下载") + resource.title)
                if downloading {
                    ModelDownloadFeedback(resource: resource, progress: store.modelDownloadProgress[resource] ?? ModelDownloadProgress())
                        .onHover { statusHovered = $0 }
                } else { Spacer(minLength: 0) }
                Button { statusPinned.toggle() } label: {
                    Group {
                        if downloading { ProgressView().controlSize(.mini).tint(statusColor) }
                        else { Image(systemName: optionalDisabled ? "minus.circle" : ready ? "checkmark.circle.fill" : "xmark.circle.fill").font(.system(size: 13)) }
                    }.foregroundStyle(statusColor).frame(width: 20, height: 22).contentShape(Rectangle())
                }.buttonStyle(HoverButtonStyle(radius: 6))
                    .accessibilityLabel(resource.title + "文件状态").accessibilityValue(status)
                    .onHover { statusHovered = $0 }
                    .overlay(alignment: .bottomTrailing) {
                        if showsStatus {
                            Group {
                                if downloading {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        ModelStatusBubble(message: (store.modelDownloadProgress[resource] ?? ModelDownloadProgress()).detail(at: context.date))
                                    }
                                } else { ModelStatusBubble(message: status) }
                            }.offset(y: -24).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
            }.font(.system(size: 10)).buttonStyle(HoverButtonStyle(radius: 6)).frame(height: 22)
        }.padding(10).opacity(optionalDisabled ? 0.58 : 1)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
            .zIndex(showsStatus ? 1 : 0)
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(resource.repository).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
            Text("模型下载命令。可保存到任意位置，若点击自动下载，则会统一保存到工作目录下的models文件夹中。")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Text(resource.relativeCommand).font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading).background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Link(destination: resource.url) { Text("打开 Hugging Face").underline().padding(.horizontal, 6).padding(.vertical, 5) }
                    .buttonStyle(HoverButtonStyle(radius: 6))
                Spacer()
                Button(copied ? "已复制" : "复制命令") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(resource.relativeCommand, forType: .string); copied = true
                }.buttonStyle(SettingsActionStyle())
            }.font(.system(size: 11))
        }.padding(20).frame(width: 430).foregroundStyle(Palette.ink)
    }

    private func concise(_ message: String) -> String {
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
    }

    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.title = "选择" + resource.title + "目录"
        panel.directoryURL = path.isEmpty ? URL(fileURLWithPath: store.settings.workingDirectory) : URL(fileURLWithPath: path).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

private struct ModelDownloadFeedback: View {
    let resource: ModelResource
    let progress: ModelDownloadProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Group {
                    if let fraction = progress.fraction, progress.stage == .downloading {
                        GeometryReader { geometry in
                            Capsule().fill(Palette.line)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Palette.button).frame(width: geometry.size.width * fraction)
                                }
                        }.frame(height: 4)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(Palette.button).frame(height: 4)
                    }
                }.frame(maxWidth: .infinity)
                Text(progress.percentage).font(.system(size: 10)).monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
                Text(progress.speedText(at: context.date)).font(.system(size: 9)).monospacedDigit()
                    .foregroundStyle(Palette.muted).frame(width: 62, alignment: .trailing)
            }.lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(resource.title + "下载进度")
                .accessibilityValue(progress.percentage + " · " + progress.detail(at: context.date))
        }.frame(maxWidth: .infinity)
    }
}

private struct ModelStatusBubble: View {
    let message: String

    private var width: CGFloat {
        min(240, max(112, ceil((message as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 24)))
    }

    var body: some View {
        Text(message).font(.system(size: 11)).foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 16)
            .frame(width: width, alignment: .leading)
            .background(ModelStatusBubbleShape().fill(Palette.surface))
            .overlay(ModelStatusBubbleShape().stroke(Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }
}

private struct ModelStatusBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 8
        let bottom = rect.maxY - 6
        let tip = rect.maxX - 12
        var path = Path()
        path.move(to: CGPoint(x: r, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: r), control: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: bottom), control: CGPoint(x: rect.maxX, y: bottom))
        path.addLine(to: CGPoint(x: tip + 4, y: bottom))
        path.addLine(to: CGPoint(x: tip, y: rect.maxY))
        path.addLine(to: CGPoint(x: tip - 4, y: bottom))
        path.addLine(to: CGPoint(x: r, y: bottom))
        path.addQuadCurve(to: CGPoint(x: 0, y: bottom - r), control: CGPoint(x: 0, y: bottom))
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addQuadCurve(to: CGPoint(x: r, y: 0), control: .zero)
        path.closeSubpath()
        return path
    }
}
