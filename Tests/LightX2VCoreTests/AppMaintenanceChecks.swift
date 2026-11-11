import Foundation
import LightX2VCore
import Darwin

func appMaintenanceChecks() async throws {
    let fm = FileManager.default
    guard let temporaryPath = realpath(fm.temporaryDirectory.path, nil) else {
        throw CheckFailure(message: "Unable to resolve the maintenance fixture directory")
    }
    let temporaryRoot = URL(fileURLWithPath: String(cString: temporaryPath), isDirectory: true)
    free(temporaryPath)
    let root = temporaryRoot.appendingPathComponent("maintenance-checks-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL

    func signedApplication(at app: URL, stamp: String, extraFiles: Int = 0) throws {
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: helper, to: app.appendingPathComponent("Contents/MacOS/LightX2VApp"))
        let info = ["CFBundleIdentifier": "app.lightx2v.desktop", "CFBundleExecutable": "LightX2VApp", "CFBundleName": "LightX2V", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data(stamp.utf8).write(to: app.appendingPathComponent("Contents/Resources/stamp"))
        for index in 0..<extraFiles {
            try Data("fixture".utf8).write(to: app.appendingPathComponent("Contents/Resources/file-\(index)"))
        }
        let signing = Process()
        signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signing.arguments = ["--force", "--deep", "--sign", "-", app.path]
        signing.standardOutput = FileHandle.nullDevice
        signing.standardError = FileHandle.nullDevice
        try signing.run()
        signing.waitUntilExit()
        try expect(signing.terminationStatus == 0, "maintenance fixture signing failed")
    }

    let app = URL(fileURLWithPath: root.appendingPathComponent("installed/LightX2V.app").path, isDirectory: true)
    try signedApplication(at: app, stamp: "original")
    let job = try AppMaintenance.createJobDirectory(excluding: [app])
    defer { try? fm.removeItem(at: job) }
    let incoming = job.appendingPathComponent("download/LightX2V.app")
    try signedApplication(at: incoming, stamp: "updated")
    var update = AppMaintenancePlan(updateApplicationAt: app, with: incoming, parentPID: Int32.max)
    update.jobDirectory = job
    let prepared = try AppMaintenance.prepare(plan: update, helperURL: helper)
    try expect(prepared.preparedApplicationURL?.deletingLastPathComponent().standardizedFileURL.path == app.deletingLastPathComponent().standardizedFileURL.path, "update was not staged on the application's volume")
    try expect(fm.fileExists(atPath: app.path), "preparation replaced the running application")
    try AppMaintenance.execute(prepared, relaunch: false)
    let stamp = try String(contentsOf: app.appendingPathComponent("Contents/Resources/stamp"), encoding: .utf8)
    try expect(stamp == "updated" && !fm.fileExists(atPath: job.path), "update did not replace the bundle and remove staging")
    let leftovers = try fm.contentsOfDirectory(atPath: app.deletingLastPathComponent().path)
    try expect(leftovers == ["LightX2V.app"], "successful update left backup application copies")

    let sentinel = root.appendingPathComponent("unowned-prepared-input")
    let sentinelData = Data("preserve caller files".utf8)
    try sentinelData.write(to: sentinel)
    let invalidJob = try AppMaintenance.createJobDirectory(excluding: [app])
    defer { try? fm.removeItem(at: invalidJob) }
    var invalidPlan = AppMaintenancePlan(updateApplicationAt: app, with: root.appendingPathComponent("missing.app"), parentPID: 0)
    invalidPlan.jobDirectory = invalidJob
    invalidPlan.preparedApplicationURL = sentinel
    var invalidRejected = false
    do { _ = try AppMaintenance.prepare(plan: invalidPlan, helperURL: helper) }
    catch { invalidRejected = true }
    let retainedSentinel = try Data(contentsOf: sentinel)
    try expect(invalidRejected && retainedSentinel == sentinelData, "failed preparation removed an input path it did not create")
    try expect(!fm.fileExists(atPath: invalidJob.path), "failed preparation retained its owned job")

    let cancellationJob = try AppMaintenance.createJobDirectory(excluding: [app])
    defer { try? fm.removeItem(at: cancellationJob) }
    let cancellationIncoming = cancellationJob.appendingPathComponent("download/LightX2V.app")
    try signedApplication(at: cancellationIncoming, stamp: "cancelled update", extraFiles: 4000)
    let launchMarker = root.appendingPathComponent("cancelled-helper-started")
    let markerHelper = root.appendingPathComponent("marker-helper")
    let quotedMarker = "'" + launchMarker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    try Data(("#!/bin/sh\n/usr/bin/touch " + quotedMarker + "\n").utf8).write(to: markerHelper)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: markerHelper.path)
    var cancellationPlan = AppMaintenancePlan(updateApplicationAt: app, with: cancellationIncoming, parentPID: Int32.max)
    cancellationPlan.jobDirectory = cancellationJob
    let heartbeat = await MainActor.run { MaintenanceHeartbeat() }
    let ticker = Task { @MainActor in
        while !Task.isCancelled {
            heartbeat.pulses += 1
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    defer { ticker.cancel() }
    let launch = Task { @MainActor [cancellationPlan] in
        try await AppMaintenance.launch(plan: cancellationPlan, helperURL: markerHelper)
    }
    var copying = false
    for _ in 0..<5000 {
        let contents = try fm.contentsOfDirectory(atPath: app.deletingLastPathComponent().path)
        if contents.contains(where: { $0.hasPrefix(".LightX2V-update-") }) { copying = true; break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    let pulsesBeforeCancellation = await MainActor.run { heartbeat.pulses }
    launch.cancel()
    var cancelled = false
    do { _ = try await launch.value } catch is CancellationError { cancelled = true }
    ticker.cancel()
    try expect(copying && pulsesBeforeCancellation > 1, "maintenance preparation blocked the main actor heartbeat")
    try expect(cancelled && !fm.fileExists(atPath: cancellationJob.path), "cancelled maintenance did not finish cleaning its job")
    try expect(!fm.fileExists(atPath: launchMarker.path), "cancelled preparation started the maintenance helper")
    let afterCancellation = try fm.contentsOfDirectory(atPath: app.deletingLastPathComponent().path)
    try expect(afterCancellation == ["LightX2V.app"], "cancelled preparation left a partial update application")
    let cancellationStamp = try String(contentsOf: app.appendingPathComponent("Contents/Resources/stamp"), encoding: .utf8)
    try expect(cancellationStamp == "updated", "cancelled preparation changed the installed application")

    let rollbackJob = try AppMaintenance.createJobDirectory(excluding: [app])
    defer { try? fm.removeItem(at: rollbackJob) }
    let rollbackIncoming = rollbackJob.appendingPathComponent("download/LightX2V.app")
    try signedApplication(at: rollbackIncoming, stamp: "replacement")
    let parent = Process()
    parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
    parent.arguments = ["1.5"]
    try parent.run()
    DispatchQueue.global().async { parent.waitUntilExit() }
    var pending = AppMaintenancePlan(updateApplicationAt: app, with: rollbackIncoming, parentPID: parent.processIdentifier)
    pending.jobDirectory = rollbackJob
    let rollback = try AppMaintenance.prepare(plan: pending, helperURL: helper)
    let disappearing = rollback.preparedApplicationURL!
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { try? FileManager.default.removeItem(at: disappearing) }
    var rolledBack = false
    do { try AppMaintenance.execute(rollback, relaunch: false) } catch { rolledBack = true }
    let retained = try String(contentsOf: app.appendingPathComponent("Contents/Resources/stamp"), encoding: .utf8)
    try expect(rolledBack && retained == "updated", "failed replacement did not restore the previous application")
    let failure = AppMaintenance.failureMessage(arguments: ["fixture", "--maintenance-error", rollbackJob.appendingPathComponent("result.json").path])
    try expect(failure != nil && !fm.fileExists(atPath: rollbackJob.path), "maintenance failure was not reported and acknowledged")

    let changedJob = try AppMaintenance.createJobDirectory(excluding: [app])
    defer { try? fm.removeItem(at: changedJob) }
    let changedIncoming = changedJob.appendingPathComponent("download/LightX2V.app")
    try signedApplication(at: changedIncoming, stamp: "pending replacement")
    let otherParent = Process()
    otherParent.executableURL = URL(fileURLWithPath: "/bin/sleep")
    otherParent.arguments = ["1.5"]
    try otherParent.run()
    DispatchQueue.global().async { otherParent.waitUntilExit() }
    var changingPlan = AppMaintenancePlan(updateApplicationAt: app, with: changedIncoming, parentPID: otherParent.processIdentifier)
    changingPlan.jobDirectory = changedJob
    let changing = try AppMaintenance.prepare(plan: changingPlan, helperURL: helper)
    let installedExecutable = app.appendingPathComponent("Contents/MacOS/LightX2VApp")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
        if let stream = try? FileHandle(forWritingTo: installedExecutable) {
            _ = try? stream.seekToEnd()
            try? stream.write(contentsOf: Data("changed while pending".utf8))
            try? stream.close()
        }
    }
    var changedRejected = false
    do { try AppMaintenance.execute(changing, relaunch: false) } catch { changedRejected = true }
    let changedStamp = try String(contentsOf: app.appendingPathComponent("Contents/Resources/stamp"), encoding: .utf8)
    try expect(changedRejected && changedStamp == "updated", "maintenance overwrote an application changed while waiting for exit")
    try fm.removeItem(at: app)
    try signedApplication(at: app, stamp: "updated")

    let workspace = root.appendingPathComponent("workspace")
    let source = workspace.appendingPathComponent("code")
    let model = source.appendingPathComponent("preserved-model")
    let cache = workspace.appendingPathComponent("cache")
    try fm.createDirectory(at: model, withIntermediateDirectories: true)
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data("model".utf8).write(to: model.appendingPathComponent("weights"))
    try Data("source".utf8).write(to: source.appendingPathComponent("remove-source"))
    let broken = workspace.appendingPathComponent("tmp")
    try fm.createSymbolicLink(atPath: broken.path, withDestinationPath: root.appendingPathComponent("missing-target").path)
    var settings = AppSettings.defaults
    settings.workingDirectory = workspace.path
    settings.model = model.path
    let uninstall = try AppUninstaller.discover(settings: settings, appURL: app,
                                               supportRoot: root.appendingPathComponent("support"),
                                               homeDirectory: root.appendingPathComponent("home"), preferenceDomains: [])
    let selected = Set(uninstall.items.filter { $0.category != .models }.map(\.id))
    let exiting = Process()
    exiting.executableURL = URL(fileURLWithPath: "/bin/sleep")
    exiting.arguments = ["1.5"]
    try exiting.run()
    DispatchQueue.global().async { exiting.waitUntilExit() }
    var removalPlan = AppMaintenancePlan(uninstall: uninstall, selectedIDs: selected, parentPID: exiting.processIdentifier)
    removalPlan.applicationURL = app // Exercise a directory-hinted URL against the planner's canonical file URLs.
    let removal = try AppMaintenance.prepare(plan: removalPlan, helperURL: helper)
    let shutdownFile = source.appendingPathComponent("shutdown-state")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { try? Data("late state".utf8).write(to: shutdownFile) }
    try AppMaintenance.execute(removal, relaunch: false)
    try expect(!fm.fileExists(atPath: app.path) && !fm.fileExists(atPath: cache.path) && !fm.fileExists(atPath: source.appendingPathComponent("remove-source").path), "selected uninstall items survived")
    let modelBytes = try Data(contentsOf: model.appendingPathComponent("weights"))
    try expect(modelBytes == Data("model".utf8), "uninstall removed a retained nested model")
    try expect(!fm.fileExists(atPath: shutdownFile.path), "uninstall omitted a selected source file written during shutdown")
    try expect((try? fm.destinationOfSymbolicLink(atPath: broken.path)) == nil, "uninstall retained a broken selected symlink")
    try expect(!fm.fileExists(atPath: removal.jobDirectory!.path), "successful uninstall left its helper job")
    print("PASS native maintenance staging, bundle replacement, rollback, failure reporting, selected uninstall and nested preservation")
}

@MainActor
private final class MaintenanceHeartbeat {
    var pulses = 0
}
