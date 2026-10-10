import SwiftUI
import AppKit
import LightX2VCore
import UniformTypeIdentifiers

struct BrandMark: View {
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29).fill(Palette.button)
            Image(systemName: "bolt.fill").font(.system(size: size * 0.56, weight: .medium)).foregroundStyle(Palette.onButton)
        }.frame(width: size, height: size)
    }
}

struct IconButton: View {
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
    @EnvironmentObject var store: AppStore
    @State private var minimumWindowSize = ScreenFittingWindow.minimumContentSize
    var body: some View {
        HStack(spacing: 0) {
            SidebarView().frame(width: 232)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(Palette.line).frame(height: 1)
                ZStack {
                    if let job = store.selected { GenerationView(job: job) }
                    else { WelcomeView() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.showLogs { LogPanel().frame(height: 205) }
                ComposerView().padding(.horizontal, 30).padding(.top, 12).padding(.bottom, 20)
            // The two sidebars and separators occupy 514 points in total.
            }.frame(minWidth: max(1, minimumWindowSize.width - 514)).background(Palette.canvas)
            if store.showInspector {
                Rectangle().fill(Palette.line).frame(width: 1)
                InspectorView().frame(width: 280)
            }
        }
        .foregroundStyle(Palette.ink)
        .tint(Palette.button)
        .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
        .overlay(alignment: .top) { WindowDragArea(isNativeTitleBar: true).frame(height: 28) }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $store.showSettings) { SettingsView(settings: store.settings).environmentObject(store) }
        .alert("LightX2V APP", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(Palette.muted)
                Text("工作空间").foregroundStyle(Palette.muted)
                Text("/").foregroundStyle(Palette.muted.opacity(0.5))
                Text(store.selected == nil ? "新建创作" : "图像生成").fontWeight(.medium)
                Spacer()
            }.frame(maxHeight: .infinity).background(WindowDragArea())
            IconButton(symbol: "terminal", label: "显示运行日志", active: store.showLogs) { store.showLogs.toggle() }
            IconButton(symbol: "sidebar.right", label: "显示模型准备与生成参数", active: store.showInspector) { store.showInspector.toggle() }
        }.font(.system(size: 12)).padding(.horizontal, 24).frame(height: 58).padding(.top, 28)
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                BrandMark(size: 28)
                Text("LightX2V").font(.system(size: 17, weight: .semibold))
                Text("APP").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
            }.padding(.horizontal, 22).padding(.top, 52).padding(.bottom, 27)
            Button { store.newGeneration() } label: {
                HStack { Image(systemName: "square.and.pencil"); Text("新建创作"); Spacer(); Text("⌘ N").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                    .font(.system(size: 13, weight: .medium)).padding(12)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
            }.buttonStyle(HoverButtonStyle(radius: 9, border: true)).disabled(store.isImportingImages).padding(.horizontal, 14)
            Text("最近创作")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 5) {
                    if store.generations.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("灵感从这里开始").font(.system(size: 12))
                            Text("生成的作品会保存在这里").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 18)
                    }
                    ForEach(store.generations) { job in
                        Button { store.selectedID = job.id } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: job.status == .completed ? "photo" : job.status == .running ? "circle.dotted" : "clock")
                                    .font(.system(size: 12)).foregroundStyle(job.status == .running ? Palette.ink : Palette.muted).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(job.title).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                                    HStack(spacing: 5) {
                                        Text(job.createdAt, style: .date)
                                        Text("· \(job.status.label)")
                                    }.font(.system(size: 9)).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 0)
                            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                .background(store.selectedID == job.id ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(HoverButtonStyle()).padding(.horizontal, 10)
                            .contextMenu {
                                Button("复用创作") { store.reuse(job) }.disabled(store.isImportingImages)
                                Button("在 Finder 中显示") { store.reveal(job) }
                                if job.status != .running { Button("从历史中移除（保留文件）") { store.removeFromHistory(job) } }
                            }
                    }
                }.subtleScrollbars()
            }
            Spacer(minLength: 12)
            if store.isRunning, store.selectedID != store.activeID {
                Button { store.selectedID = store.activeID } label: {
                    HStack { ProgressView().controlSize(.mini); Text("返回正在生成的图片").font(.system(size: 11)); Spacer() }
                        .padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(HoverButtonStyle()).padding(12)
            }
            Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, 18)
            HStack(spacing: 10) {
                ZStack { RoundedRectangle(cornerRadius: 8).fill(Palette.selection); Image(systemName: "desktopcomputer").font(.system(size: 15)) }.frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text("本机推理").font(.system(size: 12, weight: .medium))
                    HStack(spacing: 4) {
                        Circle().fill(store.environmentReady ? Palette.green : Palette.muted).frame(width: 5, height: 5)
                        Text(MacHardware.sidebarDescription)
                            .font(.system(size: 9)).foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 0)
                IconButton(symbol: "gearshape", label: "打开设置") { store.showSettings = true }
            }.padding(.horizontal, 16).padding(.vertical, 20)
        }.background(Palette.sidebar)
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: AppStore
    private let examples: [(String, String, String)] = [
        ("sparkles", "一点奇想", "A capybara wearing a wizard hat, oil painting"),
        ("camera.aperture", "一帧光影", "A quiet Japanese cafe on a rainy afternoon, soft window light, cinematic photography, warm tones"),
        ("leaf", "一处自然", "A tiny glass house in a misty green forest, soft morning sunlight, architectural photography, peaceful atmosphere")
    ]
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
                    Text("让想象，在此成像。").font(.system(size: 30, weight: .semibold))
                    Text("用文字描绘灵感，交给你的 Mac 来实现。").font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.top, 12)
                    HStack(spacing: 7) {
                        Image(systemName: "lock.shield").font(.system(size: 10))
                        Text("本地运行")
                        if let model = store.selectedModel {
                            Text("·"); Text(model.title); Text("·"); Text("6 步生成")
                        }
                    }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.top, 16)
                    if store.selectedModel == .qwenImage21 {
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
    @EnvironmentObject var store: AppStore
    @State private var focused = false
    @State private var editorHeight = PromptScrollView.minimumHeight
    @State private var dropTargeted = false
    @State private var editorDropTargeted = false
    private var highlightingDrop: Bool { store.canAddImages && (dropTargeted || editorDropTargeted) }
    var body: some View {
        VStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 8) {
                if !store.inputImages.isEmpty {
                    InputImageStrip(images: store.inputImages, remove: store.removeInputImage)
                        .disabled(store.isImportingImages)
                    if store.inputImages.count > 3 {
                        Text("参考图较多时画面可能失真，当前模型建议使用 1–3 张。")
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
            HStack {
                Text(store.isChecking ? "正在检查本地推理环境…" : "所有图像与提示词均保存在本机")
                Spacer()
            }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.horizontal, 4)
        }.frame(maxWidth: 850)
    }

    private var promptEditor: some View {
        PromptEditor(text: $store.prompt, height: $editorHeight, focused: $focused,
                     composing: $store.isComposingPrompt,
                     placeholder: store.inputImages.isEmpty ? "描述你想生成的画面…" : "描述你想如何修改图片…",
                     onDropFiles: store.canAddImages ? { store.addInputImages($0) } : nil,
                     onDropHover: { editorDropTargeted = $0 },
                     onSubmit: { if store.canGenerate { store.generate() } })
            .frame(height: editorHeight)
    }

    private var composerActions: some View {
        HStack(spacing: 7) {
            if store.selectedModel == .qwenImage21 { attachmentButton }
            ModelSelector()
            Spacer()
            if store.isRunning {
                Button { store.stop() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                        Text(store.isStopping ? "停止中" : "停止生成").font(.system(size: 11, weight: .medium))
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
                    .help("生成图片").accessibilityLabel("生成图片")
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
            .help("添加图片（建议 1–3 张，最多 8 张）").accessibilityLabel("添加图片")
    }

}

struct ModelSelector: View {
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
            Label(store.selectedModel?.title ?? "选择模型", systemImage: "cube.transparent")
        }
        .font(.system(size: 11, weight: .medium))
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 8).frame(height: 30)
        .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 7))
        .hoverSurface(radius: 7, border: false)
        .disabled(store.busy)
        .help("选择生成模型")
        .accessibilityLabel("选择模型")
        .accessibilityValue(store.selectedModel?.title ?? "未选择")
    }
}

