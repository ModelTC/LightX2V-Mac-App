import Foundation

/// One complete, immutable resource/parameter snapshot with mutable execution results.
/// This is the sole persisted generation schema; older record shapes are rejected.
struct GenerationSnapshot: Codable {
    var id: UUID
    var creationID: UUID
    var createdAt: String
    var status: GenerationStatus
    var model: Model
    var parameters: Parameters
    var prompt: String
    var promptEnhancement: Enhancement
    var inputImages: [InputImage]
    var outputImages: [String]
    var execution: Execution

    struct Model: Codable {
        var name: String
        var directory: String
        var configFile: String
    }
    struct Parameters: Codable {
        var resolution: Int
        var aspectRatio: String
        var width: Int?
        var height: Int?
        var steps: Int
        var seed: Int64
    }
    struct Enhancement: Codable {
        var enabled: Bool
        var mode: PromptEnhancementMode?
        var status: PromptEnhancementStatus?
        var modelName: String?
        var directory: String?
        var modelFile: String?
        var systemPromptFile: String?
        var visionProjectorFile: String?
        var runtimeDirectory: String?
        var thinking: String?
        var output: String?
        var whRatio: String?
        var ratioFollow: String?
        var durationSeconds: Double?
    }
    struct Execution: Codable {
        var directory: String
        var sourceDirectory: String
        var python: String
        var requestFile: String
        var logFile: String
        var startedAt: String
        var finishedAt: String?
        var durationSeconds: Double?
        var error: String?
    }

    init(_ job: Generation) {
        id = job.id; creationID = job.creationID
        createdAt = job.createdAt.ISO8601Format(); status = job.status
        let request = job.request
        model = Model(name: QwenImage21Turbo.title, directory: request.model, configFile: request.config)
        let size = GenerationSize(width: request.width, height: request.height, automaticResolution: request.resolution)
        parameters = Parameters(resolution: size.resolution.baseDimension, aspectRatio: request.resolution == nil ? (size.aspectRatio?.rawValue ?? "adaptive") : "adaptive",
                                width: job.actualWidth ?? request.width, height: job.actualHeight ?? request.height,
                                steps: QwenImage21Turbo.inferenceSteps, seed: request.seed)
        prompt = request.prompt
        promptEnhancement = Enhancement(enabled: request.promptEnhancement != nil)
        if let resources = request.promptEnhancement {
            let mode = job.enhancement?.mode ?? (request.inputImages.isEmpty ? .t2i : .i2i)
            let t2i = mode == .t2i
            promptEnhancement.mode = mode
            promptEnhancement.status = job.enhancement?.status
            promptEnhancement.modelName = t2i ? ModelResource.t2i.modelName : ModelResource.i2i.modelName
            promptEnhancement.directory = t2i ? resources.t2iDirectory : resources.i2iDirectory
            promptEnhancement.modelFile = t2i ? resources.t2iModel : resources.i2iModel
            promptEnhancement.systemPromptFile = t2i ? resources.t2iSystemPrompt : resources.i2iSystemPrompt
            promptEnhancement.visionProjectorFile = t2i ? nil : resources.visionProjector
            promptEnhancement.runtimeDirectory = resources.runtimeDirectory
            promptEnhancement.thinking = job.enhancement.flatMap { $0.thinking.isEmpty ? nil : $0.thinking }
            promptEnhancement.output = job.enhancement?.prompt
            promptEnhancement.whRatio = job.enhancement?.whRatio
            promptEnhancement.ratioFollow = job.enhancement?.ratioFollow
            promptEnhancement.durationSeconds = job.enhancement?.duration
        }
        inputImages = request.inputImages
        // Retain the intended output path even for interrupted/failed tasks.
        outputImages = [request.output]
        execution = Execution(directory: job.directory, sourceDirectory: request.repository, python: job.python,
                              requestFile: job.directory + "/request.json", logFile: job.directory + "/run.log",
                              startedAt: createdAt, finishedAt: job.finishedAt?.ISO8601Format(), durationSeconds: job.duration, error: job.error)
    }

