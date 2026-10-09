import SwiftUI
import AppKit
import LightX2VCore

enum Palette {
    static let canvas = Color(red: 0.985, green: 0.981, blue: 0.971)
    static let sidebar = Color(red: 0.946, green: 0.941, blue: 0.925)
    static let prompt = Color(red: 0.914, green: 0.937, blue: 0.913)
    static let ink = Color(red: 0.17, green: 0.18, blue: 0.17)
    static let muted = Color(red: 0.49, green: 0.50, blue: 0.47)
    static let line = Color.black.opacity(0.075)
    static let accent = Color(red: 0.78, green: 0.32, blue: 0.21)
    static let green = Color(red: 0.28, green: 0.48, blue: 0.35)
}

struct BrandMark: View {
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29).fill(Palette.ink)
            Image(systemName: "bolt.fill").font(.system(size: size * 0.56, weight: .medium)).foregroundStyle(.white)
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
                .background(active ? Palette.line : .clear, in: RoundedRectangle(cornerRadius: 7)) }
            .buttonStyle(.plain).foregroundStyle(Palette.muted).help(label).accessibilityLabel(label)
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
        .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
        .overlay(alignment: .top) { WindowDragArea(isNativeTitleBar: true).frame(height: 28) }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $store.showSettings) { SettingsView(settings: store.settings).environmentObject(store) }
        .alert("LightX2V APP", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .task { store.checkEnvironment() }
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
                    .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
            }.buttonStyle(.plain).padding(.horizontal, 14)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                TextField("搜索创作", text: $store.search).textFieldStyle(.plain).font(.system(size: 12))
            }.foregroundStyle(Palette.muted).padding(.horizontal, 24).padding(.vertical, 20)
            HStack { Text("最近创作"); Spacer(); Text("\(store.generations.count)").monospacedDigit() }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 24).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 5) {
                    if store.filteredGenerations.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.search.isEmpty ? "灵感从这里开始" : "没有找到匹配的创作").font(.system(size: 12))
                            if store.search.isEmpty { Text("生成的图片会保存在这里").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 18)
                    }
                    ForEach(store.filteredGenerations) { job in
                        Button { store.selectedID = job.id } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: job.status == .completed ? "photo" : job.status == .running ? "circle.dotted" : "clock")
                                    .font(.system(size: 12)).foregroundStyle(job.status == .running ? Palette.accent : Palette.muted).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(job.title).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                                    HStack(spacing: 5) {
                                        Text(job.createdAt, style: .date)
                                        Text("· \(job.status.label)")
                                    }.font(.system(size: 9)).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 0)
                            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                .background(store.selectedID == job.id ? Color.white.opacity(0.8) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).padding(.horizontal, 10)
                            .contextMenu {
                                Button("复用提示词和参数") { store.reuse(job) }
                                Button("在 Finder 中显示") { store.reveal(job) }
                                if job.status != .running { Button("从历史中移除（保留文件）") { store.removeFromHistory(job) } }
                            }
                    }
                }
            }
            Spacer(minLength: 12)
            if store.isRunning, store.selectedID != store.activeID {
                Button { store.selectedID = store.activeID } label: {
                    HStack { ProgressView().controlSize(.mini); Text("返回正在生成的图片").font(.system(size: 11)); Spacer() }
                        .padding(12).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).padding(12)
            }
            Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, 18)
            HStack(spacing: 10) {
                ZStack { RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.8)); Image(systemName: "desktopcomputer").font(.system(size: 15)) }.frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text("本机推理").font(.system(size: 12, weight: .medium))
                    HStack(spacing: 4) {
                        Circle().fill(store.environmentReady ? Palette.green : Palette.muted).frame(width: 5, height: 5)
                        Text(store.isChecking ? "检查环境中" : store.environmentReady ? "Apple Silicon · MPS" : "需要检查环境")
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
                        RoundedRectangle(cornerRadius: 19).fill(Color(red: 0.90, green: 0.88, blue: 0.83)).frame(width: 105, height: 118).rotationEffect(.degrees(-13)).offset(x: -29, y: 9)
                        RoundedRectangle(cornerRadius: 19).fill(Color(red: 0.85, green: 0.89, blue: 0.83)).frame(width: 105, height: 118).rotationEffect(.degrees(12)).offset(x: 29, y: 6)
                        ZStack {
                            RoundedRectangle(cornerRadius: 19).fill(Palette.canvas)
                            RoundedRectangle(cornerRadius: 19).stroke(Color.white, lineWidth: 2)
                            Image(systemName: "sparkles").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(Palette.accent)
                        }.frame(width: 100, height: 118).shadow(color: .black.opacity(0.06), radius: 14, y: 7)
                    }.frame(height: 145).padding(.bottom, 28)
                    Text("让想象，在此成像。").font(.system(size: 31, weight: .medium, design: .serif)).tracking(1)
                    Text("用文字描绘灵感，交给你的 Mac 来实现。").font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.top, 12)
                    HStack(spacing: 7) {
                        Image(systemName: "lock.shield").font(.system(size: 10))
                        Text("本地运行"); Text("·"); Text(store.selectedModel.title); Text("·"); Text("6 步生成")
                    }.font(.system(size: 10)).foregroundStyle(Palette.muted.opacity(0.85)).padding(.top, 16)
                    HStack(spacing: 10) {
                        ForEach(examples, id: \.0) { item in
                            Button { store.usePrompt(item.2) } label: {
                                VStack(alignment: .leading, spacing: 15) {
                                    Image(systemName: item.0).font(.system(size: 16, weight: .light)).foregroundStyle(Palette.accent)
                                    HStack { Text(item.1).font(.system(size: 12)); Spacer(minLength: 2); Image(systemName: "arrow.up.left").font(.system(size: 9)).foregroundStyle(Palette.muted) }
                                }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
                            }.buttonStyle(.plain).help(item.2)
                        }
                    }.frame(maxWidth: 470).padding(.top, 40)
                }.frame(maxWidth: .infinity).frame(minHeight: geometry.size.height).padding(.horizontal, 32)
            }
        }
    }
}

