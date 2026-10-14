import AppKit
import SwiftUI
import LightX2VCore

struct ModelPreparationView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.text("Download source")).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                    Spacer(minLength: 4)
                    Button {
                        if store.isDownloadingAllModels { store.stopModelDownloads() } else { store.downloadAllModels() }
                    } label: {
                        Label(L10n.text(store.isDownloadingAllModels ? "Stop all downloads" : "Download all models"),
                              systemImage: store.isDownloadingAllModels ? "stop" : "arrow.down.to.line")
                            .font(.system(size: 10)).lineLimit(1)
                    }.buttonStyle(HoverButtonStyle(radius: 6))
                        .disabled(!store.isDownloadingAllModels && (store.busy || store.needsGeneralSetup))
                }.frame(height: 20)
                Picker(L10n.text("Download source"), selection: Binding(get: { store.settings.modelDownloadSource }, set: store.setModelDownloadSource)) {
                    ForEach(ModelDownloadSource.allCases) { source in Text(source.title).tag(source) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    .disabled(store.busy).accessibilityLabel(L10n.text("Download source"))
            }
            ModelDownloadCard(resource: .turbo, path: $store.modelDirectory)
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Palette.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Prompt enhancement")).font(.system(size: 12, weight: .semibold))
                    if !store.settings.promptEnhancement.enabled {
                        Text(L10n.text("Off · Enhancement model paths are optional"))
                            .font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 4)
                Toggle(L10n.text("Prompt enhancement"), isOn: Binding(get: { store.settings.promptEnhancement.enabled }, set: store.setPromptEnhancementEnabled))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Palette.button)
                    .disabled(store.configurationBusy).accessibilityLabel(L10n.text("Prompt enhancement"))
            }.frame(height: 36).padding(.horizontal, 2)
            ModelDownloadCard(resource: .t2i, path: $store.t2iDirectory)
            ModelDownloadCard(resource: .i2i, path: $store.i2iDirectory)
        }
        .allowsHitTesting(!store.isImportingImages)
    }
}

private struct ModelDownloadCard: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject var store: AppStore
    let resource: ModelResource
    @Binding var path: String
    @State private var showsGuide = false
    @State private var statusPinned = false
    @State private var statusHovered = false
    private var showsStatus: Bool { statusPinned || statusHovered }
    private var queued: Bool { store.queuedModelDownloads.contains(resource) }
    private var optionalDisabled: Bool { resource != .turbo && !store.settings.promptEnhancement.enabled && !downloading && !queued }
    private var downloading: Bool { store.activeModelDownload == resource }
    private var ready: Bool { store.readyModelResources.contains(resource) && !store.modelDownloadErrors.contains(resource) && !downloading }
    private var status: String {
        if queued { return L10n.text("Waiting for download") }
        if optionalDisabled { return L10n.text("Prompt enhancement is off; no model configuration needed") }
        if downloading {
            let progress = store.modelDownloadProgress[resource] ?? ModelDownloadProgress()
            return L10n.render(progress.percentage) + " · " + progress.fileCountText + " · " + progress.speedText(at: Date())
        }
        if store.modelDownloadErrors.contains(resource) { return L10n.text("Download failed · ") + concise(store.modelDownloadMessages[resource] ?? L10n.text("Please retry")) }
        if ready { return L10n.text("Model files ready") }
        if let message = store.modelDownloadMessages[resource] { return concise(message) }
        return path.isEmpty ? L10n.text("No model directory selected") : concise(store.modelResourceMessages[resource] ?? L10n.text("Checking model files…"))
    }
    private var statusColor: Color {
        optionalDisabled || downloading || queued ? Palette.muted : ready ? Palette.green : Palette.accent
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(resource == .turbo ? QwenImage21Turbo.title : resource.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).help(resource.modelName)
                Spacer(minLength: 0)
                Button { showsGuide = true } label: { Text(L10n.text("Download guide")) }
                    .font(.system(size: 10)).buttonStyle(HoverButtonStyle(radius: 6))
                    .accessibilityLabel(L10n.render(resource.title) + " " + L10n.text("Download guide"))
                    .popover(isPresented: $showsGuide, arrowEdge: .leading) { ModelDownloadGuide(resource: resource, source: store.settings.modelDownloadSource) }
            }.frame(height: 20)
            HStack(spacing: 0) {
                PathInputField(title: L10n.render(resource.title) + " " + L10n.text("Directory"), placeholder: L10n.text("Local model directory"), symbol: nil, text: $path, minimumHeight: 36)
                Button(action: choose) {
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 30, height: 32)
                }.buttonStyle(HoverButtonStyle(radius: 6)).padding(.trailing, 4)
                    .help(L10n.text("Choose") + " " + L10n.render(resource.title) + " " + L10n.text("Directory")).accessibilityLabel(L10n.text("Choose") + " " + L10n.render(resource.title) + " " + L10n.text("Directory"))
            }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1).allowsHitTesting(false))
                .disabled(optionalDisabled || store.configurationBusy)
            HStack(spacing: 6) {
                Button {
                    if downloading { store.stopModelDownloads() } else { store.downloadModel(resource) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: downloading ? "stop" : queued ? "clock" : "arrow.down.to.line")
                        Text(downloading ? L10n.text("Stop") : queued ? L10n.text("Waiting") : L10n.text("Download")).lineLimit(1).minimumScaleFactor(0.8)
                    }.frame(width: 68, alignment: .leading)
                }.disabled(optionalDisabled || (store.busy && !downloading))
                    .accessibilityLabel((downloading ? L10n.text("Stop download") : queued ? L10n.text("Waiting for download") : L10n.text("Download automatically")) + " " + L10n.render(resource.title))
                if downloading {
                    ModelDownloadFeedback(resource: resource, progress: store.modelDownloadProgress[resource] ?? ModelDownloadProgress())
                } else { Spacer(minLength: 0) }
                Button { statusPinned.toggle() } label: {
                    Group {
                        if downloading { ProgressView().controlSize(.mini).tint(statusColor) }
                        else { Image(systemName: queued ? "clock" : optionalDisabled ? "minus.circle" : ready ? "checkmark.circle.fill" : "xmark.circle.fill").font(.system(size: 13)) }
                    }.foregroundStyle(statusColor).frame(width: 20, height: 22).contentShape(Rectangle())
                }.buttonStyle(HoverButtonStyle(radius: 6)).disabled(downloading || queued)
                    .accessibilityLabel(L10n.render(resource.title) + " " + L10n.text("File status")).accessibilityValue(L10n.render(status))
                    .onHover { statusHovered = $0 }
                    .overlay(alignment: .bottomTrailing) {
                        if showsStatus && !downloading && !queued {
                            ModelStatusBubble(message: status).offset(y: -24).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
            }.font(.system(size: 10)).buttonStyle(HoverButtonStyle(radius: 6)).frame(height: 22)
        }.padding(10).opacity(optionalDisabled ? 0.58 : 1)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
            .zIndex(showsStatus && !downloading ? 1 : 0)
            .onChange(of: downloading) { _, active in
                if active { statusPinned = false; statusHovered = false }
            }
    }

    private func concise(_ message: String) -> String {
        let localized = L10n.render(message)
        let firstLine = localized.split(whereSeparator: \.isNewline).first.map(String.init) ?? localized
        return firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
    }

    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.title = L10n.text("Choose") + " " + L10n.render(resource.title) + " " + L10n.text("Directory")
        panel.directoryURL = path.isEmpty ? URL(fileURLWithPath: store.settings.workingDirectory) : URL(fileURLWithPath: path).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

