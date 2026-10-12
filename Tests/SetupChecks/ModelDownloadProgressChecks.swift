import Foundation
import LightX2VCore

extension SetupChecks {
    static func modelDownloadProgressChecks() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var parser = ModelDownloadProgressParser()
        let started = parser.begin(totalBytes: 1_000_000_000)
        try expect(started.stage == .downloading && started.fraction == 0 && started.bytesPerSecond == nil, "metadata must not invent transfer speed")
        let network = parser.consume("\u{1B}[2ADownloading bytes: ███| 10.0MB  2.50MB/s", at: now)!
        try expect(network.bytesPerSecond == 2_500_000 && network.completedBytes == 0, "compressed network bytes must not advance model byte percentage")
        let files = parser.consume("Reconstructing (incomplete total...): 50%|███| 250MB / 500MB 900MB/s", at: now)!
        try expect(files.fraction == 0.25 && files.percentage == "25%" && files.bytesPerSecond == 2_500_000,
                   "use stable metadata total and network speed rather than reconstruction rate")
        let next = parser.consume("Reconstructing (incomplete total...): 33%|███| 300MB / 900MB 999MB/s", at: now.addingTimeInterval(10))!
        try expect(next.percentage == "30%" && next.remainingSeconds == 140 && next.sequence > files.sequence,
                   "growing CLI totals must not move overall percentage backwards")
        try expect(next.speed(at: now.addingTimeInterval(10)) == 0 && next.speedText(at: now.addingTimeInterval(10)) == "0 B/s", "stalled network must not retain an old positive speed")
        let saved = parser.progress
        for text in ["Fetching 45 files: 98%|██| 44/45 [00:01<00:00, 1.8it/s]", "weight.gguf: 80%|██| 800M/1.0G [00:01<00:00, 900MB/s]", "network warning", "Downloading bytes: ???"] {
            try expect(parser.consume(text) == nil && parser.progress == saved, "file-count, per-file and malformed output must not masquerade as aggregate bytes")
        }
        let binary = parser.consume("Downloading bytes: █| 4.00MiB 1.00MiB/s", at: now.addingTimeInterval(11))!
        try expect(binary.bytesPerSecond == 1_048_576 && binary.speedText(at: now.addingTimeInterval(11)) == "1.0 MB/s", "binary byte units parsed incorrectly")
        let checked = parser.checking()
        try expect(checked.stage == .checking && checked.speed(at: now) == nil && checked.percentage == "检查", "download completion must still check model files")

        var unknown = ModelDownloadProgressParser(); _ = unknown.begin(totalBytes: nil)
        let growing = unknown.consume("Reconstructing (incomplete total...): 60%|█| 1.20GB / 2.00GB 10MB/s")!
        try expect(growing.fraction == nil && growing.completedBytes == 1_200_000_000 && growing.bytesPerSecond == nil,
                   "unknown repository total must remain indeterminate and never claim disk speed as network speed")
        let completed = unknown.consume("Reconstruction complete: 100%|█| 2.00GB / 2.00GB 10MB/s")!
        try expect(completed.fraction == 1, "final reconstruction total was lost")
        var legacy = ModelDownloadProgressParser(); _ = legacy.begin(totalBytes: nil)
        let old = legacy.consume("Downloading: 10%|█| 1.25M/12.5M [00:05<00:45, 250kB/s]", at: now)!
        try expect(abs(old.fraction! - 0.1) < 0.00001 && old.bytesPerSecond == 250_000, "legacy aggregate byte units/rate were lost")
        let retry = legacy.consume("Downloading: 5%|█| 625k/12.5M [00:01<00:20, 500kB/s]", at: now.addingTimeInterval(1))!
        try expect(retry.completedBytes == 625_000 && retry.fraction! < old.fraction!, "actual retry counter resets must not be hidden")
        var derived = ModelDownloadProgressParser(); _ = derived.begin(totalBytes: 10_000_000)
        _ = derived.consume("Downloading bytes: █| 1.00MB ???B/s", at: now)
        let measured = derived.consume("Downloading bytes: █| 3.00MB ???B/s", at: now.addingTimeInterval(2))!
        try expect(measured.bytesPerSecond == 1_000_000, "missing rate should be derived only from actual network byte deltas")
        var buffered = ModelDownloadProgressParser(); _ = buffered.begin(totalBytes: nil)
        _ = buffered.consume("Downloading bytes: | 0.00B", at: now)
        let batched = buffered.consume("Downloading bytes: | 1.00MB", at: now.addingTimeInterval(0.001))!
        try expect(batched.bytesPerSecond == nil, "buffered log frames must not manufacture an enormous network rate")
        print("PASS real aggregate bytes, stable total, Xet network/disk separation, unknown size, SI/IEC units, stalled speed, retry and sequenced updates")
    }
}
