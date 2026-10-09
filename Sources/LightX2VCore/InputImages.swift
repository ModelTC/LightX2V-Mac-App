import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

public struct InputImage: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let name: String
    public var id: String { path }

    public init(path: String, name: String) { self.path = path; self.name = name }
}

/// Shared by file selection, drops and history reuse. Inference only receives
/// decoded, oriented PNG snapshots, never mutable external source files.
public enum InputImages {
    public static let maximumCount = 8

    public static func validate(_ images: [InputImage]) throws {
        guard images.count <= maximumCount else { throw AppError.message("最多可添加 \(maximumCount) 张图片。") }
        for image in images {
            guard image.path.hasPrefix("/"), FileManager.default.isReadableFile(atPath: image.path) else {
                throw AppError.message("无法读取图片「\(image.name)」，请重新添加。")
            }
        }
    }

    public static func importing(_ urls: [URL], into directory: URL, existing: [InputImage]) throws -> [InputImage] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var result = existing
        var created: [URL] = []
        var digests = try Set(existing.map { image in
            SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: image.path)))
                .map { String(format: "%02x", $0) }.joined()
        })
        do {
            for url in urls {
                guard url.isFileURL else { throw AppError.message("请拖入本机中的图片文件。") }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= 100 * 1024 * 1024,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 40000, height <= 40000, width * height <= 40_000_000 else {
                    throw AppError.message("无法添加「\(url.lastPathComponent)」。请选择不超过 100 MB、4000 万像素的图片。")
                }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                    kCGImageSourceShouldCacheImmediately: true
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                      CGImageSourceGetStatus(source) == .statusComplete else {
                    throw AppError.message("图片「\(url.lastPathComponent)」已损坏或无法解码。")
                }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                    throw AppError.message("无法读取图片。")
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw AppError.message("无法保存输入图片。") }
                let bytes = data as Data
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let path = directory.appendingPathComponent(digest + ".png")
                if digests.contains(digest) { continue }
                guard result.count < maximumCount else { throw AppError.message("最多可添加 \(maximumCount) 张图片。") }
                if !fm.fileExists(atPath: path.path) {
                    try bytes.write(to: path, options: .atomic)
                    created.append(path)
                }
                result.append(InputImage(path: path.path, name: url.lastPathComponent))
                digests.insert(digest)
            }
            return result
        } catch {
            for url in created { try? fm.removeItem(at: url) }
            throw error
        }
    }

    public static func snapshot(_ images: [InputImage], in directory: URL) throws -> [InputImage] {
        try validate(images)
        guard !images.isEmpty else { return [] }
        let folder = directory.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var result: [InputImage] = []
        do {
            for (index, image) in images.enumerated() {
                let target = folder.appendingPathComponent("reference-\(index + 1).png")
                try FileManager.default.copyItem(at: URL(fileURLWithPath: image.path), to: target)
                result.append(InputImage(path: target.path, name: image.name))
            }
            return result
        } catch {
            for image in result { try? FileManager.default.removeItem(atPath: image.path) }
            throw error
        }
    }
}