struct ComposerView: View {
    @EnvironmentObject var store: AppStore
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    // Match the macOS editor's leading text inset and first-line font.
                    if store.prompt.isEmpty { Text("描述你想生成的画面…").foregroundStyle(Palette.muted).padding(.leading, 5).allowsHitTesting(false) }
                    TextEditor(text: $store.prompt).scrollContentBackground(.hidden)
                        .focused($focused).frame(minHeight: 66, maxHeight: 92)
                        .accessibilityLabel("图像提示词")
                }.font(.system(size: 14))
                HStack(spacing: 7) {
                    ModelSelector()
                    Spacer()
                    if store.isRunning {
                        Button { store.stop() } label: {
                            HStack(spacing: 6) { Image(systemName: "stop.fill").font(.system(size: 9)); Text(store.isStopping ? "停止中" : "停止生成").font(.system(size: 11, weight: .medium)) }
                                .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 32).background(Palette.ink, in: Capsule())
                        }.buttonStyle(.plain).disabled(store.isStopping)
                    } else {
                        Button { store.generate() } label: {
                            HStack(spacing: 8) { Text("生成").font(.system(size: 12, weight: .medium)); Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)) }
                                .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 32)
                                .background(store.canGenerate ? Palette.ink : Palette.ink.opacity(0.25), in: Capsule())
                        }.buttonStyle(.plain).disabled(!store.canGenerate).keyboardShortcut(.return, modifiers: .command).help("生成图片 ⌘↵")
                    }
                }
            }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).stroke(focused ? Palette.ink.opacity(0.25) : Palette.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.025), radius: 12, y: 4)
            HStack {
                Text(store.isChecking ? "正在检查本地推理环境…" : "所有图像与提示词均保存在本机")
                Spacer()
                Text("⌘ ↵ 生成").font(.system(size: 10))
            }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.horizontal, 4)
        }.frame(maxWidth: 850)
    }
}

