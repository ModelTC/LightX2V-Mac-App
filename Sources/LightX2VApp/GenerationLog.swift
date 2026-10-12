import Foundation
import LightX2VCore

/// Each submitted turn owns a complete log. Only the UI preview is bounded.
final class GenerationLog {
    static let previewBytes = 90_000
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "app.lightx2v.log.\(UUID().uuidString)")
    private let onError: (String) -> Void
    private var reportedError = false

    init(directory: URL, onError: @escaping (String) -> Void) throws {
        let url = directory.appendingPathComponent("run.log")
        try Data().write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
        self.onError = onError
    }

    func append(_ text: String) {
        queue.async { [self] in
            do { try handle.write(contentsOf: Data(text.utf8)) }
            catch { report(error) }
        }
    }

    func close() {
        queue.sync {
            do { try handle.synchronize() } catch { report(error) }
            do { try handle.close() } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        guard !reportedError else { return }
        reportedError = true
        let message = L10n.english("Unable to save task log: %@", [String(describing: error.localizedDescription)])
        DispatchQueue.main.async { [onError] in onError(message) }
    }

    static func preview(_ text: String) -> String {
        decodeTail(Data(text.utf8))
    }

    private static func decodeTail(_ data: Data) -> String {
        // A byte limit can cut a Chinese character or emoji in half.
        var tail = data.suffix(previewBytes)
        while let byte = tail.first, byte & 0xc0 == 0x80 { tail = tail.dropFirst() }
        return String(decoding: tail, as: UTF8.self)
    }

    static func existingURL(for job: Generation) -> URL? {
        existingURL(directory: job.directory)
    }

    private static func existingURL(directory path: String) -> URL? {
        let directory = URL(fileURLWithPath: path)
        return ["run.log", "inference.log", "enhancement/llama.log"]
            .map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func readPreview(directory: String, error: String?) -> String {
        var text = ""
        if let url = existingURL(directory: directory) {
            do {
                let reader = try FileHandle(forReadingFrom: url)
                defer { try? reader.close() }
                let count = try reader.seekToEnd()
                try reader.seek(toOffset: count > UInt64(previewBytes) ? count - UInt64(previewBytes) : 0)
                text = decodeTail(try reader.read(upToCount: previewBytes) ?? Data())
            } catch { text = L10n.english("Unable to read log: %@", [String(describing: error.localizedDescription)]) }
        }
        if let error, !error.isEmpty, !text.contains(error) {
            text += (text.isEmpty ? "" : "\n\n") + error
        }
        return text.isEmpty ? L10n.english("No log available.") : preview(text)
    }
}
