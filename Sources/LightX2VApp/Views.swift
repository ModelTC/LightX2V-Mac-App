import SwiftUI
import AppKit
import LightX2VCore
import UniformTypeIdentifiers

struct BrandMark: View {
    @ObservedObject private var language = LanguagePreferences.shared
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29).fill(Palette.button)
            Image(systemName: "bolt.fill").font(.system(size: size * 0.56, weight: .medium)).foregroundStyle(Palette.onButton)
        }.frame(width: size, height: size)
    }
}

struct IconButton: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14)).frame(width: 30, height: 30)
                .background(active ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 7)) }
            .buttonStyle(HoverButtonStyle(radius: 7)).foregroundStyle(Palette.muted).help(label).accessibilityLabel(label)
    }
}

struct WorkspaceView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject var store: AppStore
    @State private var minimumWindowSize = ScreenFittingWindow.minimumContentSize
    var body: some View {
        GeometryReader { workspace in
            HStack(spacing: 0) {
                SidebarView().frame(width: 232)
                Rectangle().fill(Palette.line).frame(width: 1)
                VStack(spacing: 0) {
                    toolbar
                    Rectangle().fill(Palette.line).frame(height: 1)
                    ZStack {
                        if let job = store.selected {
                            // Reserve the compact composer and reply metadata once;
                            // attachments and prompt wrapping must not rescale replies.
                            GenerationView(previewHeight: min(500, max(280, workspace.size.height - 449)))
                                .id(job.creationID)
                        } else { WelcomeView() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if store.showLogs { LogPanel().frame(height: 205) }
                    ComposerView().padding(.horizontal, 30).padding(.top, 12).padding(.bottom, 20)
                    // The two sidebars and separators occupy 554 points in total.
                }.frame(minWidth: max(1, minimumWindowSize.width - 554)).background(Palette.canvas)
                if store.showInspector {
                    Rectangle().fill(Palette.line).frame(width: 1)
                    InspectorView().frame(width: 320)
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .tint(Palette.button)
        .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
        .overlay(alignment: .top) { WindowDragArea(isNativeTitleBar: true).frame(height: 28) }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $store.showSettings) { SettingsView(settings: store.settings).environmentObject(store) }

        .alert("LightX2V APP", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(L10n.text("OK")) { store.errorMessage = nil }
        } message: { Text(L10n.render(store.errorMessage ?? "")) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(Palette.muted)
                Text(L10n.text("Workspace")).foregroundStyle(Palette.muted)
                Text("/").foregroundStyle(Palette.muted.opacity(0.5))
                Text(store.selected == nil ? L10n.text("New creation") : L10n.text("Image generation")).fontWeight(.medium)
                Spacer()
            }.frame(maxHeight: .infinity).background(WindowDragArea())
            IconButton(symbol: "sidebar.right", label: L10n.text("Show model preparation and generation settings"), active: store.showInspector) { store.showInspector.toggle() }
        }.font(.system(size: 12)).padding(.horizontal, 24).frame(height: 58).padding(.top, 28)
    }
}

struct SidebarView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                BrandMark(size: 28)
                Text("LightX2V").font(.system(size: 17, weight: .semibold))
                Text("APP").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
            }.padding(.horizontal, 22).padding(.top, 52).padding(.bottom, 27)
            Button { store.newGeneration() } label: {
                HStack { Image(systemName: "square.and.pencil"); Text(L10n.text("New creation")); Spacer(); Text("⌘ N").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                    .font(.system(size: 13, weight: .medium)).padding(12)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
            }.buttonStyle(HoverButtonStyle(radius: 9, border: true, dimsWhenDisabled: false)).disabled(store.isImportingImages).padding(.horizontal, 14)
            Text(L10n.text("Recent creations"))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 5) {
                    if store.generations.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("Inspiration starts here")).font(.system(size: 12))
                            Text(L10n.text("Your generated images will appear here")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 18)
                    }
                    ForEach(store.recentCreations) { job in
                        Button { store.selectedID = job.id } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: job.status == .completed ? "photo" : job.status == .running ? "circle.dotted" : "clock")
                                    .font(.system(size: 12)).foregroundStyle(job.status == .running ? Palette.ink : Palette.muted).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(store.creationTitle(job)).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                                    HStack(spacing: 5) {
                                        Text(job.createdAt, style: .date)
                                        Text("· \(L10n.render(job.status.label))")
                                    }.font(.system(size: 9)).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 0)
                            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                .background(store.selected?.creationID == job.creationID ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(HoverButtonStyle()).padding(.horizontal, 10)
                            .contextMenu {
                                if job.status == .completed {
                                    Button(L10n.text("Copy")) { store.copyImage(job) }
                                }
                                Button(L10n.text("Show in Finder")) { store.reveal(job) }
                                if job.status == .completed {
                                    Button(L10n.text("Reference")) { store.reference(job) }.disabled(!store.canReferenceImages)
                                }
                                if job.status != .running { Button(L10n.text("Remove from history (keep files)")) { store.removeFromHistory(job) } }
                            }
                    }
                }.subtleScrollbars()
            }
            Spacer(minLength: 12)
            if store.isRunning, store.selectedID != store.activeID {
                Button { store.selectedID = store.activeID } label: {
                    HStack { ProgressView().controlSize(.mini); Text(L10n.text("Return to the image being generated")).font(.system(size: 11)); Spacer() }
                        .padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(HoverButtonStyle()).padding(12)
            }
            Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, 18)
            HStack(spacing: 10) {
                ZStack { RoundedRectangle(cornerRadius: 8).fill(Palette.selection); Image(systemName: "desktopcomputer").font(.system(size: 15)) }.frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Local inference")).font(.system(size: 12, weight: .medium))
                    HStack(spacing: 4) {
                        Circle().fill(store.environmentReady ? Palette.readyIndicator : Palette.muted).frame(width: 5, height: 5)
                        Text(MacHardware.sidebarDescription)
                            .font(.system(size: 9)).foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 0)
                IconButton(symbol: "gearshape", label: L10n.text("Open settings")) { store.showSettings = true }
            }.padding(.horizontal, 16).padding(.vertical, 20)
        }.background(Palette.sidebar)
    }
}