struct ModelDownloadGuide: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let resource: ModelResource
    let source: ModelDownloadSource
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(resource.repository).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
            Text(L10n.text("Model download command. Save anywhere; automatic downloads go to the models directory in your workspace."))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal) {
                Text(resource.relativeCommand(source: source)).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).fixedSize().padding(12)
            }.environment(\.layoutDirection, .leftToRight).scrollIndicators(.visible).frame(height: 52)
                .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Link(destination: resource.url(source: source)) { Text(L10n.render(source.linkTitle)).underline().padding(.horizontal, 6).padding(.vertical, 5) }
                    .buttonStyle(HoverButtonStyle(radius: 6))
                Spacer()
                Button(copied ? L10n.text("Copied") : L10n.text("Copy command")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(resource.relativeCommand(source: source), forType: .string); copied = true
                }.buttonStyle(SettingsActionStyle())
            }.font(.system(size: 11))
        }.padding(20).frame(width: 430).foregroundStyle(Palette.ink)
            .onChange(of: source) { _, _ in copied = false }
    }

}

private struct ModelDownloadFeedback: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let resource: ModelResource
    let progress: ModelDownloadProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                Text(progress.stage == .downloading ? progress.percentage : "…").font(.system(size: 9)).monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
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
                Text(progress.fileCountText).font(.system(size: 9)).monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
                Text(progress.speedText(at: context.date)).font(.system(size: 9)).monospacedDigit()
                    .foregroundStyle(Palette.muted).frame(width: 62, alignment: .trailing)
            }.lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.render(resource.title) + " " + L10n.text("Download progress"))
                .accessibilityValue(L10n.render(progress.percentage) + " · " + progress.fileCountText + " · " + progress.speedText(at: context.date))
        }.frame(maxWidth: .infinity).environment(\.layoutDirection, .leftToRight)
    }
}

private struct ModelStatusBubble: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let message: String

    private var width: CGFloat {
        min(240, max(112, ceil((L10n.render(message) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 24)))
    }

    var body: some View {
        Text(L10n.render(message)).font(.system(size: 11)).foregroundStyle(Palette.ink)
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
