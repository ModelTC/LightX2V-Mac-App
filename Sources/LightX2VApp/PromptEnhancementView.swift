import AppKit
import SwiftUI
import LightX2VCore

/// Each stream invalidates its text only, not the window or inspector.
@MainActor
final class EnhancementTextStream: ObservableObject {
    @Published var text: String
    init(text: String = "") { self.text = text }
}

struct PromptEnhancementControl: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 10) {
            Label("Prompt 增强", systemImage: "sparkles")
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 8)
            Button { store.showEnhancementSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .frame(width: 26, height: 26)
            }.buttonStyle(HoverButtonStyle(radius: 6)).help("配置 Prompt 增强")
                .accessibilityLabel("配置 Prompt 增强").disabled(store.configurationBusy)
            Toggle("Prompt 增强", isOn: Binding(get: { store.settings.promptEnhancement.enabled }, set: store.setPromptEnhancementEnabled))
            .labelsHidden().fixedSize().toggleStyle(.switch).controlSize(.mini).tint(Palette.button)
            .accessibilityLabel("Prompt 增强")
            .disabled(store.configurationBusy).allowsHitTesting(!store.isImportingImages)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line, lineWidth: 1))
    }
}

struct PromptEnhancementSettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var settings: PromptEnhancementSettings
    @State private var mode: PromptEnhancementMode

    init(settings: PromptEnhancementSettings, mode: PromptEnhancementMode) {
        _settings = State(initialValue: settings); _mode = State(initialValue: mode)
    }

    private var validationMessage: String? {
        do { try settings.validate(for: mode); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 20, weight: .light))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Prompt 增强").font(.system(size: 17, weight: .semibold))
                    Text("本地运行，按是否添加参考图自动切换。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("自动查找") { settings.discover(near: [store.settings.model, store.settings.repository, store.settings.workingDirectory]) }
                    .buttonStyle(SettingsActionStyle())
            }
            PathSettingField(title: "llama.cpp 运行目录（bin）", value: $settings.runtimeDirectory, directory: true)
            Picker("增强模型", selection: $mode) {
                Text("文字 → 画面").tag(PromptEnhancementMode.t2i)
                Text("参考图 → 画面").tag(PromptEnhancementMode.i2i)
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("增强模型类型")
            VStack(alignment: .leading, spacing: 16) {
                if mode == .t2i {
                    PathSettingField(title: "PE-T2I 模型（GGUF）", value: $settings.t2iModel, directory: false)
                    PathSettingField(title: "系统提示词（system_prompt.txt）", value: $settings.t2iSystemPrompt, directory: false)
                } else {
                    PathSettingField(title: "PE-I2I 模型（GGUF）", value: $settings.i2iModel, directory: false)
                    PathSettingField(title: "视觉编码器（mmproj）", value: $settings.visionProjector, directory: false)
                    PathSettingField(title: "系统提示词（system_prompt.txt）", value: $settings.i2iSystemPrompt, directory: false)
                }
                Label(validationMessage ?? "\(mode.title)资源已就绪", systemImage: validationMessage == nil ? "checkmark.circle" : "info.circle")
                    .font(.system(size: 11)).foregroundStyle(validationMessage == nil ? Palette.green : Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 32, alignment: .topLeading)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { store.applyEnhancementSettings(normalizedSettings) }.buttonStyle(SettingsActionStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }.buttonStyle(SettingsActionStyle())
        }.padding(26).frame(width: 510).foregroundStyle(Palette.ink).background(Palette.surface)
            .tint(Palette.button).dismissEditingOnOutsideClick()
    }

    private var normalizedSettings: PromptEnhancementSettings {
        var value = settings
        func path(_ text: String) -> String { (text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath }
        value.runtimeDirectory = path(value.runtimeDirectory)
        value.t2iModel = path(value.t2iModel); value.t2iSystemPrompt = path(value.t2iSystemPrompt)
        value.i2iModel = path(value.i2iModel); value.i2iSystemPrompt = path(value.i2iSystemPrompt)
        value.visionProjector = path(value.visionProjector)
        return value
    }
}

struct PromptEnhancementMessageView: View {
    let job: Generation
    let reply: PromptEnhancementReply
    let thinkingStream: EnhancementTextStream
    let promptStream: EnhancementTextStream
    @State private var showsThinking: Bool

    init(job: Generation, reply: PromptEnhancementReply, thinkingStream: EnhancementTextStream, promptStream: EnhancementTextStream) {
        self.job = job; self.reply = reply
        self.thinkingStream = thinkingStream; self.promptStream = promptStream
        _showsThinking = State(initialValue: reply.status == .thinking)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                BrandMark(size: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("LightX2V").font(.system(size: 12, weight: .semibold))
                        Text("Prompt 增强").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                    Text(reply.mode.title).font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle("显示思考内容", isOn: $showsThinking)
                .font(.system(size: 10)).toggleStyle(.switch).controlSize(.mini).tint(Palette.button)
                .fixedSize().frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("显示思考内容")
            if showsThinking {
                EnhancementThinkingView(stream: thinkingStream, id: job.id, active: reply.status == .thinking)
            }
            EnhancedPromptBody(job: job, reply: reply, stream: promptStream)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: reply.status) { previous, current in
                // Collapse once when thinking ends. A manual reopening during
                // rewriting remains open when the prompt or image completes.
                if previous == .thinking && current != .thinking { showsThinking = false }
            }
    }
}

private struct EnhancedPromptBody: View {
    @EnvironmentObject var store: AppStore
    let job: Generation
    let reply: PromptEnhancementReply
    @ObservedObject var stream: EnhancementTextStream

    private var text: String { reply.status == .completed ? (reply.prompt ?? stream.text) : stream.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !text.isEmpty {
                Text(text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("enhanced-prompt")
            }
            if reply.status == .completed {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark").foregroundStyle(Palette.green)
                    Text("已增强").foregroundStyle(Palette.muted)
                    if let duration = reply.duration { Text("· \(Int(duration.rounded())) 秒").foregroundStyle(Palette.muted) }
                    if job.request.resolution != nil, let ratio = reply.whRatio, !ratio.isEmpty {
                        Text("· \(ratio)").foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").frame(width: 26, height: 26) }
                        .buttonStyle(HoverButtonStyle(radius: 6)).help("复制增强提示词").accessibilityLabel("复制增强提示词")
                }.font(.system(size: 10))
            } else if reply.status.isActive {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(reply.status == .thinking ? "正在思考与完善描述…" : "正在输出增强提示词…")
                        .font(.system(size: text.isEmpty ? 12 : 10)).foregroundStyle(Palette.muted)
                }.padding(.vertical, text.isEmpty ? 6 : 0)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label(job.status == .cancelled ? "增强已停止" : "增强未完成", systemImage: "info.circle")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                    Text(job.error ?? "本次增强已中断，请重试。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("复用输入重试") { store.reuse(job) }.disabled(store.busy)
                        Button("查看任务文件") { store.reveal(job) }
                    }.font(.system(size: 11)).buttonStyle(HoverButtonStyle())
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EnhancementThinkingView: View {
    @ObservedObject var stream: EnhancementTextStream
    let id: UUID
    let active: Bool

    var body: some View {
        ScrollView {
            Text(stream.text.isEmpty ? (active ? "正在加载增强模型…" : "暂无思考输出") : stream.text)
                .font(.system(size: 11)).lineSpacing(4).foregroundStyle(Palette.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12).subtleScrollbars()
                .background(ConversationScrollAnchor(turns: [id]))
        }.frame(height: 190).background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("增强模型的思考过程")
    }
}
