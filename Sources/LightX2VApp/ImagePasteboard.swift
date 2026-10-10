import AppKit
import UniformTypeIdentifiers

/// Capture the clipboard before another copy replaces it. Decode and normalize
/// these immutable sources through the same importer as selected image files.
enum ImagePasteboard {
    enum Source: Sendable {
        case file(URL)
        case data(Data, fileExtension: String)
    }

    static func containsImages(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains { $0 == .fileURL || isImageType($0) } == true
    }

    static func read(_ pasteboard: NSPasteboard) throws -> [Source] {
        try (pasteboard.pasteboardItems ?? []).compactMap { item in
            // Finder can also provide a preview. Import the actual file once.
            if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
                return .file(url)
            }
            let type = [NSPasteboard.PasteboardType.png, .tiff].first { item.types.contains($0) }
                ?? item.types.first(where: isImageType)
            guard let type else { return nil }
            guard let data = item.data(forType: type), !data.isEmpty, data.count <= 100 * 1024 * 1024 else {
                throw NSError(domain: "LightX2V.Clipboard", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "无法读取剪贴板图片，请重新复制不超过 100 MB 的图片。"])
            }
            return .data(data, fileExtension: UTType(type.rawValue)?.preferredFilenameExtension ?? "png")
        }
    }

    static func materialize(_ sources: [Source], in directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try sources.enumerated().map { index, source in
            switch source {
            case .file(let url): return url
            case .data(let bytes, let fileExtension):
                let url = directory.appendingPathComponent("粘贴图片-\(index + 1).\(fileExtension)")
                try bytes.write(to: url, options: .atomic)
                return url
            }
        }
    }

    private static func isImageType(_ type: NSPasteboard.PasteboardType) -> Bool {
        UTType(type.rawValue)?.conforms(to: .image) == true
    }
}
