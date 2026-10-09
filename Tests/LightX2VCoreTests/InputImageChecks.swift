import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import LightX2VCore

func inputImageChecks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("images, 中文 " + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func fixture(_ name: String, _ color: CGFloat, orientation: Int = 1) throws -> URL {
        let url = root.appendingPathComponent(name)
        let context = CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 120,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: color, green: 0.5, blue: 1, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try expect(CGImageDestinationFinalize(dest), "fixture encoding")
        return url
    }
    func rejects(_ message: String, _ action: () throws -> Void) throws {
        var failed = false
        do { try action() } catch { failed = true }
        try expect(failed, message)
    }
    let first = try fixture("原图, 一.tiff", 1, orientation: 6)
    let second = try fixture("原图 二.tiff", 0)
    let draft = root.appendingPathComponent("draft")
    let images = try InputImages.importing([first, second, first], into: draft, existing: [])
    try expect(images.count == 2 && images.map(\.name) == [first.lastPathComponent, second.lastPathComponent], "order and duplicate removal")
    let decoded = CGImageSourceCreateWithURL(URL(fileURLWithPath: images[0].path) as CFURL, nil)!
    let pixels = CGImageSourceCreateImageAtIndex(decoded, 0, nil)!
    try expect(pixels.width == 20 && pixels.height == 30, "EXIF rotation was lost")
    try expect(pixels.alphaInfo == .last || pixels.alphaInfo == .premultipliedLast, "alpha lost")
    let same = try InputImages.importing([first], into: draft, existing: images)
    try expect(same == images, "repeated import duplicates inputs")
    let job = root.appendingPathComponent("job, with spaces")
    let snapshots = try InputImages.snapshot(images, in: job)
    try expect(snapshots.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["reference-1.png", "reference-2.png"], "unsafe snapshot paths")
    try expect(snapshots.map(\.name) == images.map(\.name), "snapshot names changed")
    try fm.removeItem(at: first); try fm.removeItem(at: second); try fm.removeItem(at: draft)
    try InputImages.validate(snapshots)
    let reused = try InputImages.snapshot(snapshots, in: root.appendingPathComponent("reuse"))
    let reusedBytes = try Data(contentsOf: URL(fileURLWithPath: reused[0].path))
    let snapshotBytes = try Data(contentsOf: URL(fileURLWithPath: snapshots[0].path))
    try expect(reusedBytes == snapshotBytes, "reuse depends on deleted originals")
    let request = try InferenceRequest(settings: .defaults, prompt: "combine", width: 1024, height: 1024, seed: 1, output: job.appendingPathComponent("image.png").path, inputImages: snapshots)
    let data = try JSONEncoder().encode(request)
    let restored = try JSONDecoder().decode(InferenceRequest.self, from: data)
    try expect(restored.inputImages == snapshots, "history lost input order")
    var textOnly = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    textOnly.removeValue(forKey: "inputImages")
    let original = try JSONDecoder().decode(InferenceRequest.self, from: JSONSerialization.data(withJSONObject: textOnly))
    try expect(original.inputImages.isEmpty, "text-only history no longer loads")
    let bad = root.appendingPathComponent("bad.png"); try Data("not an image".utf8).write(to: bad)
    let oversized = root.appendingPathComponent("oversized.png")
    try Data().write(to: oversized)
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: 100 * 1024 * 1024 + 1); try handle.close()
    try rejects("oversized file accepted") { _ = try InputImages.importing([oversized], into: draft, existing: []) }
    let valid = try fixture("good.tiff", 0.8)
    try rejects("mixed bad batch accepted") { _ = try InputImages.importing([valid, bad], into: draft, existing: snapshots) }
    let files = try fm.contentsOfDirectory(atPath: draft.path)
    try expect(files.isEmpty, "failed batch left partial imports")
    try rejects("directory accepted") { _ = try InputImages.importing([root], into: draft, existing: []) }
    try rejects("web URL accepted") { _ = try InputImages.importing([URL(string: "https://example.com/p.png")!], into: draft, existing: []) }
    var many: [URL] = []
    for i in 0...8 { many.append(try fixture("\(i).tiff", CGFloat(i) / 9)) }
    try rejects("ninth image accepted") { _ = try InputImages.importing(many, into: draft, existing: []) }
    let afterLimit = try fm.contentsOfDirectory(atPath: draft.path)
    try expect(afterLimit.isEmpty, "over-limit batch not rolled back")
    try fm.removeItem(atPath: snapshots[0].path)
    try rejects("deleted history input accepted") { try InputImages.validate(snapshots) }
    try rejects("relative reference accepted") { try InputImages.validate([InputImage(path: "relative.png", name: "relative")]) }
    print("PASS image import, orientation, alpha, deduplication, snapshots, reuse and atomic failures")
}
