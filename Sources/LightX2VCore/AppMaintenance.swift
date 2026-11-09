import Foundation
import CryptoKit
import Darwin

public enum AppMaintenanceOperation: String, Codable {
    case update, uninstall
}

public struct AppMaintenancePlan: Codable {
    public var operation: AppMaintenanceOperation
    public var parentPID: Int32
    public var applicationURL: URL
    public var stagedApplicationURL: URL?
    public var uninstallPlan: AppUninstallPlan?
    public var selectedIDs: Set<String>
    public var jobDirectory: URL?
    public var preparedApplicationURL: URL?
    public var originalApplicationDigest: String?

    public init(updateApplicationAt applicationURL: URL, with stagedApplicationURL: URL, parentPID: Int32 = getpid()) {
        operation = .update
        self.parentPID = parentPID
        self.applicationURL = applicationURL
        self.stagedApplicationURL = stagedApplicationURL
        selectedIDs = []
    }

    public init(uninstall plan: AppUninstallPlan, selectedIDs: Set<String>, parentPID: Int32 = getpid()) {
        operation = .uninstall
        self.parentPID = parentPID
        applicationURL = plan.applicationURL
        uninstallPlan = plan
        self.selectedIDs = selectedIDs
    }
}

public struct AppMaintenanceResult: Codable {
    public let success: Bool
    public let message: String
}

/// A copied native helper completes filesystem changes after the parent exits.
public enum AppMaintenance {
    public static let helperName = "LightX2VMaintenance"
    private static let jobMarker = ".lightx2v-maintenance-job"
    private static let bundleIdentifier = "app.lightx2v.desktop"

