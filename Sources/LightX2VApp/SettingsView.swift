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
                    }.subtleScrollbars()
                }.onChange(of: store.modelPreparationFocus) { _, _ in
                    withAnimation { proxy.scrollTo("model-preparation", anchor: .top) }
                }
            }
        }.padding(.horizontal, 20).background(Palette.inspector)
    }
}

struct ModelPreparationView: View {
    @EnvironmentObject var store: AppStore
    @State private var showsDetails = false
    private var needsModelSelection: Bool { store.modelDirectory.isEmpty || store.modelConfig.isEmpty }

    private var statusTitle: String {
        if store.isChecking { return "正在检查环境" }
        if store.hasUnsavedModelSettings { return "有未保存的修改" }
        if needsModelSelection { return "待准备模型" }
        if store.environmentReady { return "环境就绪" }
        return store.environmentMessage == "尚未检查运行环境" ? "尚未检查" : "检查未通过"
    }

    private var statusColor: Color {
        if store.isChecking || needsModelSelection { return Palette.muted }
        return store.environmentReady && !store.hasUnsavedModelSettings ? Palette.green : Palette.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                ModelResourceRow(title: "模型目录", value: $store.modelDirectory, directory: true)
                Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, 12)
                ModelResourceRow(title: "Config 配置", value: $store.modelConfig, directory: false)
            }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
            .disabled(store.busy)

            HStack(spacing: 7) {
                Group {
                    if store.isChecking { ProgressView().controlSize(.mini) }
                    else {
                        Image(systemName: store.hasUnsavedModelSettings ? "pencil.circle" : needsModelSelection ? "cube.transparent" : store.environmentReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(statusColor)
                    }
                }.frame(width: 14, height: 14)
                Text(statusTitle).font(.system(size: 10, weight: .medium))
                Spacer(minLength: 4)
                if store.hasUnsavedModelSettings {
                    Button("撤销") { store.discardModelSettings() }
                        .disabled(store.busy).accessibilityLabel("撤销模型设置修改")
                } else {
                    Button("详情") { showsDetails = true }
                        .accessibilityLabel("查看环境检查详情")
                        .popover(isPresented: $showsDetails, arrowEdge: .leading) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("环境检查").font(.system(size: 13, weight: .semibold))
                                ScrollView {
                                    Text(store.environmentMessage).font(.system(size: 11))
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).subtleScrollbars()
                                }.frame(maxHeight: 180)
                                Text("检查路径、配置与 MPS 可用性，不加载模型权重。")
                                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }.padding(18).frame(width: 320)
                        }
                }
            }.font(.system(size: 10)).buttonStyle(HoverButtonStyle(radius: 6)).foregroundStyle(Palette.muted)

            if !store.isChecking && !store.environmentReady && !store.hasUnsavedModelSettings && store.environmentMessage != "尚未检查运行环境" {
                Text(store.environmentMessage).font(.system(size: 10)).foregroundStyle(needsModelSelection ? Palette.muted : Palette.accent)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(store.environmentMessage)
            }

            Button { store.applyModelSettings() } label: {
                HStack(spacing: 7) {
                    if !store.isChecking { Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .medium)) }
                    Text(store.isChecking ? "正在检查…" : store.hasUnsavedModelSettings ? "保存并检查" : "检查模型")
                }
                .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).frame(height: 26)
            }.buttonStyle(SettingsActionStyle(prominent: true)).disabled(store.busy)
        }
    }
}

private struct ModelResourceRow: View {
    let title: String
    @Binding var value: String
    let directory: Bool
    @State private var showsEditor = false

    private var name: String {
        value.isEmpty ? "选择\(title)" : URL(fileURLWithPath: value).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { showsEditor = true } label: {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: directory ? "cube.transparent" : "doc.text")
                        .font(.system(size: 14)).foregroundStyle(Palette.muted)
                        .frame(width: 18).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.system(size: 10)).foregroundStyle(Palette.muted)
                        Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle(radius: 6)).accessibilityLabel("编辑\(title)：\(name)")
            .help("\(value)\n点击编辑完整路径")
            .popover(isPresented: $showsEditor, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 14) {
                    PathSettingField(title: title, value: $value, directory: directory)
                    HStack {
                        Spacer()
                        Button("完成") { showsEditor = false }.keyboardShortcut(.defaultAction)
                    }
                }.padding(18).frame(width: 420).buttonStyle(SettingsActionStyle())
            }
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
                panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
                panel.directoryURL = value.isEmpty ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: value).deletingLastPathComponent()
                if panel.runModal() == .OK, let url = panel.url { value = url.path }
            } label: {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(HoverButtonStyle(radius: 6)).help("选择\(title)").accessibilityLabel("选择\(title)")
        }.padding(12)
    }
}

struct FirstLaunchSetupView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        SettingsView(settings: store.settings)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.03), radius: 20, y: 6)
            .padding(40)
            .frame(minWidth: 760, minHeight: 540)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.sidebar)
            .overlay(alignment: .top) { WindowDragArea(isNativeTitleBar: true).frame(height: 28) }
    }
}

struct PathSettingField: View {
    let title: String
    @Binding var value: String
    let directory: Bool
    var allowsCreatingDirectories = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium))
            HStack(spacing: 8) {
                TextField(title, text: $value).font(.system(size: 11, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(title).help(value)
                    .dismissEditingOnOutsideClick()
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = allowsCreatingDirectories
                    panel.directoryURL = value.isEmpty ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: value).deletingLastPathComponent()
                    if panel.runModal() == .OK, let url = panel.url { value = url.path }
                } label: {
                    Text("选择…")
                }.font(.system(size: 11)).help("选择\(title)").accessibilityLabel("选择\(title)")
            }
        }
    }
}
