import Foundation

/// The last edited state of a creation, independent of immutable run snapshots.
public struct CreationSettings: Codable, Equatable {
    public var modelName: String
    public var parameters: Parameters
    public var promptEnhancement: Enhancement
    public var updatedAt: String
    public struct Parameters: Codable, Equatable {
        public var resolution: Int
        public var aspectRatio: String
    }
    public struct Enhancement: Codable, Equatable { public var enabled: Bool }
    public init(modelName: String = QwenImage21Turbo.title, size: GenerationSize = GenerationSize(), enhancementEnabled: Bool = true) {
        self.modelName = modelName
        parameters = Parameters(resolution: size.resolution.baseDimension, aspectRatio: size.aspectRatio?.rawValue ?? "adaptive")
        promptEnhancement = Enhancement(enabled: enhancementEnabled)
        updatedAt = Date().ISO8601Format()
    }
    private enum CodingKeys: String, CodingKey { case modelName, parameters, promptEnhancement, updatedAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modelName = try values.decode(String.self, forKey: .modelName)
        parameters = try values.decode(Parameters.self, forKey: .parameters)
        promptEnhancement = try values.decode(Enhancement.self, forKey: .promptEnhancement)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        guard modelName == QwenImage21Turbo.title,
              ImageResolution.allCases.contains(where: { $0.baseDimension == parameters.resolution }),
              parameters.aspectRatio == "adaptive" || ImageAspectRatio(rawValue: parameters.aspectRatio) != nil,
              ISO8601DateFormatter().date(from: updatedAt) != nil else {
            throw AppError.message("Invalid creation settings")
        }
    }
    public var size: GenerationSize {
        var result = GenerationSize()
        result.selectResolution(ImageResolution.allCases.first { $0.baseDimension == parameters.resolution }!)
        result.selectAspectRatio(ImageAspectRatio(rawValue: parameters.aspectRatio))
        return result
    }
}
