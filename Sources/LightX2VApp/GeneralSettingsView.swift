import SwiftUI
import AppKit
import LightX2VCore

struct SettingsView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject var store: AppStore
    @FocusState private var headerFocused: Bool
    @State var settings: AppSettings
    @State private var setupProgress = GeneralSetupProgress()
    @State private var saveError: String?
    @State private var showEnvironments = false
    @State private var searching = false
    @State private var environments: [PythonEnvironment] = []
    @State private var checkedCount = 0
    @State private var totalCount = 0
    @State private var searchError: String?
    @State private var searchCancelled = false
    @State private var operationID: UUID?
    @State private var showInstallInstructions = false
    @State private var showInstaller = false
    @State private var installing = false
    @State private var installProgress = EnvironmentInstallProgress(.download)
    @State private var installLines: [String] = []
    @State private var installError: String?
    @State private var installCancelled = false

    private var layout: WorkspaceLayout { WorkspaceLayout(normalized(settings.workingDirectory)) }
    private var hasWorkDirectory: Bool { (try? WorkspaceLayout.validate(normalized(settings.workingDirectory))) != nil }
    private var reconnectingWorkspace: Bool {
        hasWorkDirectory && layout.root != WorkspaceLayout(store.settings.workingDirectory).root
            && FileManager.default.fileExists(atPath: layout.state.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: 8) {
                languageCard
                workspaceCard
                pythonCard
            }.padding(.horizontal, 24).padding(.bottom, 12)
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 10) {
                Spacer()
                Button(L10n.text("Close")) { store.closeGeneralSettings() }.keyboardShortcut(.cancelAction)
                    .disabled(store.isPreparingWorkspace)
                Button(L10n.text("Save")) { save() }
                    .buttonStyle(SettingsActionStyle(prominent: true))
                    .keyboardShortcut(.defaultAction).disabled(store.busy || (!settings.hasGeneralPaths && !reconnectingWorkspace))
            }.padding(.horizontal, 24).frame(height: 60)
        }.frame(width: 640).background(Palette.canvas).foregroundStyle(Palette.ink)
            .buttonStyle(SettingsActionStyle())
            // Present neutrally. AppKit otherwise focuses and selects the first
            // path automatically; subsequent clicks and Tab retain native focus.
            .defaultFocus($headerFocused, true, priority: .userInitiated)
            .onAppear { updateGuide() }
            .onChange(of: settings) { _, _ in saveError = nil }
            .onChange(of: settings.workingDirectory) { _, directory in
                let path = normalized(directory)
                guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: WorkspaceLayout(path).state.path) else { return }
                do {
                    if let restored = try store.existingWorkspaceSettings(at: path) {
                        settings = restored
                        updateGuide()
                    }
                } catch { saveError = error.localizedDescription }
            }
            .alert(L10n.text("Settings operation failed"), isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button(L10n.text("Close"), role: .cancel) { saveError = nil }
            } message: {
                Text(L10n.render(saveError ?? ""))
            }
            // Resource transfers belong to this page. The post-save dependency
            // check belongs to the workspace and must survive its dismissal.
            .onDisappear {
                if installing || searching { store.setupTask?.cancel() }
            }
            .sheet(isPresented: $showEnvironments, onDismiss: { if searching { store.setupTask?.cancel() } }) {
                environmentPicker
            }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandMark(size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.needsGeneralSetup ? L10n.text("Welcome to LightX2V") : L10n.text("General settings"))
                    .font(.system(size: 18, weight: .semibold))
                Text(L10n.text("3 settings · Change the language anytime")).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Text(L10n.text("Configured %@ / 3", [String(describing: setupProgress.completed.count + 1)]))
                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Palette.muted)
                .accessibilityLabel(L10n.text("General settings: %@ of 3 settings configured", [String(describing: setupProgress.completed.count + 1)]))
        }.padding(.horizontal, 24).frame(height: 64)
            .focusable().focusEffectDisabled().focused($headerFocused)
    }

    private var languageCard: some View {
        HStack(spacing: 8) {
            SettingsStepBadge(number: 1)
            SettingsCardTitle(title: L10n.text("Language"))
            Spacer()
            Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(Palette.muted)
            Picker(L10n.text("Language"), selection: $language.selection) {
                ForEach(LanguagePreferences.options, id: \.code) { option in
                    Text(option.name).tag(option.code)
                }
            }.labelsHidden().pickerStyle(.menu).frame(width: 180)
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityLabel(L10n.text("Language"))
        }.padding(.horizontal, 12).frame(height: 48)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
    }

    private var workspaceCard: some View {
        SettingsSection(step: .workspace, current: setupProgress.current, title: L10n.text("LightX2V workspace"),
                        status: pathStatus(.workspace), details: workspaceMessage, hasActions: false) {
            pathRow(L10n.text("LightX2V workspace"), value: $settings.workingDirectory, directory: true, create: true)
        } actions: {
            EmptyView()
        }
    }

    private var workspaceMessage: String {
        if !store.generations.isEmpty && normalized(settings.workingDirectory) != store.settings.workingDirectory,
           !FileManager.default.fileExists(atPath: layout.state.path) {
            return L10n.text("Switching starts an empty history. Existing records and images stay in the previous workspace.")
        }
        return L10n.text("Settings, history, images, logs and caches are stored here.")
    }

    private var pythonCard: some View {
        SettingsSection(step: .python, current: setupProgress.current, title: L10n.text("PyTorch environment"),
                        status: pythonStatus, statusColor: pythonCheckFailed ? Palette.accent : pythonMatchesSaved && store.environmentReady ? Palette.green : Palette.muted,
                        statusDetails: pythonCheckFailed ? store.environmentMessage : nil,
                        statusAdvice: L10n.text("Search local environments first. Based on the results, choose manual installation or automatic installation."),
                        details: L10n.text("Search local environments first. If none qualify, follow the manual instructions or install automatically.")) {
            pathRow(L10n.text("PyTorch environment"), value: $settings.python, directory: false)
        } actions: {
            Button { startSearch() } label: { Label(L10n.text("Search local environments"), systemImage: "magnifyingglass").fixedSize() }
                .disabled(store.busy || !hasWorkDirectory)
            SettingsStatusLine(message: pythonMatchesSaved && store.isChecking ? L10n.text("Checking") : "",
                               running: pythonMatchesSaved && store.isChecking,
                               color: pythonMatchesSaved && store.environmentReady ? Palette.green : Palette.muted)
        }
    }

    private var pythonMatchesSaved: Bool {
        !store.needsGeneralSetup && normalized(settings.python) == store.settings.python
            && normalized(settings.workingDirectory) == store.settings.workingDirectory
    }

    private var pythonCheckFailed: Bool {
        pythonMatchesSaved && !store.isChecking && !store.environmentReady
            && store.environmentMessage != "Environment has not been checked"
    }

    private var pythonStatus: String {
        if pythonCheckFailed { return L10n.text("Check failed · View reason") }
        guard setupProgress.completed.contains(.python) else { return pathStatus(.python) }
        guard pythonMatchesSaved else { return L10n.text("Check on save") }
        if store.isChecking { return L10n.text("Checking") }
        if store.environmentReady { return L10n.text("Check passed") }
        return store.environmentMessage == "Environment has not been checked" ? L10n.text("Check on save") : L10n.text("Check failed")
    }

    private func pathStatus(_ step: GeneralSetupStep) -> String {
        if setupProgress.completed.contains(step) { return L10n.text("Configured") }
        let value: String
        switch step {
        case .workspace: value = settings.workingDirectory
        case .source: value = settings.repository
        case .python: value = settings.python
        case .llama: value = settings.promptEnhancement.runtimeDirectory
        }
        return normalized(value).isEmpty ? L10n.text("Not configured") : L10n.text("Invalid path")
    }

    private func pathRow(_ title: String, value: Binding<String>, directory: Bool, create: Bool = false,
                         placeholder: String? = nil) -> some View {
        HStack(spacing: 0) {
            PathInputField(title: title,
                           placeholder: placeholder ?? (directory ? L10n.text("Choose a directory or paste its full path") : L10n.text("Choose bin/python or search local environments")),
                           symbol: nil, text: value,
                           onCommit: { updateGuide() })
            chooseButton(title, value: value, directory: directory, create: create)
                .padding(.trailing, 6)
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1).allowsHitTesting(false))
        .disabled(store.busy).environment(\.layoutDirection, .leftToRight)
    }

    private func chooseButton(_ title: String, value: Binding<String>, directory: Bool, create: Bool = false) -> some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
            panel.canCreateDirectories = create; panel.allowsMultipleSelection = false
            panel.title = directory ? L10n.text("Choose %@", [String(describing: title)]) : L10n.text("Choose the Python executable in your PyTorch environment")
            panel.directoryURL = value.wrappedValue.isEmpty ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: normalized(value.wrappedValue)).deletingLastPathComponent()
            if panel.runModal() == .OK, let url = panel.url {
                value.wrappedValue = url.path
                updateGuide()
            }
        } label: {
            Image(systemName: "folder").font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.muted).frame(width: 32, height: 32)
        }
            .buttonStyle(HoverButtonStyle(radius: 6))
            .accessibilityLabel(L10n.text("Browse %@", [String(describing: title)])).help(L10n.text("Browse %@", [String(describing: title)]))
            .disabled(store.busy)
    }

    private var environmentPicker: some View {
        EnvironmentSearchView(environments: environments, searching: searching, cancelled: searchCancelled,
                              checked: checkedCount, total: totalCount, error: searchError,
                              managedInstallIssue: PyTorchEnvironmentInstaller.installationIssue(in: layout),
                              onSelect: { environment in
                                  guard environment.isCompatible else { return }
                                  settings.python = environment.executable
                                  updateGuide(); store.setupTask?.cancel(); showEnvironments = false
                              }, onSearch: startSearch, onStop: { store.setupTask?.cancel() },
                              onInstructions: { showInstallInstructions = true }, onInstall: startInstall,
                              onClose: { store.setupTask?.cancel(); showEnvironments = false })
            .sheet(isPresented: $showInstallInstructions) {
                EnvironmentInstallInstructions(onClose: { showInstallInstructions = false })
            }
            .sheet(isPresented: $showInstaller, onDismiss: { if installing { store.setupTask?.cancel() } }) {
                EnvironmentInstallView(workspace: layout, progress: installProgress, lines: installLines,
                                       installing: installing, cancelled: installCancelled, error: installError,
                                       onCancel: { store.setupTask?.cancel() }, onRetry: startInstall,
                                       onSearch: { showInstaller = false; startSearch() },
                                       onClose: { showInstaller = false })
            }
    }

    private func normalized(_ value: String) -> String {
        (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    private func updateGuide() {
        let progress = GeneralSetupProgress(settings: settings)
        guard progress != setupProgress else { return }
        setupProgress = progress
    }

    private func startSearch() {
        guard !store.busy else { return }
        saveError = nil; searchError = nil; environments = []; checkedCount = 0; totalCount = 0
        searching = true; searchCancelled = false; showEnvironments = true; store.isPreparingResources = true
        let token = UUID(); operationID = token
        let workspace = layout; let repository = normalized(settings.repository); let selected = normalized(settings.python)
        store.setupTask = Task {
            defer { searching = false; operationID = nil; store.finishSetupTask() }
            do {
                environments = try await PythonEnvironmentSearch.search(workspace: workspace, repository: repository, selected: selected) { values, checked, total in
                    Task { @MainActor in if operationID == token { environments = values; checkedCount = checked; totalCount = total } }
                }
            } catch {
                if Task.isCancelled { searchCancelled = true }
                else { searchError = error.localizedDescription }
            }
        }
    }

    private var bundledRequirements: URL? {
        Bundle.main.url(forResource: "requirements", withExtension: "txt")
            ?? Bundle.module.url(forResource: "requirements", withExtension: "txt")
    }

    private func startInstall() {
        guard !store.busy else { return }
        guard let bundledRequirements else { searchError = L10n.english("The APP dependency file is missing. Download the APP again."); return }
        showInstaller = true; installing = true; installError = nil; installCancelled = false
        installLines = []; installProgress = .init(.download); store.isPreparingResources = true
        let workspace = layout; let token = UUID(); operationID = token
        store.setupTask = Task {
            defer { installing = false; operationID = nil; store.finishSetupTask() }
            do {
                _ = try await PyTorchEnvironmentInstaller.install(workspace: workspace, requirements: bundledRequirements) { value in
                    Task { @MainActor in
                        guard operationID == token else { return }
                        if value.stage.rawValue >= installProgress.stage.rawValue {
                            if value.logLine == nil { installProgress = value }
                            else if value.stage != installProgress.stage { installProgress = .init(value.stage) }
                        }
                        if let line = value.logLine, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let clean = line.replacingOccurrences(of: #"\x1b\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
                                .replacingOccurrences(of: "\r", with: "")
                            installLines.append(clean)
                        }
                    }
                }
                installProgress = .init(.completed, detail: L10n.english("TorchLightX2V is ready. Search local environments again."))
            } catch {
                if Task.isCancelled { installCancelled = true }
                else { installError = error.localizedDescription }
            }
        }
    }

    private func save() {
        updateGuide()
        Task {
            do {
                try await store.applyGeneralSettings(settings)
            } catch { saveError = error.localizedDescription }
        }
    }
}

private struct SettingsSection<Content: View, Actions: View>: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let step: GeneralSetupStep
    let current: GeneralSetupStep?
    let title: String
    let status: String
    var statusColor: Color = Palette.muted
    var statusDetails: String?
    var statusAdvice: String?
    let details: String
    var command: String?
    var linkTitle: String?
    var linkURL: URL?
    var hasActions = true
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions
    @State private var showsDetails = false
    @State private var showsStatusDetails = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SettingsStepBadge(number: step.rawValue + 1, active: current == step)
                SettingsCardTitle(title: title)
                Button { showsDetails = true } label: { Image(systemName: "info.circle").frame(width: 20, height: 20) }
                    .buttonStyle(HoverButtonStyle(radius: 4)).foregroundStyle(Palette.muted)
                    .accessibilityLabel(L10n.text("View %@ details", [String(describing: title)]))
                    .help(L10n.text("View instructions and full status"))
                    .popover(isPresented: $showsDetails) { SettingsDetails(title: title, message: details, command: command, linkTitle: linkTitle, linkURL: linkURL) }
                Spacer(minLength: 4)
                Group {
                    if let statusDetails {
                        Button { showsStatusDetails = true } label: {
                            Text(L10n.render(status)).lineLimit(1).minimumScaleFactor(0.8).padding(.horizontal, 5).padding(.vertical, 4)
                        }.buttonStyle(HoverButtonStyle(radius: 5))
                            .accessibilityLabel(L10n.render(status))
                            .popover(isPresented: $showsStatusDetails) {
                                SettingsDetails(title: L10n.text("Check failed"), message: statusDetails, advice: statusAdvice)
                            }
                    } else { Text(L10n.render(status)).lineLimit(1).minimumScaleFactor(0.8) }
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(statusColor)
                    .frame(width: step == .python ? 208 : 112, alignment: .trailing)
            }.frame(height: 24)
            content.padding(.top, 4).frame(height: 48)
            if hasActions {
                HStack(spacing: 8) { actions }.padding(.top, 4).frame(height: 30)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(current == step ? Palette.surfaceSubtle.opacity(0.65) : Palette.canvas,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(current == step ? Palette.borderStrong : Palette.line.opacity(0.7), lineWidth: 1))
    }
}

