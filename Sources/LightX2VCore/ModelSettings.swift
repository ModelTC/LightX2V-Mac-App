import Foundation

/// User-selected folders only; inference requests own the resolved files.
public struct PromptEnhancementConfiguration: Codable, Equatable {
    public var enabled: Bool
    public var t2iDirectory: String
    public var i2iDirectory: String

    public init(_ resources: PromptEnhancementSettings) {
        enabled = resources.enabled
        t2iDirectory = resources.t2iDirectory
        i2iDirectory = resources.i2iDirectory
    }

    public var resources: PromptEnhancementSettings {
        var value = PromptEnhancementSettings()
        value.enabled = enabled
        value.t2iDirectory = t2iDirectory
        value.i2iDirectory = i2iDirectory
        return value
    }
}

public struct QwenImage21TurboSettings: Codable, Equatable {
    public var modelDirectory: String
    public var modelDownloadSource: ModelDownloadSource
    public var promptEnhancement: PromptEnhancementSettings

    public init(modelDirectory: String = "", modelDownloadSource: ModelDownloadSource = .huggingFace,
                promptEnhancement: PromptEnhancementSettings = .init()) {
        self.modelDirectory = modelDirectory
        self.modelDownloadSource = modelDownloadSource
        self.promptEnhancement = promptEnhancement
    }

    private enum CodingKeys: String, CodingKey { case modelDirectory, modelDownloadSource, promptEnhancement }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modelDirectory = try values.decode(String.self, forKey: .modelDirectory)
        modelDownloadSource = try values.decode(ModelDownloadSource.self, forKey: .modelDownloadSource)
        promptEnhancement = try values.decode(PromptEnhancementConfiguration.self, forKey: .promptEnhancement).resources
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(modelDirectory, forKey: .modelDirectory)
        try values.encode(modelDownloadSource, forKey: .modelDownloadSource)
        try values.encode(PromptEnhancementConfiguration(promptEnhancement), forKey: .promptEnhancement)
    }
}
