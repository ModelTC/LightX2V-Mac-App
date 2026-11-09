import AppKit
import SwiftUI
import LightX2VCore

enum AppMaintenanceSection: Hashable, Identifiable {
    case updates, uninstall
    var id: Self { self }
}

struct AppMaintenanceView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var section: AppMaintenanceSection
    @State private var release: StableAppRelease?
    @State private var uninstallPlan: AppUninstallPlan?
    @State private var selectedItems: Set<String> = []
    @State private var message = ""
    @State private var failure: String?
    @State private var working = false
    @State private var confirmUninstall = false
    private let applicationURL: URL

    init(initialSection: AppMaintenanceSection, applicationURL: URL = Bundle.main.bundleURL) {
        _section = State(initialValue: initialSection)
        self.applicationURL = applicationURL
    }

    private var buildInfo: [String: Any] { Bundle(url: applicationURL)?.infoDictionary ?? [:] }
    private var currentCommit: String? { buildInfo["LightX2VCommit"] as? String }
    private var currentCommitDate: Date? {
        (buildInfo["LightX2VCommitDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }
    private var updateAvailable: Bool { release?.isNewer(than: currentCommit, commitDate: currentCommitDate) == true }
    private var removesApplication: Bool {
        uninstallPlan?.items.contains { $0.category == .application && selectedItems.contains($0.id) } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                BrandMark(size: 28)
                Text(L10n.text("Application management")).font(.system(size: 18, weight: .semibold))
                Spacer()
            }
            Picker(L10n.text("Application management"), selection: $section) {
                Text(L10n.text("Updates")).tag(AppMaintenanceSection.updates)
                Text(L10n.text("Uninstall")).tag(AppMaintenanceSection.uninstall)
            }.pickerStyle(.segmented).disabled(working)
            if section == .updates { updateContent }
            else { uninstallContent }
            Spacer(minLength: 0)
            if !message.isEmpty {
                HStack(spacing: 8) {
                    if working { ProgressView().controlSize(.small) }
                    Text(L10n.render(message)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            if let failure {
                Text(L10n.render(failure)).font(.system(size: 12)).foregroundStyle(Palette.accent)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if working { Button(L10n.text("Cancel")) { store.setupTask?.cancel() } }
                Spacer()
                Button(L10n.text("Close")) { dismiss() }.disabled(working).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 720, height: 610)
        .background(Palette.canvas).foregroundStyle(Palette.ink)
        .buttonStyle(SettingsActionStyle())
        .onAppear { if section == .uninstall { loadUninstallPlan() } }
        .onChange(of: section) { _, value in
            failure = nil; message = ""
            if value == .uninstall { loadUninstallPlan() }
        }
        .onDisappear { if working { store.setupTask?.cancel() } }
        .alert(L10n.text(removesApplication ? "Uninstall LightX2V?" : "Remove selected files?"), isPresented: $confirmUninstall) {
            Button(L10n.text("Cancel"), role: .cancel) {}
            Button(L10n.text(removesApplication ? "Uninstall and quit" : "Delete and restart"), role: .destructive) { uninstallSelectedItems() }
        } message: {
            Text(L10n.text("The selected files will be permanently deleted after LightX2V closes."))
        }
    }

    private var updateContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Stable app updates")).font(.system(size: 15, weight: .semibold))
            Text(L10n.text("Current build %@", [currentCommit.map { String($0.prefix(7)) } ?? "—"]))
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text(L10n.text("The app will close, replace its application bundle and restart."))
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack {
                Button(L10n.text("Check stable version")) { checkStableVersion() }.disabled(working || store.busy)
                if updateAvailable {
                    Button(L10n.text("Download and install")) { installStableVersion() }
                        .buttonStyle(SettingsActionStyle(prominent: true)).disabled(working || store.busy)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var uninstallContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Choose what to remove")).font(.system(size: 15, weight: .semibold))
            Text(L10n.text("Select the files to delete. Unchecked items will be kept."))
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack {
                Button(L10n.text("Select all")) { selectedItems = Set(uninstallPlan?.items.map(\.id) ?? []) }
                Button(L10n.text("Keep all")) { selectedItems = [] }
                Spacer()
            }.disabled(working)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let uninstallPlan {
                        ForEach(UninstallCategory.allCases, id: \.self) { category in
                            let items = uninstallPlan.items.filter { $0.category == category }
                            if !items.isEmpty {
                                Text(L10n.text(category.title)).font(.system(size: 12, weight: .semibold))
                                if category == .sources {
                                    Text(L10n.text("Programs used for image generation and prompt enhancement. These files can be downloaded again when needed."))
                                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                }
                                ForEach(items, id: \.id) { item in
                                    Toggle(isOn: Binding(get: { selectedItems.contains(item.id) }, set: { selected in
                                        select(item, selected: selected)
                                    })) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            if item.isExternal {
                                                Text(L10n.text("External folder")).font(.system(size: 10)).foregroundStyle(Palette.accent)
                                            }
                                            Text(item.path).font(.system(size: 11, design: .monospaced))
                                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }.toggleStyle(.checkbox).disabled(working)
                                }
                            }
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            Button(L10n.text("Delete selected items…"), role: .destructive) { confirmUninstall = true }
                .disabled(working || store.busy || selectedItems.isEmpty)
        }
    }

    private func loadUninstallPlan() {
        guard !store.busy else { return }
        beginOperation(L10n.english("Preparing"))
        store.setupTask = Task {
            defer { finishOperation() }
            do {
                let plan = try await store.makeUninstallPlan(applicationURL: applicationURL)
                try Task.checkCancellation()
                uninstallPlan = plan
                selectedItems = Set(plan.items.filter(\.defaultSelected).map(\.id))
                message = ""
            } catch {
                message = ""
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }

    private func select(_ item: UninstallItem, selected: Bool) {
        guard let uninstallPlan else { return }
        let children = uninstallPlan.items.filter { $0.path == item.path || $0.path.hasPrefix(item.path + "/") }
        if selected {
            selectedItems.formUnion(children.map(\.id))
        } else {
            selectedItems.subtract(children.map(\.id))
        }
    }

    private func beginOperation(_ status: String) {
        failure = nil; message = status; working = true
        store.isPreparingResources = true
    }

    private func finishOperation() {
        working = false
        store.finishSetupTask()
    }

    private func checkStableVersion() {
        guard !store.busy else { return }
        beginOperation(L10n.english("Checking the stable release…"))
        store.setupTask = Task {
            defer { finishOperation() }
            do {
                let value = try await AppUpdater.fetchStableRelease()
                try Task.checkCancellation()
                release = value
                if currentCommit == nil || currentCommitDate == nil {
                    message = L10n.english("Build information is unavailable. Use a packaged LightX2V app.")
                } else if value.isNewer(than: currentCommit, commitDate: currentCommitDate) {
                    message = L10n.english("Stable version %@ is available.", [String(value.commit.prefix(7))])
                } else if value.commit == currentCommit {
                    message = L10n.english("LightX2V is up to date.")
                } else {
                    message = L10n.english("The installed build is newer than the current stable release.")
                }
            } catch {
                message = ""
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }

    private func installStableVersion() {
        guard !store.busy, let release, updateAvailable else { return }
        beginOperation(L10n.english("Preparing the stable update…"))
        store.setupTask = Task {
            var directory: URL?
            var helperStarted = false
            defer {
                if !helperStarted, let directory { try? FileManager.default.removeItem(at: directory) }
                finishOperation()
            }
            do {
                var excluded = [applicationURL]
                if !store.settings.workingDirectory.isEmpty { excluded.append(WorkspaceLayout(store.settings.workingDirectory).root) }
                let job = try AppMaintenance.createJobDirectory(excluding: excluded)
                directory = job
                let app = try await AppUpdater.stage(release, in: job) { status in
                    Task { @MainActor in if working { message = status } }
                }
                try Task.checkCancellation()
                var plan = AppMaintenancePlan(updateApplicationAt: applicationURL, with: app)
                plan.jobDirectory = job
                _ = try await AppMaintenance.launch(plan: plan)
                helperStarted = true
                finishOperation()
                NSApp.terminate(nil)
            } catch {
                message = ""
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }

    private func uninstallSelectedItems() {
        guard !store.busy, let uninstallPlan, !selectedItems.isEmpty else { return }
        let plan = AppMaintenancePlan(uninstall: uninstallPlan, selectedIDs: selectedItems)
        beginOperation(L10n.english("Preparing"))
        store.setupTask = Task {
            defer { finishOperation() }
            do {
                _ = try await AppMaintenance.launch(plan: plan)
                finishOperation()
                NSApp.terminate(nil)
            } catch {
                message = ""
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}