private struct SettingsStatusLine: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let message: String
    var running = false
    var color: Color = Palette.muted
    var cancel: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            Group {
                if running { ProgressView().controlSize(.mini) }
                else { Color.clear.accessibilityHidden(true) }
            }.frame(width: 14, height: 14)
            Text(L10n.render(message)).lineLimit(1).truncationMode(.middle).help(L10n.render(message))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.text("Cancel download")) { cancel?() }
                .buttonStyle(HoverButtonStyle(radius: 4)).frame(width: 60)
                .opacity(running && cancel != nil ? 1 : 0)
                .disabled(!running || cancel == nil).accessibilityHidden(!running || cancel == nil)
        }
        .font(.system(size: 10)).foregroundStyle(color).frame(height: 18)
    }
}

private struct SettingsDetails: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let title: String
    let message: String
    var command: String?
    var linkTitle: String?
    var linkURL: URL?
    var advice: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.render(title)).font(.system(size: 13, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.render(message)).font(.system(size: 11)).textSelection(.enabled)
                    if let command {
                        Text(L10n.text("Download LightX2V manually ") + SourceDownloader.version).font(.system(size: 11, weight: .medium))
                        ScrollView(.horizontal) {
                            Text(command).environment(\.layoutDirection, .leftToRight).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true).padding(10)
                        }.frame(height: CGFloat(command.components(separatedBy: "\n").count) * 13 + 32)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 220)
            if let advice {
                Text(L10n.render(advice)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let linkTitle, let linkURL {
                Link(destination: linkURL) { Text(L10n.render(linkTitle)).underline().padding(.trailing, 6).padding(.vertical, 5) }
                    .font(.system(size: 11)).buttonStyle(HoverButtonStyle(radius: 6))
            }
        }.padding(18).frame(width: 360).foregroundStyle(Palette.ink)
    }
}

/// All setting cards share the same typography and badge geometry.
private struct SettingsCardTitle: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let title: String
    var body: some View {
        Text(L10n.render(title)).font(.system(size: 15, weight: .semibold))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
    }
}

private struct SettingsStepBadge: View {
    let number: Int
    var active = false
    var body: some View {
        Text(String(number)).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(active ? Palette.onButton : Palette.muted)
            .frame(width: 22, height: 22)
            .background(active ? Palette.ink : Palette.selection, in: Circle())
    }
}
