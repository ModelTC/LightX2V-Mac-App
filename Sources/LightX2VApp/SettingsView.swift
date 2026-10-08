import SwiftUI
import AppKit
import LightX2VCore

struct InspectorView: View {
    @EnvironmentObject var store: AppStore
    private let presets = [("1:1", 1024, 1024), ("4:3", 1152, 864), ("3:4", 864, 1152), ("16:9", 1536, 864)]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("生成参数").font(.system(size: 12, weight: .semibold)); Spacer(); Image(systemName: "slider.horizontal.3").foregroundStyle(Palette.muted) }
                .frame(height: 58).padding(.top, 28)
            Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, -20)
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    VStack(alignment: .leading, spacing: 11) {
                        sectionLabel("模型")
                        HStack(spacing: 10) {
                            Image(systemName: "cube.transparent").font(.system(size: 22, weight: .light)).foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Qwen-Image-2.1").font(.system(size: 12, weight: .medium))
                                Text("Viggle v0.3 · BF16").font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("画面尺寸")
                        HStack(spacing: 5) {
                            ForEach(presets, id: \.0) { preset in
                                Button {
                                    store.width = preset.1
                                    store.height = preset.2
                                } label: {
                                    VStack(spacing: 7) {
                                        RoundedRectangle(cornerRadius: 2).stroke(lineWidth: 1)
                                            .frame(width: preset.1 >= preset.2 ? 20 : 14, height: preset.1 > preset.2 ? 14 : 20).frame(height: 20)
                                        Text(preset.0).font(.system(size: 9))
                                    }.frame(maxWidth: .infinity).padding(.vertical, 10)
                                        .foregroundStyle(isPreset(preset) ? Palette.ink : Palette.muted)
                                        .background(isPreset(preset) ? Palette.sidebar : Color.white, in: RoundedRectangle(cornerRadius: 7))
                                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(isPreset(preset) ? Palette.ink.opacity(0.3) : Palette.line, lineWidth: 1))
                                }.buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 8) {
                            dimension("宽", value: $store.width)
                            Text("×").foregroundStyle(Palette.muted).padding(.top, 18)
                            dimension("高", value: $store.height)
                        }
                        HStack { Text("32 的倍数 · 256–2048 px"); Spacer(); Button("512 测试") { store.width = 512; store.height = 512 } }
                            .font(.system(size: 9)).foregroundStyle(Palette.muted).buttonStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("随机种子")
                        HStack {
                            TextField("42", text: $store.seedText).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).disabled(store.randomSeed).accessibilityLabel("随机种子")
                            Button { store.seedText = String(Int64.random(in: 0...4294967295)) } label: { Image(systemName: "dice").foregroundStyle(Palette.muted) }.buttonStyle(.plain).help("随机选择一个种子").disabled(store.randomSeed)
                        }.padding(10).background(.white, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line, lineWidth: 1))
                        Toggle("每次使用随机种子", isOn: $store.randomSeed).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).tint(Palette.ink)
                    }
                    VStack(alignment: .leading, spacing: 13) {
                        sectionLabel("推理设置")
                        infoRow("采样步数", "6 步")
                        infoRow("引导强度", "1.0 · 无 CFG")
                        infoRow("运行设备", "Apple MPS")
                        infoRow("内存策略", "磁盘流式加载")
                        Text("沿用 Viggle v0.3 的蒸馏配置，步数与噪声调度保持配套。").font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4)
                    }
                    if let selected = store.selected {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionLabel("当前作品")
                            infoRow("实际尺寸", "\(selected.request.width) × \(selected.request.height)")
                            infoRow("实际种子", String(selected.request.seed))
                            infoRow("状态", selected.status.label)
                            Button { store.reuse(selected) } label: { Label("将参数带入新创作", systemImage: "arrow.uturn.backward") }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent)
                        }.padding(.top, 5)
                    }
                }.padding(.vertical, 23)
            }
            Spacer(minLength: 10)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive").font(.system(size: 11))
                    Text("为 Apple Silicon 优化").font(.system(size: 10, weight: .medium))
                }
                Text("\(Int(ProcessInfo.processInfo.physicalMemory / 1073741824)) GB 统一内存 · 按需加载权重").font(.system(size: 9)).foregroundStyle(Palette.muted)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(Palette.sidebar.opacity(0.7), in: RoundedRectangle(cornerRadius: 9)).padding(.bottom, 20)
        }.padding(.horizontal, 20).background(Color(red: 0.972, green: 0.969, blue: 0.958))
    }
    private func isPreset(_ preset: (String, Int, Int)) -> Bool { store.width == preset.1 && store.height == preset.2 }
    private func sectionLabel(_ title: String) -> some View { Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted) }
    private func dimension(_ name: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.system(size: 10)).foregroundStyle(Palette.muted)
            TextField(name, value: value, format: .number.grouping(.never)).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line, lineWidth: 1)).accessibilityLabel(name == "宽" ? "图片宽度" : "图片高度")
        }
    }
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(Palette.muted); Spacer(); Text(value) }.font(.system(size: 10))
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                BrandMark(size: 36)
                VStack(alignment: .leading, spacing: 4) { Text("本地运行设置").font(.system(size: 20, weight: .semibold)); Text("连接你的 LightX2V 与 Qwen-Image-2.1 模型").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                Spacer()
            }
            VStack(spacing: 16) {
                pathField("LightX2V 源码目录", value: $settings.repository, directory: true)
                pathField("Qwen-Image-2.1 模型目录", value: $settings.model, directory: true)
                pathField("MPS / Viggle v0.3 配置", value: $settings.config, directory: false)
                pathField("Python 可执行文件", value: $settings.python, directory: false)
                pathField("生成结果目录", value: $settings.outputDirectory, directory: true)
            }.disabled(store.busy)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if store.isChecking { ProgressView().controlSize(.mini) }
                    else { Image(systemName: store.environmentReady ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(store.environmentReady ? Palette.green : Palette.accent) }
                    Text(store.isChecking ? "检查中…" : store.environmentReady ? "运行环境可用" : "运行环境需要检查").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("重新检查已保存设置") { store.checkEnvironment() }.disabled(store.busy).font(.system(size: 11))
                }
                ScrollView { Text(store.environmentMessage).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 75)
            }.padding(14).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 10))
            Text("模型与 Python 环境由本机提供。应用不会自动下载权重或安装依赖；所有推理使用本地 MPS。")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            HStack {
                Button("恢复默认路径") { settings = .defaults }.disabled(store.busy)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并检查") { store.applySettings(settings); dismiss() }.keyboardShortcut(.defaultAction).disabled(store.busy).buttonStyle(.borderedProminent).tint(Palette.ink)
            }
        }.padding(28).frame(width: 660).background(Palette.canvas).foregroundStyle(Palette.ink)
    }
    private func pathField(_ title: String, value: Binding<String>, directory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium))
            HStack(spacing: 8) {
                TextField(title, text: value).font(.system(size: 11, design: .monospaced)).textFieldStyle(.roundedBorder)
                Button("选择…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = directory
                    panel.directoryURL = URL(fileURLWithPath: value.wrappedValue).deletingLastPathComponent()
                    if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path }
                }.font(.system(size: 11))
            }
        }
    }
}