    public static func createJobDirectory(excluding paths: [URL] = []) throws -> URL {
        let fm = FileManager.default
        var base = fm.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        if paths.contains(where: { contains($0, base) }) { base = URL(fileURLWithPath: "/private/tmp") }
        let directory = base.appendingPathComponent("lightx2v-maintenance-" + UUID().uuidString)
        guard !paths.contains(where: { contains($0, directory) }) else {
            throw AppError.message("Unable to create a maintenance directory outside the selected files.")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(UUID().uuidString.utf8).write(to: directory.appendingPathComponent(jobMarker), options: .atomic)
        return directory
    }

    public static func prepare(plan original: AppMaintenancePlan, helperURL: URL? = nil) throws -> AppMaintenancePlan {
        var plan = original
        try preflight(plan)
        let exclusions = (try deletionSelection(plan)?.deletionURLs ?? []) + (plan.uninstallPlan?.workspaceRoots ?? [])
        let job = try plan.jobDirectory ?? createJobDirectory(excluding: exclusions + [plan.applicationURL])
        try validateJob(job, excluding: exclusions + [plan.applicationURL])
        plan.jobDirectory = job
        let fm = FileManager.default
        var completed = false
        defer {
            if !completed {
                if let prepared = plan.preparedApplicationURL { try? fm.removeItem(at: prepared) }
                try? fm.removeItem(at: job)
            }
        }
        let helper = helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + helperName)
        guard fm.isExecutableFile(atPath: helper.path) else { throw AppError.message("The maintenance helper is missing. Download LightX2V again.") }
        let copiedHelper = job.appendingPathComponent(helperName)
        try fm.copyItem(at: helper, to: copiedHelper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: copiedHelper.path)
        plan.originalApplicationDigest = try applicationDigest(plan.applicationURL)
        if plan.operation == .update {
            guard let staged = plan.stagedApplicationURL else { throw AppError.message("The downloaded application is missing.") }
            let prepared = plan.applicationURL.deletingLastPathComponent()
                .appendingPathComponent(".LightX2V-update-" + UUID().uuidString + ".app")
            plan.preparedApplicationURL = prepared
            try fm.copyItem(at: staged, to: prepared)
            try validateApplication(prepared, signature: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: job.appendingPathComponent("plan.json"), options: .atomic)
        completed = true
        return plan
    }

    @discardableResult
    public static func launch(plan: AppMaintenancePlan, helperURL: URL? = nil) throws -> URL {
        let prepared = try prepare(plan: plan, helperURL: helperURL)
        let job = prepared.jobDirectory!
        do {
            let process = Process()
            process.executableURL = job.appendingPathComponent(helperName)
            process.arguments = [job.appendingPathComponent("plan.json").path]
            process.currentDirectoryURL = job
            let log = job.appendingPathComponent("helper.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            try process.run()
            return job
        } catch {
            if let app = prepared.preparedApplicationURL { try? FileManager.default.removeItem(at: app) }
            try? FileManager.default.removeItem(at: job)
            throw error
        }
    }

    public static func execute(_ plan: AppMaintenancePlan, relaunch: Bool = true) throws {
        guard let job = plan.jobDirectory else { throw AppError.message("Maintenance job directory is missing.") }
        do {
            let selection = try deletionSelection(plan)
            try validateJob(job, excluding: (selection?.deletionURLs ?? []) + (plan.uninstallPlan?.workspaceRoots ?? []) + [plan.applicationURL])
            try preflight(plan)
            try waitForParent(plan.parentPID)
            var coordinationError: NSError?
            var result: Result<Void, Error> = .failure(AppError.message("Unable to coordinate application maintenance."))
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: plan.applicationURL, options: .forReplacing, error: &coordinationError) { application in
                result = Result {
                    guard samePath(application, plan.applicationURL) else {
                        throw AppError.message("The application moved while maintenance was pending. Try again.")
                    }
                    try preflight(plan)
                    if plan.operation == .update {
                        try installUpdate(plan, relaunch: relaunch)
                    } else if let currentSelection = try deletionSelection(plan) {
                        try uninstall(currentSelection, application: plan.applicationURL)
                        if relaunch && FileManager.default.fileExists(atPath: plan.applicationURL.path) {
                            try openApplication(plan.applicationURL)
                        }
                    }
                }
            }
            if let coordinationError { throw coordinationError }
            try result.get()
            try? FileManager.default.removeItem(at: job)
        } catch {
            let result = AppMaintenanceResult(success: false, message: error.localizedDescription)
            if let data = try? JSONEncoder().encode(result) {
                try? data.write(to: job.appendingPathComponent("result.json"), options: .atomic)
            }
            if let prepared = plan.preparedApplicationURL { try? FileManager.default.removeItem(at: prepared) }
            if relaunch && FileManager.default.fileExists(atPath: plan.applicationURL.path) {
                try? openApplication(plan.applicationURL, arguments: ["--maintenance-error", job.appendingPathComponent("result.json").path])
            }
            throw error
        }
    }

    public static func preflight(_ plan: AppMaintenancePlan) throws {
        guard plan.parentPID > 1 else { throw AppError.message("Invalid maintenance parent process.") }
        try validateApplication(plan.applicationURL, signature: false)
        if let expected = plan.originalApplicationDigest {
            guard try applicationDigest(plan.applicationURL) == expected else {
                throw AppError.message("The installed application changed while maintenance was pending. Try again.")
            }
        }
        let fm = FileManager.default
        switch plan.operation {
        case .update:
            guard fm.isWritableFile(atPath: plan.applicationURL.deletingLastPathComponent().path) else {
                throw AppError.message("The application folder is not writable. Move LightX2V to a writable Applications folder and try again.")
            }
            guard let staged = plan.preparedApplicationURL ?? plan.stagedApplicationURL else { throw AppError.message("The downloaded application is missing.") }
            guard !samePath(staged, plan.applicationURL) else { throw AppError.message("The update must be staged separately from the installed application.") }
            try validateApplication(staged, signature: true)
            if let prepared = plan.preparedApplicationURL {
                guard samePath(prepared.deletingLastPathComponent(), plan.applicationURL.deletingLastPathComponent()),
                      prepared.lastPathComponent.hasPrefix(".LightX2V-update-") else {
                    throw AppError.message("The prepared update is outside its installation folder.")
                }
            }
        case .uninstall:
            guard let selection = try deletionSelection(plan), !selection.deletionURLs.isEmpty || !selection.preferenceDomains.isEmpty else {
                throw AppError.message("Choose at least one item to uninstall.")
            }
            try AppUninstaller.validateDeletionTargets(selection)
            for path in selection.deletionURLs where exists(path) {
                guard samePath(path, plan.applicationURL) || !contains(path, plan.applicationURL) else {
                    throw AppError.message("A selected data folder contains the running application. Move LightX2V outside that folder before uninstalling.")
                }
                guard fm.isDeletableFile(atPath: path.path) else { throw AppError.message("Unable to remove the selected path: " + path.path) }
            }
        }
    }

    public static func failureMessage(arguments: [String] = CommandLine.arguments) -> String? {
        guard let index = arguments.firstIndex(of: "--maintenance-error"), arguments.count > index + 1 else { return nil }
        let resultURL = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        let job = resultURL.deletingLastPathComponent()
        guard resultURL.lastPathComponent == "result.json", (try? validateJob(job, excluding: [])) != nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: resultURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) < 65536,
              let data = try? Data(contentsOf: resultURL),
              let result = try? JSONDecoder().decode(AppMaintenanceResult.self, from: data), !result.success else { return nil }
        try? FileManager.default.removeItem(at: job)
        return result.message
    }

