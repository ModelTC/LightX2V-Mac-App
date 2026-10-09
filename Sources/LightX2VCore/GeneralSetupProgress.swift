import Foundation

public enum GeneralSetupStep: Int, CaseIterable {
    case workspace = 1, source, python
}

/// A snapshot of committed input. The UI refreshes this after editing finishes,
/// so a partially typed path never moves the guide away from the user.
public struct GeneralSetupProgress: Equatable {
    public let completed: Set<GeneralSetupStep>
    public var current: GeneralSetupStep? { GeneralSetupStep.allCases.first { !completed.contains($0) } }

    public init(settings: AppSettings = .defaults) {
        func normalized(_ value: String) -> String {
            (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        }
        var paths = settings
        paths.workingDirectory = normalized(settings.workingDirectory)
        paths.repository = normalized(settings.repository)
        paths.python = normalized(settings.python)
        completed = Set(GeneralSetupStep.allCases.filter { (try? paths.validateGeneralPath($0)) != nil })
    }
}
