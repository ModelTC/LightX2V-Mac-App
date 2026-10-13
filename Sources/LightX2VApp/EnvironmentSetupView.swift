import SwiftUI
import AppKit
import LightX2VCore

struct EnvironmentSearchView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let environments: [PythonEnvironment]
    let searching: Bool
    let cancelled: Bool
    let checked: Int
    let total: Int
    let error: String?
    var managedInstallIssue: String? = nil
    var installSource: Binding<EnvironmentInstallSource> = .constant(.pypi)
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
                    Text(L10n.text("Choose PyTorch environment")).font(.system(size: 18, weight: .semibold))
                    Text(searching ? L10n.text("Checking %@ / %@ environments…", [String(describing: checked), String(describing: total)]) : cancelled ? L10n.text("Search stopped") : compatibleCount == 0 ? L10n.text("No compatible environment found") : L10n.text("Found %@ compatible environments", [String(describing: compatibleCount)]))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if searching { ProgressView().controlSize(.small) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.text("Required dependencies · Apple Silicon MPS")).font(.system(size: 10, weight: .medium))
                Text(PyTorchRequirements.summary).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        installationChoice(L10n.text("Manual installation"), symbol: "doc.text", detail: L10n.text("Follow the instructions, then search again."),
                                           button: L10n.text("View installation instructions"), action: onInstructions)
                        installationChoice(L10n.text("Install automatically in workspace"), symbol: "arrow.down.circle", detail: L10n.text("Install Miniconda, Python 3.11 and inference dependencies."),
                                           button: L10n.text("Start automatic installation"), issue: managedInstallIssue, sourceChoice: true, action: onInstall)
                    }
                    if environments.isEmpty && searching {
                        Text(L10n.text("Looking for Conda, venv, pyenv and other environments…"))
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 65)
                    }
                    if !environments.isEmpty {
                        if compatibleCount == 0 {
                            Text(L10n.text("Detected environments")).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                        }
                        ForEach(environments) { environment in
                            Button { onSelect(environment) } label: { EnvironmentResultRow(environment: environment) }
                                .buttonStyle(HoverButtonStyle(radius: 10, border: true, dimsWhenDisabled: false))
                                .disabled(!environment.isCompatible).help(L10n.render(environment.compatibilityDetail))
                        }
                    }
                }.padding(.trailing, 2).subtleScrollbars()
            }.frame(height: 330)
            if let error {
                Text(L10n.render(error)).font(.system(size: 11)).foregroundStyle(Palette.accent)
                    .lineLimit(3).help(L10n.render(error)).textSelection(.enabled)
            }
            HStack {
                if searching { Button(L10n.text("Stop search"), action: onStop) }
                else { Button { onSearch() } label: { Label(L10n.text("Search local environments"), systemImage: "magnifyingglass") } }
                Spacer()
                Button(L10n.text("Close"), action: onClose).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 630).background(Palette.canvas).foregroundStyle(Palette.ink)
            .buttonStyle(SettingsActionStyle()).tint(Palette.ink)
    }

    private func installationChoice(_ title: String, symbol: String, detail: String, button: String,
                                    issue: String? = nil, sourceChoice: Bool = false, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Image(systemName: symbol).font(.system(size: 19, weight: .light)).foregroundStyle(Palette.muted)
            Text(L10n.render(title)).font(.system(size: 12, weight: .semibold))
            Text(L10n.render(detail)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(3).frame(minHeight: 34, alignment: .topLeading)
            if sourceChoice {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("Installation source")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Picker(L10n.text("Installation source"), selection: installSource) {
                        ForEach(EnvironmentInstallSource.allCases) { option in Text(option.title).tag(option) }
                    }.labelsHidden().pickerStyle(.segmented).controlSize(.small).disabled(searching)
                        .accessibilityLabel(L10n.text("Installation source"))
                }
            }
            Button(button, action: action).font(.system(size: 11)).disabled(issue != nil || (sourceChoice && searching))
            if let issue {
                Text(L10n.render(issue)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
    }
}

private struct EnvironmentResultRow: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let environment: PythonEnvironment
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: environment.isCompatible ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(environment.isCompatible ? Palette.green : Palette.muted).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(environment.name == "System Python" ? L10n.text("System Python") : environment.name).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(environment.isCompatible ? L10n.text("Available") : L10n.text("Incompatible"))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(environment.isCompatible ? Palette.green : Palette.muted)
                }
                Text(environment.executable).environment(\.layoutDirection, .leftToRight).font(.system(size: 10, design: .monospaced))
                    .lineLimit(2).foregroundStyle(Palette.muted).multilineTextAlignment(.leading)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 5) {
                    ForEach(PyTorchRequirements.dependencies, id: \.name) { dependency in
                        let version = environment.version(of: dependency.name)
                        Text("\(dependency.name)  \(version.isEmpty ? L10n.text("Not installed") : version)")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                    }
                }
                Text(environment.isCompatible ? L10n.text("Python %@ · MPS available", [String(describing: environment.pythonVersion)]) : environment.compatibilityDetail)
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(3).multilineTextAlignment(.leading)
            }
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct EnvironmentInstallInstructions: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let onClose: () -> Void
    private var commands: String {
        return """
        pip install torch torchvision torchaudio transformers diffusers -U
        pip install loguru
        pip install imageio
        pip install imageio_ffmpeg
        pip install safetensors
        pip install einops
        pip install gguf
        pip install opencv-python
        pip install prometheus_client
        pip install pydantic
        pip install huggingface_hub
        pip install modelscope
        """
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("Install dependencies manually")).font(.system(size: 18, weight: .semibold))
            Text(L10n.text("Prepare a Python 3.11 environment and run these commands in it."))
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            ScrollView([.vertical, .horizontal]) {
                Text(commands).environment(\.layoutDirection, .leftToRight).font(.system(size: 11, design: .monospaced)).lineSpacing(7)
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(14)
            }.frame(height: 240).background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10)).subtleScrollbars()
            Text(L10n.text("After installation, search local environments in the APP and select this environment."))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            HStack {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commands, forType: .string) } label: {
                    Label(L10n.text("Copy installation commands"), systemImage: "doc.on.doc")
                }
                Spacer()
                Button(L10n.text("Close"), action: onClose).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 610).background(Palette.canvas).foregroundStyle(Palette.ink).buttonStyle(SettingsActionStyle())
    }
}

