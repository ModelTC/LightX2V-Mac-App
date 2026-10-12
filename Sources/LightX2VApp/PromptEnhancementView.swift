import AppKit
import SwiftUI
import LightX2VCore

/// Each stream invalidates its text only, not the window or inspector.
@MainActor
final class EnhancementTextStream: ObservableObject {
    @Published var text: String
    init(text: String = "") { self.text = text }
}

struct PromptEnhancementMessageView: View {
    @ObservedObject private var language = LanguagePreferences.shared
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
                        Text(L10n.text("Prompt enhancement")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                    Text(L10n.render(reply.mode.title)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(L10n.text("Show reasoning"), isOn: $showsThinking)
                .font(.system(size: 10)).toggleStyle(.switch).controlSize(.mini).tint(Palette.button)
                .fixedSize().frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(L10n.text("Show reasoning"))
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
    @ObservedObject private var language = LanguagePreferences.shared
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
                    Text(L10n.text("Enhanced")).foregroundStyle(Palette.muted)
                    if let duration = reply.duration { Text(L10n.text("· %@ s", [String(describing: Int(duration.rounded()))])).foregroundStyle(Palette.muted) }
                    if job.request.resolution != nil, let ratio = reply.whRatio, !ratio.isEmpty {
                        Text("· \(ratio)").foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").frame(width: 26, height: 26) }
                        .buttonStyle(HoverButtonStyle(radius: 6)).help(L10n.text("Copy enhanced prompt")).accessibilityLabel(L10n.text("Copy enhanced prompt"))
                }.font(.system(size: 10))
            } else if reply.status.isActive {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(reply.status == .thinking ? L10n.text("Thinking and refining the description…") : L10n.text("Writing the enhanced prompt…"))
                        .font(.system(size: text.isEmpty ? 12 : 10)).foregroundStyle(Palette.muted)
                    Button(L10n.text("View live log")) { store.openLog(for: job) }
                        .font(.system(size: 10)).foregroundStyle(Palette.muted).buttonStyle(HoverButtonStyle())
                }.padding(.vertical, text.isEmpty ? 6 : 0)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label(job.status == .cancelled ? L10n.text("Enhancement stopped") : L10n.text("Enhancement incomplete"), systemImage: "info.circle")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                    Text(L10n.render(job.error ?? "Enhancement was interrupted. Please retry.")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button(L10n.text("Retry with these inputs")) { store.reuse(job) }.disabled(store.busy)
                        Button(L10n.text("View log")) { store.openLog(for: job) }
                        Button(L10n.text("View task files")) { store.reveal(job) }
                    }.font(.system(size: 11)).buttonStyle(HoverButtonStyle())
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EnhancementThinkingView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @ObservedObject var stream: EnhancementTextStream
    let id: UUID
    let active: Bool

    var body: some View {
        ScrollView {
            Text(stream.text.isEmpty ? (active ? L10n.text("Loading enhancement model…") : L10n.text("No reasoning output")) : stream.text)
                .font(.system(size: 11)).lineSpacing(4).foregroundStyle(Palette.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12).subtleScrollbars()
                .background(ConversationScrollAnchor(turns: [id]))
        }.frame(height: 190).background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(L10n.text("Enhancement model reasoning"))
    }
}
