import SwiftUI
import AppKit
import LightX2VCore

struct EnvironmentSearchView: View {
    let environments: [PythonEnvironment]
    let searching: Bool
    let cancelled: Bool
    let checked: Int
    let total: Int
    let error: String?
    var managedInstallIssue: String? = nil
    let onSelect: (PythonEnvironment) -> Void
    let onSearch: () -> Void
    let onStop: () -> Void
    let onInstructions: () -> Void
    let onInstall: () -> Void
    let onClose: () -> Void
    private var compatibleCount: Int { environments.filter(\.isCompatible).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("选择 PyTorch 环境").font(.system(size: 18, weight: .semibold))
                    Text(searching ? "正在检测 \(checked) / \(total) 个环境…" : cancelled ? "搜索已停止" : compatibleCount == 0 ? "未找到符合要求的环境" : "找到 \(compatibleCount) 个符合要求的环境")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if searching { ProgressView().controlSize(.small) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("版本要求 · Apple Silicon MPS").font(.system(size: 10, weight: .medium))
                Text(PyTorchRequirements.summary).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !searching && compatibleCount == 0 {
                        HStack(alignment: .top, spacing: 12) {
                            installationChoice("自行安装", symbol: "doc.text", detail: "按简短说明准备环境，安装后重新搜索。",
                                               button: "查看安装说明", action: onInstructions)
                            installationChoice("在工作目录安装", symbol: "arrow.down.circle", detail: "自动安装 Miniconda、Python 3.11 和推理依赖。",
                                               button: "安装 TorchLightX2V", issue: managedInstallIssue, action: onInstall)
                        }
                    }
                    if environments.isEmpty && searching {
                        Text("正在查找 Conda、venv、pyenv 等常见环境…")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 65)
                    }
                    if !environments.isEmpty {
                        if compatibleCount == 0 {
                            Text("已检测环境").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                        }
                        ForEach(environments) { environment in
                            Button { onSelect(environment) } label: { EnvironmentResultRow(environment: environment) }
                                .buttonStyle(HoverButtonStyle(radius: 10, border: true, dimsWhenDisabled: false))
                                .disabled(!environment.isCompatible).help(environment.compatibilityDetail)
                        }
                    }
                }.padding(.trailing, 2).subtleScrollbars()
            }.frame(height: 330)
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.accent)
                    .lineLimit(3).help(error).textSelection(.enabled)
            }
            HStack {
                if searching { Button("停止搜索", action: onStop) }
                else { Button { onSearch() } label: { Label("搜索本机环境", systemImage: "magnifyingglass") } }
                Spacer()
                Button("返回", action: onClose).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 630).background(Palette.canvas).foregroundStyle(Palette.ink)
            .buttonStyle(SettingsActionStyle()).tint(Palette.ink)
    }

    private func installationChoice(_ title: String, symbol: String, detail: String, button: String,
                                    issue: String? = nil, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Image(systemName: symbol).font(.system(size: 19, weight: .light)).foregroundStyle(Palette.muted)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(3).frame(minHeight: 34, alignment: .topLeading)
            Button(button, action: action).font(.system(size: 11)).disabled(issue != nil)
            if let issue {
                Text(issue).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
    }
}

