import Foundation

public enum ImageResolution: String, CaseIterable, Identifiable {
    case fiveTwelve = "512", oneK = "1K", twoK = "2K"
    public var id: String { rawValue }
    public var baseDimension: Int {
        switch self { case .fiveTwelve: return 512; case .oneK: return 1024; case .twoK: return 2048 }
    }
}

public struct ImageDimensions: Equatable {
    public let width: Int
    public let height: Int
    public static let allowedRange = 256...2752
    public static let validationMessage = L10n.english("Width and height must be multiples of 32 between 256 and 2752.")

    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var isValid: Bool {
        Self.allowedRange.contains(width) && Self.allowedRange.contains(height) && width % 32 == 0 && height % 32 == 0
    }
}

public enum ImageAspectRatio: String, CaseIterable, Identifiable {
    case square = "1:1", landscape43 = "4:3", portrait34 = "3:4"
    case landscape32 = "3:2", portrait23 = "2:3", landscape169 = "16:9", portrait916 = "9:16"
    public var id: String { rawValue }
    public var ratio: Double {
        let parts = rawValue.split(separator: ":").map { Double($0)! }
        return parts[0] / parts[1]
    }

    public func dimensions(at resolution: ImageResolution) -> ImageDimensions {
        // 512 and 1K follow LightX2V image_dimensions(resolution, ratio). 2K uses Qwen's official table.
        // The 2K table is intentionally not derived by doubling the 1K sizes.
        let size: (Int, Int)
        switch (resolution, self) {
        case (.fiveTwelve, .square): size = (512, 512)
        case (.fiveTwelve, .landscape43): size = (576, 448)
        case (.fiveTwelve, .portrait34): size = (448, 576)
        case (.fiveTwelve, .landscape32): size = (640, 416)
        case (.fiveTwelve, .portrait23): size = (416, 640)
        case (.fiveTwelve, .landscape169): size = (672, 384)
        case (.fiveTwelve, .portrait916): size = (384, 672)
        case (.oneK, .square): size = (1024, 1024)
        case (.oneK, .landscape43): size = (1184, 896)
        case (.oneK, .portrait34): size = (896, 1184)
        case (.oneK, .landscape32): size = (1248, 832)
        case (.oneK, .portrait23): size = (832, 1248)
        case (.oneK, .landscape169): size = (1376, 768)
        case (.oneK, .portrait916): size = (768, 1376)
        case (.twoK, .square): size = (2048, 2048)
        case (.twoK, .landscape43): size = (2400, 1792)
        case (.twoK, .portrait34): size = (1792, 2400)
        case (.twoK, .landscape32): size = (2528, 1696)
        case (.twoK, .portrait23): size = (1696, 2528)
        case (.twoK, .landscape169): size = (2752, 1536)
        case (.twoK, .portrait916): size = (1536, 2752)
        }
        return ImageDimensions(width: size.0, height: size.1)
    }
}

public struct GenerationSize {
    public private(set) var resolution: ImageResolution = .oneK
    /// A nil ratio delegates output dimensions to the model.
    public private(set) var aspectRatio: ImageAspectRatio? = nil
    public var dimensions: ImageDimensions? { aspectRatio?.dimensions(at: resolution) }
    public var automaticResolution: Int? { aspectRatio == nil ? resolution.baseDimension : nil }

    public init() {}

    public init(width: Int?, height: Int?, automaticResolution: Int? = nil) {
        if let automaticResolution {
            resolution = ImageResolution.allCases.first { $0.baseDimension == automaticResolution } ?? .oneK
            aspectRatio = nil
            return
        }
        guard let width, let height else { return }
        // Keep exact presets; map legacy custom sizes to the nearest tier and ratio.
        let original = ImageDimensions(width: width, height: height)
        for tier in ImageResolution.allCases {
            if let ratio = ImageAspectRatio.allCases.first(where: { $0.dimensions(at: tier) == original }) {
                resolution = tier
                aspectRatio = ratio
                return
            }
        }
        let area = Double(max(1, width)) * Double(max(1, height))
        resolution = ImageResolution.allCases.min {
            abs(log(area / pow(Double($0.baseDimension), 2))) < abs(log(area / pow(Double($1.baseDimension), 2)))
        } ?? .oneK
        let currentRatio = Double(max(1, width)) / Double(max(1, height))
        aspectRatio = ImageAspectRatio.allCases.min {
            abs(log($0.ratio / currentRatio)) < abs(log($1.ratio / currentRatio))
        } ?? .square
    }

    public mutating func selectResolution(_ value: ImageResolution) { resolution = value }
    public mutating func selectAspectRatio(_ value: ImageAspectRatio?) { aspectRatio = value }
}