struct WelcomeView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject var store: AppStore
    private var examples: [(String, String, String)] { [
        ("sparkles", L10n.text("A little wonder"), "A capybara wearing a wizard hat, oil painting"),
        ("camera.aperture", L10n.text("A frame of light"), "A quiet Japanese cafe on a rainy afternoon, soft window light, cinematic photography, warm tones"),
        ("leaf", L10n.text("A touch of nature"), "A tiny glass house in a misty green forest, soft morning sunlight, architectural photography, peaceful atmosphere")
    ] }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 19).fill(Palette.selection).frame(width: 105, height: 118).rotationEffect(.degrees(-13)).offset(x: -29, y: 9)
                        RoundedRectangle(cornerRadius: 19).fill(Palette.surfaceSubtle).frame(width: 105, height: 118).rotationEffect(.degrees(12)).offset(x: 29, y: 6)
                        ZStack {
                            RoundedRectangle(cornerRadius: 19).fill(Palette.canvas)
                            RoundedRectangle(cornerRadius: 19).stroke(Palette.line, lineWidth: 1)
                            Image(systemName: "sparkles").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(Palette.ink)
                        }.frame(width: 100, height: 118).shadow(color: .black.opacity(0.04), radius: 14, y: 7)
                    }.frame(height: 145).padding(.bottom, 28)
                    Text(L10n.text("Bring your imagination into view.")).font(.system(size: 30, weight: .semibold))
                    Text(L10n.text("Describe your inspiration and let your Mac create it.")).font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.top, 12)
                    HStack(spacing: 7) {
                        Image(systemName: "lock.shield").font(.system(size: 10))
                        Text(L10n.text("Runs locally"))
                        if let model = store.selectedModel {
                            Text("·"); Text(model.title); Text("·"); Text(L10n.text("%@-step generation", [String(describing: QwenImage21Turbo.inferenceSteps)]))
                        }
                    }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.top, 16)
                    if store.selectedModel == .qwenImage21Turbo {
                        HStack(spacing: 10) {
                            ForEach(examples, id: \.0) { item in
                                Button { store.usePrompt(item.2) } label: {
                                    VStack(alignment: .leading, spacing: 15) {
                                        Image(systemName: item.0).font(.system(size: 16, weight: .light)).foregroundStyle(Palette.ink)
                                        HStack { Text(item.1).font(.system(size: 12)); Spacer(minLength: 2); Image(systemName: "arrow.up.left").font(.system(size: 9)).foregroundStyle(Palette.muted) }
                                    }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
                                }.buttonStyle(HoverButtonStyle(radius: 12, border: true)).help(item.2)
                            }
                        }.frame(maxWidth: 470).padding(.top, 40)
                    }
                }.frame(maxWidth: .infinity).frame(minHeight: geometry.size.height).padding(.horizontal, 32).subtleScrollbars()
            }
        }
    }
}