    private static func deletionSelection(_ plan: AppMaintenancePlan) throws -> AppUninstallSelection? {
        guard plan.operation == .uninstall else { return nil }
        guard let uninstall = plan.uninstallPlan, samePath(uninstall.applicationURL, plan.applicationURL) else { throw AppError.message("Uninstall plan application does not match.") }
        return try AppUninstaller.selection(from: uninstall, selectedIDs: plan.selectedIDs)
    }

    private static func validateJob(_ job: URL, excluding paths: [URL]) throws {
        let fm = FileManager.default
        let values = try job.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              job.lastPathComponent.hasPrefix("lightx2v-maintenance-"),
              fm.fileExists(atPath: job.appendingPathComponent(jobMarker).path),
              !paths.contains(where: { contains($0, job) || contains(job, $0) }) else {
            throw AppError.message("Invalid maintenance staging directory.")
        }
    }

    private static func validateApplication(_ app: URL, signature: Bool) throws {
        let fm = FileManager.default
        let values = try app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard app.isFileURL, app.pathExtension == "app", values.isDirectory == true, values.isSymbolicLink != true,
              !app.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix("/System/") else {
            throw AppError.message("Choose a valid LightX2V application bundle.")
        }
        let metadata = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard metadata?["CFBundleIdentifier"] as? String == bundleIdentifier,
              let executable = metadata?["CFBundleExecutable"] as? String,
              executable == URL(fileURLWithPath: executable).lastPathComponent,
              fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/" + executable).path) else {
            throw AppError.message("The application is not a complete LightX2V bundle.")
        }
        if signature {
            try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            let architectures = try command("/usr/bin/lipo", ["-archs", app.appendingPathComponent("Contents/MacOS/" + executable).path])
            guard architectures.split(separator: " ").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" }) else {
                throw AppError.message("The application does not support Apple Silicon.")
            }
        }
    }

    private static func applicationDigest(_ app: URL) throws -> String {
        let metadata = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard let executable = metadata?["CFBundleExecutable"] as? String,
              executable == URL(fileURLWithPath: executable).lastPathComponent else { throw AppError.message("Invalid application executable.") }
        return SHA256.hash(data: try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/" + executable))).map { String(format: "%02x", $0) }.joined()
    }

    private static func installUpdate(_ plan: AppMaintenancePlan, relaunch: Bool) throws {
        let fm = FileManager.default
        guard let prepared = plan.preparedApplicationURL else { throw AppError.message("The update has not been prepared.") }
        let backup = plan.applicationURL.deletingLastPathComponent().appendingPathComponent(".LightX2V-backup-" + UUID().uuidString + ".app")
        do {
            _ = try fm.replaceItemAt(plan.applicationURL, withItemAt: prepared, backupItemName: backup.lastPathComponent,
                                     options: [.usingNewMetadataOnly, .withoutDeletingBackupItem])
            try validateApplication(plan.applicationURL, signature: true)
            if relaunch { try openApplication(plan.applicationURL) }
        } catch let updateError {
            if exists(backup) {
                do {
                    if exists(plan.applicationURL) {
                        _ = try fm.replaceItemAt(plan.applicationURL, withItemAt: backup, options: .usingNewMetadataOnly)
                    } else {
                        try fm.moveItem(at: backup, to: plan.applicationURL)
                    }
                } catch {
                    throw AppError.message("The update failed and the previous application remains at " + backup.path + ". " + error.localizedDescription)
                }
            }
            throw updateError
        }
        try fm.removeItem(at: backup)
    }

    private static func uninstall(_ selection: AppUninstallSelection, application: URL) throws {
        let fm = FileManager.default
        let paths = selection.deletionURLs.filter { !samePath($0, application) && exists($0) }
        var moved: [(original: URL, staged: URL)] = []
        do {
            for path in paths {
                let staged = path.deletingLastPathComponent().appendingPathComponent(".lightx2v-uninstall-" + UUID().uuidString)
                try fm.moveItem(at: path, to: staged)
                moved.append((path, staged))
            }
        } catch {
            let retained = restore(moved)
            throw AppError.message(error.localizedDescription + retained)
        }
        for (index, pair) in moved.enumerated() {
            do { try fm.removeItem(at: pair.staged) }
            catch {
                let retained = restore(Array(moved[index...]))
                throw AppError.message("Unable to finish removing " + pair.original.path + ". " + error.localizedDescription + retained)
            }
        }
        for domain in selection.preferenceDomains { UserDefaults.standard.removePersistentDomain(forName: domain) }
        UserDefaults.standard.synchronize()
        if selection.deletionURLs.contains(where: { samePath($0, application) }) { try fm.removeItem(at: application) }
        for directory in selection.emptyParentURLs.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            if let contents = try? fm.contentsOfDirectory(atPath: directory.path), contents.isEmpty { try fm.removeItem(at: directory) }
        }
    }

    private static func restore(_ moved: [(original: URL, staged: URL)]) -> String {
        var retained: [String] = []
        for pair in moved.reversed() where exists(pair.staged) {
            do { try FileManager.default.moveItem(at: pair.staged, to: pair.original) }
            catch { retained.append(pair.staged.path) }
        }
        return retained.isEmpty ? "" : " Recoverable files remain at " + retained.joined(separator: ", ") + "."
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func waitForParent(_ pid: Int32) throws {
        let deadline = Date().addingTimeInterval(60)
        while kill(pid, 0) == 0 || errno == EPERM {
            guard Date() < deadline else { throw AppError.message("LightX2V is still running. Close it and try again.") }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        let base = AppUninstaller.normalized(parent).path
        let candidate = AppUninstaller.normalized(child).path
        return candidate == base || candidate.hasPrefix(base + "/")
    }

    private static func samePath(_ first: URL, _ second: URL) -> Bool {
        AppUninstaller.normalized(first).path == AppUninstaller.normalized(second).path
    }

    @discardableResult
    private static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw AppError.message("Application verification failed. " + output) }
        return output
    }

    private static func openApplication(_ app: URL, arguments: [String] = []) throws {
        var values = ["-n", "-a", app.path]
        if !arguments.isEmpty { values += ["--args"] + arguments }
        try command("/usr/bin/open", values)
    }
}