struct EnvironmentInstallView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let workspace: WorkspaceLayout
    var source: Binding<EnvironmentInstallSource> = .constant(.pypi)
    let progress: EnvironmentInstallProgress
    let lines: [String]
    let installing: Bool
    let cancelled: Bool
    let error: String?
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onSearch: () -> Void
    let onClose: () -> Void
    @State private var showLogs = true
    private var completed: Bool { progress.stage == .completed && !installing }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(completed ? L10n.text("Environment ready") : L10n.text("Install PyTorch environment")).font(.system(size: 18, weight: .semibold))
                Text("TorchLightX2V · Python 3.11").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Installation source")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                Picker(L10n.text("Installation source"), selection: source) {
                    ForEach(EnvironmentInstallSource.allCases) { option in Text(option.title).tag(option) }
                }.labelsHidden().pickerStyle(.segmented).disabled(installing || completed)
                    .accessibilityLabel(L10n.text("Installation source"))
            }
            Text(PyTorchEnvironmentInstaller.environment(in: workspace).path)
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 13) {
                ForEach(EnvironmentInstallStage.allCases.filter { $0 != .completed }, id: \.rawValue) { stage in
                    HStack(spacing: 10) {
                        Image(systemName: stage.rawValue < progress.stage.rawValue ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(stage.rawValue < progress.stage.rawValue ? Palette.green : Palette.muted)
                        Text(L10n.render(stage.title)).font(.system(size: 12, weight: stage == progress.stage ? .medium : .regular))
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
                Text(L10n.render(progress.detail)).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            if cancelled { Text(L10n.text("Installation cancelled. You can resume.")).font(.system(size: 11)).foregroundStyle(Palette.muted) }
            if let error {
                Text(L10n.render(error)).font(.system(size: 11)).foregroundStyle(Palette.accent).lineLimit(5).help(L10n.render(error)).textSelection(.enabled)
            }
            Button { showLogs.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(showLogs ? 90 : 0))
                    Text(L10n.text("Installation log"))
                }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 6).padding(.vertical, 5)
            }.buttonStyle(HoverButtonStyle(radius: 6))
                .accessibilityValue(showLogs ? L10n.text("Expanded") : L10n.text("Collapsed"))
            if showLogs {
                ScrollViewReader { scroll in
                    ScrollView {
                        Text(lines.joined(separator: "\n")).environment(\.layoutDirection, .leftToRight).font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("log-bottom")
                    }.padding(10).frame(height: 115).background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
                        .subtleScrollbars()
                        .onAppear { scroll.scrollTo("log-bottom", anchor: .bottom) }
                        .onChange(of: lines) { _, _ in scroll.scrollTo("log-bottom", anchor: .bottom) }
                }
            }
            HStack {
                if installing { Button(L10n.text("Cancel installation"), action: onCancel).keyboardShortcut(.cancelAction) }
                else if !completed { Button(L10n.text(cancelled || error != nil ? "Resume installation" : "Start automatic installation"), action: onRetry).buttonStyle(SettingsActionStyle(prominent: true)) }
                Spacer()
                if completed {
                    Button(L10n.text("Close"), action: onClose)
                    Button(L10n.text("Search local environments"), action: onSearch).buttonStyle(SettingsActionStyle(prominent: true)).keyboardShortcut(.defaultAction)
                } else if !installing { Button(L10n.text("Close"), action: onClose).keyboardShortcut(.cancelAction) }
            }
        }.padding(24).frame(width: 610).background(Palette.canvas).foregroundStyle(Palette.ink).buttonStyle(SettingsActionStyle())
    }
}