struct ComposerView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject var store: AppStore
    @State private var focused = false
    @State private var editorHeight = PromptScrollView.minimumHeight
    @State private var dropTargeted = false
    @State private var editorDropTargeted = false
    private var highlightingDrop: Bool { store.canAddImages && (dropTargeted || editorDropTargeted) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.inputImages.isEmpty {
                InputImageStrip(images: store.inputImages, remove: store.removeInputImage)
                    .disabled(store.isImportingImages)
                if store.inputImages.count > 3 {
                    Text(L10n.text("Too many references may distort the image. This model works best with 1–3 images."))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            promptEditor
            composerActions
        }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(highlightingDrop ? Palette.ink : focused ? Palette.focus : Palette.line, lineWidth: highlightingDrop ? 2 : 1))
            .shadow(color: .black.opacity(0.025), radius: 12, y: 4)
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: store.receiveImageDrop)
            .frame(maxWidth: 850)
    }

    private var promptEditor: some View {
        PromptEditor(text: $store.prompt, height: $editorHeight, focused: $focused,
                     composing: $store.isComposingPrompt,
                     placeholder: L10n.text("Describe the image you want to create…"),
                     onDropFiles: store.canAddImages ? { store.addInputImages($0) } : nil,
                     onDropHover: { editorDropTargeted = $0 },
                     onPasteImages: store.receiveImagePaste,
                     onSubmit: { if store.canGenerate { store.generate() } })
            .frame(height: editorHeight)
    }

    private var composerActions: some View {
        HStack(spacing: 7) {
            attachmentButton
            ModelSelector()
            if store.selectedModel == nil {
                Label(L10n.text("Choose a model first"), systemImage: "arrow.left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .lineLimit(1)
                    .accessibilityIdentifier("model-selection-reminder")
            }
            Spacer()
            if store.isRunning {
                Button { store.stop() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                        Text(store.isStopping ? L10n.text("Stopping") : L10n.text("Stop generation")).font(.system(size: 11, weight: .medium))
                    }.foregroundStyle(Palette.onButton).padding(.horizontal, 12).frame(height: 32)
                        .background(Palette.button, in: Capsule())
                }.buttonStyle(HoverButtonStyle(radius: 16, bright: true)).disabled(store.isStopping)
            } else {
                Button { store.generate() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(store.canGenerate ? Palette.onButton : Palette.disabledInk).frame(width: 32, height: 32)
                        .background(store.canGenerate ? Palette.button : Palette.disabledFill, in: Circle())
                }.buttonStyle(HoverButtonStyle(radius: 16, bright: true, dimsWhenDisabled: false))
                    .disabled(!store.canGenerate).keyboardShortcut(.return, modifiers: .command)
                    .help(L10n.text("Generate image")).accessibilityLabel(L10n.text("Generate image"))
            }
        }.onHover { inside in if inside { NSCursor.arrow.set() } }
    }

    private var attachmentButton: some View {
        Button { store.chooseInputImages() } label: {
            Group {
                if store.isImportingImages { ProgressView().controlSize(.small) }
                else { Image(systemName: "plus").font(.system(size: 16, weight: .regular)) }
            }.frame(width: 30, height: 30)
        }.buttonStyle(HoverButtonStyle(radius: 7)).disabled(!store.canAddImages)
            .help(L10n.text("Add images (1–3 recommended, up to 8)")).accessibilityLabel(L10n.text("Add images"))
    }

}