struct ModelSelector: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Menu {
            Picker("模型", selection: $store.selectedModel) {
                ForEach(GenerationModel.allCases) { model in
                    Text(model.title).tag(model)
                }
            }.pickerStyle(.inline)
            Text(store.selectedModel.detail)
            Divider()
            Button("模型准备") { store.showModelPreparation() }
        } label: {
            Label(store.selectedModel.title, systemImage: "cube.transparent")
        }
        .font(.system(size: 11, weight: .medium))
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 8).frame(height: 30)
        .background(Palette.sidebar.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .disabled(store.busy)
        .help("选择生成模型 · \(store.selectedModel.detail)")
        .accessibilityLabel("选择模型")
        .accessibilityValue(store.selectedModel.title)
    }
}

private struct PromptMessageView: View {
    let prompt: String
    let createdAt: Date

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 7) {
                Text(prompt)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink)
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
            .frame(maxWidth: 620, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct GenerationView: View {
    @EnvironmentObject var store: AppStore
    let job: Generation
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                PromptMessageView(prompt: job.request.prompt, createdAt: job.createdAt)
                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 9) {
                        BrandMark(size: 23)
                        Text("LightX2V").font(.system(size: 12, weight: .semibold))
                        Text("Qwen-Image-2.1").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(store.elapsed(job, now: context.date)).font(.system(size: 10)).foregroundStyle(Palette.muted).monospacedDigit()
                        }
                    }
                    if job.status == .completed {
                        if let image = NSImage(contentsOfFile: job.request.output) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 470)
                                .background(Palette.sidebar.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
                                .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: job.request.output)) ?? NSItemProvider() }
                                .contextMenu { Button("复制图片") { store.copyImage(job) }; Button("另存为…") { store.export(job) }; Button("在 Finder 中显示") { store.reveal(job) } }
                            HStack(spacing: 14) {
                                Label("已生成", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.green)
                                Spacer()
                                Button("复用参数") { store.reuse(job) }
                                Button { store.reveal(job) } label: { Image(systemName: "folder") }.help("在 Finder 中显示")
                                Button { store.copyImage(job) } label: { Image(systemName: "doc.on.doc") }.help("复制图片")
                                Button { store.export(job) } label: { Label("导出", systemImage: "square.and.arrow.up") }
                            }.font(.system(size: 11)).buttonStyle(.plain)
                        } else {
                            failure("图片文件已移动或删除。", symbol: "photo.badge.exclamationmark")
                        }
                    } else if job.status == .running {
                        VStack(spacing: 17) {
                            ProgressView().controlSize(.regular).tint(Palette.accent)
                            Text(store.phase).font(.system(size: 13, weight: .medium))
                            Text("模型按需载入内存，首次生成可能需要几分钟。")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            HStack(spacing: 5) {
                                ForEach(1...6, id: \.self) { index in
                                    Capsule().fill(index < store.currentStep ? Palette.accent : index == store.currentStep ? Palette.accent.opacity(0.45) : Palette.line)
                                        .frame(width: 25, height: 4)
                                }
                            }
                            Button("查看实时日志") { store.showLogs = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }.frame(maxWidth: .infinity).frame(height: 260)
                            .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [5])))
                    } else {
                        failure(job.error ?? job.status.label, symbol: job.status == .failed ? "exclamationmark.triangle" : "pause.circle")
                    }
                }
            }.padding(30).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
    }
    private func failure(_ message: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(job.status.label, systemImage: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent)
            Text(message).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(7).textSelection(.enabled)
            HStack(spacing: 18) {
                Button("复用参数重试") { store.reuse(job) }
                Button("查看日志") { store.showLogs = true }
                Button("打开任务文件夹") { store.reveal(job) }
            }.buttonStyle(.plain).font(.system(size: 11))
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 12))
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
                    }
                }.onChange(of: store.logs) { _, _ in if store.isRunning, store.selectedID == store.activeID { proxy.scrollTo("log-end", anchor: .bottom) } }
            }
        }.background(Color.white.opacity(0.7)).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}