private struct PromptMessageView: View {
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
    @EnvironmentObject var store: AppStore
    let job: Generation
    @State private var image: NSImage?
    @State private var loadingImage = true
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                let previewHeight = min(500, max(280, geometry.size.height - 235))
                // Keep the header and actions attached to the actual image width.
                let replyWidth = image.map { min(620, max(220, previewHeight * $0.size.width / max(1, $0.size.height))) } ?? 620

                VStack(alignment: .leading, spacing: 28) {
                    PromptMessageView(prompt: job.request.prompt, createdAt: job.createdAt, inputImages: job.request.inputImages)
                    VStack(alignment: .leading, spacing: 12) {
                        replyHeader
                        if job.status == .completed {
                            if let image {
                                Image(nsImage: image).resizable().scaledToFit()
                                    .onDrag { NSItemProvider(object: URL(fileURLWithPath: job.request.output) as NSURL) }
                                    .contextMenu { Button("复制图片") { store.copyImage(job) }; Button("另存为…") { store.export(job) }; Button("在 Finder 中显示") { store.reveal(job) } }
                                imageActions
                            } else if loadingImage {
                                ProgressView("正在读取图片…").controlSize(.small).padding(.vertical, 30)
                            } else {
                                failure("无法读取图片，请检查文件位置和访问权限。", symbol: "photo.badge.exclamationmark")
                            }
                        } else if job.status == .running {
                            VStack(spacing: 17) {
                                ProgressView().controlSize(.regular).tint(Palette.ink)
                                Text(store.phase).font(.system(size: 13, weight: .medium))
                                Text("模型按需载入内存，首次生成可能需要几分钟。")
                                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                HStack(spacing: 5) {
                                    ForEach(1...6, id: \.self) { index in
                                        Capsule().fill(index < store.currentStep ? Palette.ink : index == store.currentStep ? Palette.ink.opacity(0.45) : Palette.line)
                                            .frame(width: 25, height: 4)
                                    }
                                }
                                Button("查看实时日志") { store.showLogs = true }.buttonStyle(HoverButtonStyle()).font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }.frame(maxWidth: .infinity).frame(height: 260)
                                .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [5])))
                        } else {
                            failure(job.error ?? job.status.label, symbol: job.status == .failed ? "exclamationmark.triangle" : "pause.circle")
                        }
                    }.frame(maxWidth: replyWidth, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: 800).frame(maxWidth: .infinity).subtleScrollbars()
            }
        }.task(id: job.status == .completed ? job.request.output : nil) {
            image = nil
            loadingImage = true
            guard job.status == .completed else { return }
            let loaded = await LocalImagePreview.load(job.request.output, maximumDimension: 1800)
            guard !Task.isCancelled else { return }
            image = loaded
            loadingImage = false
        }
    }

    private var replyHeader: some View {
        HStack(alignment: .top, spacing: 9) {
            BrandMark(size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("LightX2V").font(.system(size: 12, weight: .semibold))
                    Text("Qwen-Image-2.1").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                HStack(spacing: 6) {
                    if job.status == .completed {
                        Label("已生成", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.green)
                        Text("·").foregroundStyle(Palette.muted)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(store.elapsed(job, now: context.date)).foregroundStyle(Palette.muted).monospacedDigit()
                    }
                }.font(.system(size: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var imageActions: some View {
        HStack(spacing: 6) {
            Button { store.copyImage(job) } label: {
                Label("复制", systemImage: "doc.on.doc")
                    .padding(.horizontal, 9).frame(height: 28)
            }.help("复制图片")
            Button { store.export(job) } label: {
                Label("导出", systemImage: "square.and.arrow.up")
                    .padding(.horizontal, 9).frame(height: 28)
            }.help("保存图片到其他位置")
            Menu {
                Button("复用创作") { store.reuse(job) }.disabled(store.isImportingImages)
                Button("在 Finder 中显示") { store.reveal(job) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("更多操作").accessibilityLabel("图片更多操作")
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
        .buttonStyle(HoverButtonStyle(radius: 6))
    }

    private func failure(_ message: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(job.status.label, systemImage: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent)
            Text(message).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(7).textSelection(.enabled)
            HStack(spacing: 18) {
                Button("复用参数重试") { store.reuse(job) }.disabled(store.isImportingImages)
                Button("查看日志") { store.showLogs = true }
                Button("打开任务文件夹") { store.reveal(job) }
            }.buttonStyle(HoverButtonStyle()).font(.system(size: 11))
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct LogPanel: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal"); Text("运行日志").fontWeight(.medium)
                Text("最近 90 KB · 完整日志保存在任务目录").font(.system(size: 9)).foregroundStyle(Palette.muted)
                Spacer()
                if let job = store.selected { IconButton(symbol: "folder", label: "打开完整日志所在文件夹") { store.reveal(job) } }
                IconButton(symbol: "xmark", label: "关闭日志") { store.showLogs = false }
            }.font(.system(size: 11)).padding(.horizontal, 18).frame(height: 36)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(store.logs.isEmpty ? "开始生成后，这里会显示真实的 LightX2V 运行日志。" : store.logs)
                            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding(12)
                        Color.clear.frame(height: 1).id("log-end")
                    }.subtleScrollbars()
                }.onChange(of: store.logs) { _, _ in if store.isRunning, store.selectedID == store.activeID { proxy.scrollTo("log-end", anchor: .bottom) } }
            }
        }.background(Palette.surfaceSubtle).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}