struct ModelSelector: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject var store: AppStore

    var body: some View {
        Menu {
            ForEach(GenerationModel.allCases) { model in
                Button {
                    store.selectModel(model)
                } label: {
                    if store.selectedModel == model {
                        Label(model.title, systemImage: "checkmark")
                    } else {
                        Text(model.title)
                    }
                }
            }
        } label: {
            Label(store.selectedModel?.title ?? L10n.text("Choose model"), systemImage: "cube.transparent")
        }
        .font(.system(size: 11, weight: .medium))
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        // Constrain the native menu itself, so changing its title does not
        // move either the popup anchor or the indicator while it closes.
        .frame(width: 180)
        .padding(.horizontal, 8).frame(height: 30)
        .foregroundStyle(store.selectedModel == nil ? Palette.accent : Palette.ink)
        .background(store.selectedModel == nil ? Palette.accentSurface : Palette.surfaceSubtle,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            if store.selectedModel == nil { ModelSelectionRing() }
        }
        .hoverSurface(radius: 7, border: false)
        .disabled(store.configurationBusy)
        .allowsHitTesting(!store.isImportingImages)
        .help(L10n.text("Choose generation model"))
        .accessibilityLabel(L10n.text("Choose model"))
        .accessibilityValue(store.selectedModel?.title ?? L10n.text("Not selected"))
    }
}

/// A quiet breathing outline draws attention without changing layout or hit areas.
private struct ModelSelectionRing: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Palette.accent.opacity(reduceMotion ? 0.8 : bright ? 0.9 : 0.35), lineWidth: 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: bright)
            .onAppear { bright = true }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct PromptMessageView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let prompt: String
    let createdAt: Date
    let inputImages: [InputImage]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 7) {
                if !inputImages.isEmpty {
                    InputImageStrip(images: inputImages).frame(maxWidth: CGFloat(inputImages.count * 82 - 10))
                }
                Text(prompt)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.onPrompt)
                    .lineSpacing(5)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(Palette.prompt, in: UnevenRoundedRectangle(
                        topLeadingRadius: 18, bottomLeadingRadius: 18,
                        bottomTrailingRadius: 5, topTrailingRadius: 18, style: .continuous
                    ))
                Text(createdAt, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .padding(.trailing, 4)
            }
            .frame(maxWidth: 560, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct GenerationView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject var store: AppStore
    // Based on the whole window, so attaching a reference never rescales replies.
    var previewHeight: CGFloat = 500

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                // Keep drawing and hit regions in the same layout pass.
                VStack(alignment: .leading, spacing: 36) {
                    ForEach(store.selectedCreation) { job in
                        GenerationTurnView(job: job, previewHeight: previewHeight,
                                           maximumWidth: max(1, min(620, geometry.size.width - 56)))
                            .id(job.id)
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: 800).frame(maxWidth: .infinity).subtleScrollbars()
                .background(ConversationScrollAnchor(turns: store.selectedCreation.map(\.id)))
            }
        }
    }
}