    func generation() throws -> Generation {
        guard model.name == QwenImage21Turbo.title, parameters.steps == QwenImage21Turbo.inferenceSteps,
              let output = outputImages.first, outputImages.count == 1,
              let created = ISO8601DateFormatter().date(from: createdAt) else {
            throw AppError.message("Invalid generation snapshot")
        }
        var settings = AppSettings(repository: execution.sourceDirectory, model: model.directory, config: model.configFile, python: execution.python)
        settings.promptEnhancement.enabled = promptEnhancement.enabled
        var reply: PromptEnhancementReply?
        if promptEnhancement.enabled {
            guard let mode = promptEnhancement.mode, let peStatus = promptEnhancement.status,
                  let name = promptEnhancement.modelName, let directory = promptEnhancement.directory,
                  let file = promptEnhancement.modelFile, let system = promptEnhancement.systemPromptFile,
                  let runtime = promptEnhancement.runtimeDirectory,
                  name == (mode == .t2i ? ModelResource.t2i.modelName : ModelResource.i2i.modelName) else {
                throw AppError.message("Incomplete prompt enhancement snapshot")
            }
            settings.promptEnhancement.runtimeDirectory = runtime
            if mode == .t2i {
                settings.promptEnhancement.t2iDirectory = directory
                settings.promptEnhancement.t2iModel = file; settings.promptEnhancement.t2iSystemPrompt = system
            } else {
                guard let projector = promptEnhancement.visionProjectorFile else { throw AppError.message("Missing I2I projector snapshot") }
                settings.promptEnhancement.i2iDirectory = directory
                settings.promptEnhancement.i2iModel = file; settings.promptEnhancement.i2iSystemPrompt = system
                settings.promptEnhancement.visionProjector = projector
            }
            var value = PromptEnhancementReply(mode: mode); value.status = peStatus
            value.thinking = promptEnhancement.thinking ?? ""; value.prompt = promptEnhancement.output
            value.whRatio = promptEnhancement.whRatio; value.ratioFollow = promptEnhancement.ratioFollow
            value.duration = promptEnhancement.durationSeconds; reply = value
        }
        // Decode history without checking whether external input files still exist.
        let data = try JSONSerialization.data(withJSONObject: [
            "repository": settings.repository, "model": settings.model, "config": settings.config,
            "prompt": prompt, "width": parameters.aspectRatio == "adaptive" ? NSNull() : parameters.width.map { $0 as Any } ?? NSNull(),
            "height": parameters.aspectRatio == "adaptive" ? NSNull() : parameters.height.map { $0 as Any } ?? NSNull(),
            "resolution": parameters.aspectRatio == "adaptive" ? parameters.resolution as Any : NSNull(),
            "seed": parameters.seed, "output": output,
            "inputImages": inputImages.map { ["path": $0.path, "name": $0.name] }
        ])
        var request = try JSONDecoder().decode(InferenceRequest.self, from: data)
        request.promptEnhancement = promptEnhancement.enabled ? settings.promptEnhancement : nil
        var job = Generation(id: id, creationID: creationID, request: request)
        job.createdAt = created; job.status = status; job.enhancement = reply
        job.python = execution.python; job.actualWidth = parameters.width; job.actualHeight = parameters.height
        job.duration = execution.durationSeconds; job.error = execution.error
        if let finished = execution.finishedAt {
            guard let date = ISO8601DateFormatter().date(from: finished) else { throw AppError.message("Invalid finishedAt") }
            job.finishedAt = date
        }
        return job
    }
}

/// Keep the bridge's runtime request fields and the exact history snapshot together.
/// Updating this file after enhancement never replaces the original prompt.
public struct GenerationRequestDocument: Encodable {
    let generation: Generation
    public init(_ generation: Generation) { self.generation = generation }
    private enum CodingKeys: String, CodingKey { case generation }
    public func encode(to encoder: Encoder) throws {
        try generation.request.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generation, forKey: .generation)
    }
}
