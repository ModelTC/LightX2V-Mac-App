import SwiftUI
import AppKit
import LightX2VCore

struct InspectorView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { Text("模型准备").font(.system(size: 12, weight: .semibold)); Spacer(); Image(systemName: "cube.transparent").foregroundStyle(Palette.muted) }
                            .frame(height: 58).padding(.top, 28).id("model-preparation")
                        Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, -20)
                        ModelPreparationView().padding(.vertical, 20)
                        Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, -20)
                        HStack { Text("生成参数").font(.system(size: 12, weight: .semibold)); Spacer(); Image(systemName: "slider.horizontal.3").foregroundStyle(Palette.muted) }
                            .padding(.top, 22).padding(.bottom, 20)
                        GenerationParametersView().padding(.bottom, 23)
                    }
                }.onChange(of: store.modelPreparationFocus) { _, _ in
                    withAnimation { proxy.scrollTo("model-preparation", anchor: .top) }
                }
            }
        }.padding(.horizontal, 20).background(Color(red: 0.972, green: 0.969, blue: 0.958))
    }
}

struct ModelPreparationView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 14) {
                PathSettingField(title: "模型目录", value: $store.modelDirectory, directory: true, compact: true)
                PathSettingField(title: "Config 配置", value: $store.modelConfig, directory: false, compact: true)
            }.disabled(store.busy)
            HStack {
                if store.hasUnsavedModelSettings {
                    Button("撤销修改") { store.discardModelSettings() }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                Button(store.hasUnsavedModelSettings ? "保存并检查" : "检查模型") { store.applyModelSettings() }
                    .buttonStyle(.borderedProminent).tint(Palette.ink)
            }.font(.system(size: 10)).controlSize(.small).disabled(store.busy)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if store.isChecking { ProgressView().controlSize(.mini) }
                    else { Image(systemName: store.hasUnsavedModelSettings ? "pencil.circle" : store.environmentReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(!store.hasUnsavedModelSettings && store.environmentReady ? Palette.green : Palette.accent) }
                    Text(store.isChecking ? "检查中…" : store.hasUnsavedModelSettings ? "模型设置待保存" : store.environmentReady ? "运行环境可用" : "运行环境需要检查")
                        .font(.system(size: 10, weight: .medium))
                }
                Text(store.hasUnsavedModelSettings ? "保存并检查后可开始生成。" : store.environmentMessage)
                    .font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(3)
                    .help(store.hasUnsavedModelSettings ? "保存并检查后可开始生成。" : store.environmentMessage)
            }
        }
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
                VStack(alignment: .leading, spacing: 4) { Text("通用设置").font(.system(size: 20, weight: .semibold)); Text("配置本地运行环境与生成结果的保存位置").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                Spacer()
            }
            VStack(spacing: 16) {
                PathSettingField(title: "LightX2V 源码目录", value: $settings.repository, directory: true)
                PathSettingField(title: "Python 可执行文件", value: $settings.python, directory: false)
                PathSettingField(title: "生成结果目录", value: $settings.outputDirectory, directory: true, allowsCreatingDirectories: true)
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
            Text("模型目录与 Config 配置请在主界面右侧的「模型准备」中设置。")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            HStack {
                Button("恢复默认路径") {
                    let defaults = AppSettings.defaults
                    settings.repository = defaults.repository
                    settings.python = defaults.python
                    settings.outputDirectory = defaults.outputDirectory
                }.disabled(store.busy)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并检查") { store.applyGeneralSettings(settings); dismiss() }.keyboardShortcut(.defaultAction).disabled(store.busy).buttonStyle(.borderedProminent).tint(Palette.ink)
            }
        }.padding(28).frame(width: 660).background(Palette.canvas).foregroundStyle(Palette.ink)
    }
}

struct PathSettingField: View {
    let title: String
    @Binding var value: String
    let directory: Bool
    var compact = false
    var allowsCreatingDirectories = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: compact ? 10 : 11, weight: .medium))
            HStack(spacing: 8) {
                TextField(title, text: $value).font(.system(size: compact ? 10 : 11, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(title).help(value)
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = allowsCreatingDirectories
                    panel.directoryURL = URL(fileURLWithPath: value).deletingLastPathComponent()
                    if panel.runModal() == .OK, let url = panel.url { value = url.path }
                } label: {
                    if compact { Image(systemName: "folder").frame(width: 16, height: 16) }
                    else { Text("选择…") }
                }.font(.system(size: 11)).help("选择\(title)").accessibilityLabel("选择\(title)")
            }
        }
    }
}
