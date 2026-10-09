import AppKit
import ImageIO

enum LocalImagePreview {
    /// File access can wait for a macOS permission prompt. Never perform it
    /// during SwiftUI layout or on the main thread.
    @MainActor static func load(_ path: String, maximumDimension: Int) async -> NSImage? {
        let image = await Task.detached(priority: .userInitiated) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension
            ]
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil as CGImage? }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard !Task.isCancelled, let image else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}