private struct EnvironmentResultRow: View {
    let environment: PythonEnvironment
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: environment.isCompatible ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(environment.isCompatible ? Palette.green : Palette.muted).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(environment.name).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(environment.isCompatible ? "可选择" : "不符合要求")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(environment.isCompatible ? Palette.green : Palette.muted)
                }
                Text(environment.executable).font(.system(size: 10, design: .monospaced))
                    .lineLimit(2).foregroundStyle(Palette.muted).multilineTextAlignment(.leading)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 5) {
                    ForEach(PyTorchRequirements.dependencies, id: \.name) { dependency in
                        let version = environment.version(of: dependency.name)
                        Text("\(dependency.name)  \(version.isEmpty ? "未安装" : version)")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                    }
                }
                Text(environment.isCompatible ? "Python \(environment.pythonVersion) · MPS 可用" : environment.compatibilityDetail)
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(3).multilineTextAlignment(.leading)
            }
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct EnvironmentInstallInstructions: View {
    let workspace: WorkspaceLayout
    let requirements: URL
    let onClose: () -> Void
    private var commands: String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        LIGHTX2V_WORKSPACE=\(quote(workspace.root.path))
        python3.11 -m venv "$LIGHTX2V_WORKSPACE/envs/TorchLightX2V"
        LIGHTX2V_PYTHON="$LIGHTX2V_WORKSPACE/envs/TorchLightX2V/bin/python"
        "$LIGHTX2V_PYTHON" -m pip install --upgrade pip
        "$LIGHTX2V_PYTHON" -m pip install -r "$LIGHTX2V_WORKSPACE/environments/requirements.txt"
        "$LIGHTX2V_PYTHON" -m pip check
        """
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("自行安装 PyTorch 环境").font(.system(size: 18, weight: .semibold))
            Text("准备 Apple Silicon 版 Python 3.11，在终端执行以下命令。")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            ScrollView([.vertical, .horizontal]) {
                Text(commands).font(.system(size: 11, design: .monospaced)).lineSpacing(7)
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(14)
            }.frame(height: 190).background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10)).subtleScrollbars()
            Text("已将完整依赖文件存入工作目录 / environments / requirements.txt。安装完成后，返回并点击“搜索本机环境”。")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            HStack {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commands, forType: .string) } label: {
                    Label("复制安装命令", systemImage: "doc.on.doc")
                }
                Spacer()
                Button("返回", action: onClose).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 610).background(Palette.canvas).foregroundStyle(Palette.ink).buttonStyle(SettingsActionStyle())
    }
}

struct EnvironmentInstallView: View {
    let workspace: WorkspaceLayout
    let progress: EnvironmentInstallProgress
    let lines: [String]
    let installing: Bool
    let cancelled: Bool
    let error: String?
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onSearch: () -> Void
    let onClose: () -> Void
    @State private var showLogs = false
    private var completed: Bool { progress.stage == .completed && !installing }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(completed ? "环境已就绪" : "安装 PyTorch 环境").font(.system(size: 18, weight: .semibold))
                Text("TorchLightX2V · Python 3.11").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Text(PyTorchEnvironmentInstaller.environment(in: workspace).path)
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 13) {
                ForEach(EnvironmentInstallStage.allCases.filter { $0 != .completed }, id: \.rawValue) { stage in
                    HStack(spacing: 10) {
                        Image(systemName: stage.rawValue < progress.stage.rawValue ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(stage.rawValue < progress.stage.rawValue ? Palette.green : Palette.muted)
                        Text(stage.title).font(.system(size: 12, weight: stage == progress.stage ? .medium : .regular))
                            .foregroundStyle(stage == progress.stage || stage.rawValue < progress.stage.rawValue ? Palette.ink : Palette.muted)
                        Spacer()
                        if stage == progress.stage && installing { ProgressView().controlSize(.mini) }
                    }
                }
            }.padding(15).background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 12))
            if progress.stage == .download && installing, let fraction = progress.fraction {
                ProgressView(value: fraction).tint(Palette.ink)
            }
            if !progress.detail.isEmpty && (installing || completed) {
                Text(progress.detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            if cancelled { Text("安装已取消，可继续安装。").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.accent).lineLimit(5).help(error).textSelection(.enabled)
            }
            DisclosureGroup("安装日志", isExpanded: $showLogs) {
                ScrollViewReader { scroll in
                    ScrollView {
                        Text(lines.suffix(80).joined(separator: "\n")).font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("log-bottom")
                    }.padding(10).frame(height: 115).background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
                        .subtleScrollbars().onChange(of: lines.last) { _, _ in scroll.scrollTo("log-bottom", anchor: .bottom) }
                }
            }.font(.system(size: 11)).tint(Palette.muted)
            HStack {
                if installing { Button("取消安装", action: onCancel).keyboardShortcut(.cancelAction) }
                else if !completed { Button("继续安装", action: onRetry) }
                Spacer()
                if completed {
                    Button("返回", action: onClose)
                    Button("搜索本机环境", action: onSearch).buttonStyle(SettingsActionStyle(prominent: true)).keyboardShortcut(.defaultAction)
                } else if !installing { Button("返回", action: onClose).keyboardShortcut(.cancelAction) }
            }
        }.padding(24).frame(width: 610).background(Palette.canvas).foregroundStyle(Palette.ink).buttonStyle(SettingsActionStyle())
    }
}