struct GenerationTurnView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject var store: AppStore
    let job: Generation
    let previewHeight: CGFloat
    var maximumWidth: CGFloat = 620
    @State private var image: NSImage?
    @State private var loadingImage = true
    @State private var loadedImagePath: String?
    var body: some View {
        // Keep the header and actions attached to the actual image width.
        let replyWidth = image.map { min(maximumWidth, max(220, previewHeight * $0.size.width / max(1, $0.size.height))) } ?? maximumWidth

        VStack(alignment: .leading, spacing: 28) {
            PromptMessageView(prompt: job.request.prompt, createdAt: job.createdAt, inputImages: job.request.inputImages)
            if let reply = job.enhancement {
                PromptEnhancementMessageView(job: job, reply: reply, thinkingStream: store.thinkingStream(for: job),
                                             promptStream: store.promptStream(for: job))
                    .frame(maxWidth: maximumWidth)
            }
            if job.enhancement == nil || job.enhancement?.status == .completed {
            VStack(alignment: .leading, spacing: 12) {
                replyHeader
                if job.status == .completed {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: replyWidth, height: replyWidth * image.size.height / max(1, image.size.width))
                            .contentShape(Rectangle())
                            .onDrag { NSItemProvider(object: URL(fileURLWithPath: job.request.output) as NSURL) }
                            .contextMenu {
                                Button(L10n.text("Copy")) { store.copyImage(job) }
                                Button(L10n.text("Show in Finder")) { store.reveal(job) }
                                Button(L10n.text("Reference")) { store.reference(job) }.disabled(!store.canReferenceImages)
                                Button(L10n.text("View log")) { store.openLog(for: job) }
                            }
                        imageActions
                    } else if loadingImage {
                        ProgressView(L10n.text("Reading image…")).controlSize(.small).padding(.vertical, 30)
                    } else {
                        failure(L10n.text("Unable to read image. Check its location and access permissions."), symbol: "photo.badge.exclamationmark")
                    }
                } else if job.status == .running {
                    VStack(spacing: 17) {
                        ProgressView().controlSize(.regular).tint(Palette.ink)
                        Text(L10n.render(store.phase)).font(.system(size: 13, weight: .medium))
                        HStack(spacing: 5) {
                            ForEach(1...QwenImage21Turbo.inferenceSteps, id: \.self) { index in
                                Capsule().fill(index < store.currentStep ? Palette.ink : index == store.currentStep ? Palette.ink.opacity(0.45) : Palette.line)
                                    .frame(width: 25, height: 4)
                            }
                        }
                        Button(L10n.text("View live log")) { store.openLog(for: job) }.buttonStyle(HoverButtonStyle()).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }.frame(maxWidth: .infinity).frame(height: 260)
                        .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [5])))
                } else {
                    failure(job.error ?? job.status.label, symbol: job.status == .failed ? "exclamationmark.triangle" : "pause.circle")
                }
            }.frame(maxWidth: replyWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: job.status == .completed ? job.request.output : nil) {
            guard job.status == .completed else { return }
            // Keep the completed preview across task restarts.
            guard loadedImagePath != job.request.output else { return }
            loadingImage = true
            let loaded = await LocalImagePreview.load(job.request.output, maximumDimension: 1800)
            guard !Task.isCancelled else { return }
            image = loaded
            loadingImage = false
            loadedImagePath = job.request.output
        }
    }

    private var replyHeader: some View {
        HStack(alignment: .top, spacing: 9) {
            BrandMark(size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("LightX2V").font(.system(size: 12, weight: .semibold))
                    Text(QwenImage21Turbo.title).font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                HStack(spacing: 6) {
                    if job.status == .completed {
                        Label(L10n.text("Generated"), systemImage: "checkmark.circle.fill").foregroundStyle(Palette.green)
                        Text("·").foregroundStyle(Palette.muted)
                    }
                    if job.status == .running {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(L10n.render(store.elapsed(job, now: context.date))).monospacedDigit()
                        }
                    } else {
                        Text(L10n.render(store.elapsed(job))).monospacedDigit()
                    }
                }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var imageActions: some View {
        HStack(spacing: 4) {
            copyButton
            revealButton
            Button { store.openLog(for: job) } label: { Image(systemName: "terminal").frame(width: 30, height: 30) }
                .help(L10n.text("View this generation log")).accessibilityLabel(L10n.text("View this generation log"))
            referenceButton
        }
        .font(.system(size: 13)).foregroundStyle(Palette.muted)
        .buttonStyle(HoverButtonStyle(radius: 6))
    }

    private var copyButton: some View {
        Button { store.copyImage(job) } label: {
            Label(L10n.text("Copy"), systemImage: "doc.on.doc")
                .labelStyle(.iconOnly).frame(width: 30, height: 30)
        }.help(L10n.text("Copy image")).accessibilityLabel(L10n.text("Copy"))
    }

    private var revealButton: some View {
        Button { store.reveal(job) } label: {
            Label(L10n.text("Show in Finder"), systemImage: "folder")
                .labelStyle(.iconOnly).frame(width: 30, height: 30)
        }.help(L10n.text("Show image file in Finder")).accessibilityLabel(L10n.text("Show in Finder"))
    }

    private var referenceButton: some View {
        Button { store.reference(job) } label: {
            Label(L10n.text("Reference"), systemImage: "photo.badge.plus")
                .labelStyle(.iconOnly).frame(width: 30, height: 30)
        }.disabled(!store.canReferenceImages)
            .help(store.selectedModel == nil ? L10n.text("Choose a model first") : L10n.text("Add this image as a reference to the current prompt"))
            .accessibilityLabel(L10n.text("Reference"))
    }

    private func failure(_ message: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.render(job.status.label), systemImage: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent)
            Text(L10n.render(message)).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(7).textSelection(.enabled)
            HStack(spacing: 18) {
                Button(L10n.text("Retry with these settings")) { store.reuse(job) }.disabled(store.isImportingImages)
                Button(L10n.text("View log")) { store.openLog(for: job) }
                Button(L10n.text("Open task directory")) { store.reveal(job) }
            }.buttonStyle(HoverButtonStyle()).font(.system(size: 11))
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct LogPanel: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: "terminal"); Text(L10n.text("Run log")).fontWeight(.medium)
                    if !store.selectedCreation.isEmpty {
                        Picker(L10n.text("Generation task"), selection: Binding(get: { store.logGenerationID }, set: { id in
                            if let id { store.selectLog(id) }
                        })) {
                            ForEach(Array(store.selectedCreation.enumerated()), id: \.element.id) { index, job in
                                Text(L10n.text("Run %@ · %@ · %@", [String(describing: index + 1), String(describing: job.createdAt.formatted(date: .omitted, time: .standard)), String(describing: L10n.render(job.status.label))]))
                                    .tag(Optional(job.id))
                            }
                        }.labelsHidden().pickerStyle(.menu).controlSize(.small).frame(maxWidth: 250)
                            .accessibilityLabel(L10n.text("Choose generation log"))
                    }
                    Spacer()
                    if let job = store.logGeneration { IconButton(symbol: "folder", label: L10n.text("Show complete log in Finder")) { store.revealLog(job) } }
                    IconButton(symbol: "xmark", label: L10n.text("Close log")) { store.showLogs = false }
                }.font(.system(size: 11))
                Text(L10n.text("Latest 90 KB · Each run keeps its full log in its task directory")).font(.system(size: 9)).foregroundStyle(Palette.muted)
            }.padding(.horizontal, 18).padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(store.logs.isEmpty ? L10n.text("Real LightX2V logs will appear here when generation starts.") : store.logs)
                                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding(12)
                            Color.clear.frame(width: 1, height: 1).id("log-end")
                        }.frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
                            .subtleScrollbars()
                    }.onAppear { proxy.scrollTo("log-end", anchor: .bottomLeading) }
                        .onChange(of: store.logs) { _, _ in proxy.scrollTo("log-end", anchor: .bottomLeading) }
                }
            }.environment(\.layoutDirection, .leftToRight)
        }.background(Palette.surfaceSubtle).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}
