import Foundation

/// JSONEncoder's keyed containers do not preserve insertion order. Serialize the
/// encoded values with explicit field groups, including every nested snapshot.
enum ReadableJSON {
    static func format(_ data: Data) throws -> Data {
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return Data((try render(value, depth: 0) + "\n").utf8)
    }
    private static func order(_ object: [String: Any]) -> [String] {
        let fields: [String]
        if object["creationID"] != nil {
            fields = ["id", "creationID", "createdAt", "status", "model", "parameters", "prompt", "promptEnhancement", "inputImages", "outputImages", "execution"]
        } else if object["generations"] != nil {
            fields = ["settings", "hasCompletedGeneralSetup", "activeCreationID", "creationSettings", "generations"]
        } else if object["updatedAt"] != nil {
            fields = ["modelName", "parameters", "promptEnhancement", "updatedAt"]
        } else if object["aspectRatio"] != nil {
            fields = ["resolution", "aspectRatio", "width", "height", "steps", "seed"]
        } else if object["startedAt"] != nil {
            fields = ["directory", "sourceDirectory", "python", "requestFile", "logFile", "startedAt", "inferenceStartedAt", "finishedAt", "durationSeconds", "inferenceDurationSeconds", "error"]
        } else if object["seed"] != nil && object["steps"] != nil {
            fields = ["resolution", "aspectRatio", "width", "height", "steps", "seed"]
        } else if object["configFile"] != nil {
            fields = ["name", "directory", "configFile"]
        } else if object["enabled"] != nil {
            fields = ["enabled", "mode", "status", "modelName", "directory", "modelFile", "systemPromptFile", "visionProjectorFile", "runtimeDirectory", "t2iDirectory", "i2iDirectory", "t2iModel", "t2iSystemPrompt", "i2iModel", "i2iSystemPrompt", "visionProjector", "thinking", "output", "whRatio", "ratioFollow", "durationSeconds"]
        } else {
            fields = ["workingDirectory", "python", "Qwen-Image-2.1-Turbo", "Qwen-Image-2.1-Turbo-INT8", "modelDirectory", "modelDownloadSource", "promptEnhancement", "repository", "model", "config", "modelName", "prompt", "resolution", "width", "height", "seed", "inputImages", "output", "generation", "path", "name"]
        }
        let specified = fields.filter { object[$0] != nil }
        // Unspecified extension fields follow the defined groups; production
        // persisted schemas have all their fields explicitly listed above.
        return specified + object.keys.filter { !fields.contains($0) }.sorted()
    }
    private static func render(_ value: Any, depth: Int) throws -> String {
        let indent = String(repeating: "  ", count: depth)
        let childIndent = indent + "  "
        if let object = value as? [String: Any] {
            if object.isEmpty { return "{}" }
            let rows = try order(object).map { key in
                childIndent + (try scalar(key)) + ": " + (try render(object[key]!, depth: depth + 1))
            }
            return "{\n" + rows.joined(separator: ",\n") + "\n" + indent + "}"
        }
        if let array = value as? [Any] {
            if array.isEmpty { return "[]" }
            return "[\n" + (try array.map { childIndent + (try render($0, depth: depth + 1)) }).joined(separator: ",\n") + "\n" + indent + "]"
        }
        return try scalar(value)
    }
    private static func scalar(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
