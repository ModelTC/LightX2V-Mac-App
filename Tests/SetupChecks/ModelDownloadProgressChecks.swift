import Foundation
import LightX2VCore

extension SetupChecks {
    static func modelDownloadProgressChecks() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var parser = ModelDownloadProgressParser()
        let started = parser.begin(totalBytes: nil)
        try expect(started.fraction == nil && started.fileCountText == "—/—", "unknown file total must not invent a percentage")
        let initial = parser.consume("Fetching 32 files: 0%|          | 0/32 [00:00<?, ?it/s]", at: now)!
        try expect(initial.fraction == 0 && initial.fileCountText == "0/32", "initial HF file count was lost")
        let network = parser.consume("\u{1B}[2ADownloading bytes: | 228MB, 3.25MB/s", at: now)!
        try expect(network.bytesPerSecond == 3_250_000 && network.percentage == "0%", "network speed must not change the completed-file count")
        _ = parser.consume("Reconstructing (incomplete total...): 0%| | 11.1MB / 9.53GB, 99MB/s", at: now)
        let files = parser.consume("Fetching 32 files: 81%|████| 26/32 [00:01<00:00, 1.8it/s]\u{1B}[A", at: now)!
        try expect(files.fraction == 26.0 / 32 && files.percentage == "81%" && files.fileCountText == "26/32" && files.bytesPerSecond == 3_250_000,
                   "file count, percentage and network speed must remain independent of reconstruction bytes")
        let saved = parser.progress
        for text in ["Fetching files: 25%", "Fetching 32 files: 90%| | 33/32", "weight.gguf: 80%| | 8/10 [00:01]", "network warning", "Downloading bytes: ???"] {
            try expect(parser.consume(text) == nil && parser.progress == saved, "malformed counters and per-file output must not affect repository progress")
        }
        let stalled = parser.progress
        try expect(stalled.speedText(at: now.addingTimeInterval(6)) == "0 B/s", "stalled network must not retain an old positive speed")
        let binary = parser.consume("Downloading bytes: | 4.00MiB 1.00MiB/s", at: now.addingTimeInterval(7))!
        try expect(binary.bytesPerSecond == 1_048_576 && binary.fileCountText == "26/32", "binary speed must not reset files")
        let final = parser.consume("Fetching 32 files: 100%|████| 32/32 [00:02<00:00, 1.8it/s]")!
        try expect(final.fraction == 1 && final.percentage == "100%", "completion must come from the HF file counter")
        try expect(parser.checking().percentage == "检查", "model validation must follow transfer completion")
        var retry = ModelDownloadProgressParser(); _ = retry.begin(totalBytes: nil)
        let resumed = retry.consume("Fetching 5 files: 60%| | 3/5 [00:01]")!
        try expect(resumed.percentage == "60%", "cached completed files must contribute to progress")
        var buffered = ModelDownloadProgressParser(); _ = buffered.begin(totalBytes: nil)
        _ = buffered.consume("Downloading bytes: | 0.00B", at: now)
        let batch = buffered.consume("Downloading bytes: | 1.00MB", at: now.addingTimeInterval(0.001))!
        try expect(batch.bytesPerSecond == nil, "buffered frames must not manufacture a network rate")
        let derived = buffered.consume("Downloading bytes: | 3.00MB", at: now.addingTimeInterval(2))!
        try expect(derived.bytesPerSecond == 1_500_000, "missing network rate must use measured bytes over elapsed time")
        print("PASS HF completed-file counts, 26/32 regression, independent network speed, cached files, malformed output, stalls and buffered frames")
    }
}
