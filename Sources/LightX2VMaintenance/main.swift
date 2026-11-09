import Foundation
import LightX2VCore

do {
    guard CommandLine.arguments.count == 2 else { throw AppError.message("A maintenance plan is required.") }
    let planURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let plan = try JSONDecoder().decode(AppMaintenancePlan.self, from: Data(contentsOf: planURL))
    guard plan.jobDirectory?.standardizedFileURL.resolvingSymlinksInPath().path == planURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path else {
        throw AppError.message("The maintenance plan is outside its job directory.")
    }
    try AppMaintenance.execute(plan)
} catch {
    FileHandle.standardError.write(Data(("LightX2V maintenance failed: " + error.localizedDescription + "\n").utf8))
    exit(1)
}
