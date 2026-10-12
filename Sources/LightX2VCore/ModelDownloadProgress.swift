import Foundation

public struct ModelDownloadProgress: Equatable, Sendable {
    public enum Stage: Equatable, Sendable { case preparing, downloading, checking }
    public var stage: Stage = .preparing
    public var sequence = 0
    public var completedBytes: Double = 0
    public var totalBytes: Double?
    public var bytesPerSecond: Double?
    public var speedUpdatedAt: Date?
    public var remainingSeconds: Double?

    public init() {}
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, completedBytes / totalBytes))
    }
    public var percentage: String {
        if stage == .preparing { return "准备" }
        if stage == .checking { return "检查" }
        return fraction.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? "—%"
    }
    public func speed(at date: Date) -> Double? {
        guard stage == .downloading, let bytesPerSecond, let speedUpdatedAt else { return nil }
        return date.timeIntervalSince(speedUpdatedAt) < 5 ? bytesPerSecond : 0
    }
    public func speedText(at date: Date) -> String {
        speed(at: date).map { Self.bytes($0) + "/s" } ?? "— B/s"
    }
    public func detail(at date: Date) -> String {
        switch stage {
        case .preparing: return "获取模型信息…"
        case .checking: return "下载结束，正在检查模型文件…"
        case .downloading:
            let amount = Self.bytes(completedBytes) + (totalBytes.map { " / " + Self.bytes($0) } ?? " · 总大小待确认")
            var text = "本次下载 " + amount + "\n网络速度 " + speedText(at: date)
            if let remainingSeconds, remainingSeconds.isFinite, remainingSeconds > 0, speed(at: date) != 0 {
                let minutes = max(1, Int(ceil(remainingSeconds / 60)))
                text += "\n预计剩余 " + (minutes < 60 ? "约 \(minutes) 分钟" : "约 \(minutes / 60) 小时 \(minutes % 60) 分钟")
            }
            return text
        }
    }
    private static func bytes(_ count: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = max(0, count), index = 0
        while value >= 1000 && index < units.count - 1 { value /= 1000; index += 1 }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), value, units[index])
    }
}

/// HF's file-count bar is not byte progress. Xet also separates network bytes
/// from reconstructed file bytes: only the former may supply download speed.
public struct ModelDownloadProgressParser: Sendable {
    public private(set) var progress = ModelDownloadProgress()
    private var expectedBytes: Double?
    private var lastCompletedAt: Date?
    private var lastCompleted: Double = 0
    private var completionRate: Double?
    private var networkBytes: Double?
    private var networkAt: Date?
    private static let quantity = #"([0-9]+(?:\.[0-9]+)?)\s*([kKMGTPE]?i?B|[kKMGTPE])?"#

    public init() {}
    public mutating func begin(totalBytes: Double?) -> ModelDownloadProgress {
        expectedBytes = totalBytes.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        progress.stage = .downloading; progress.totalBytes = expectedBytes
        progress.sequence += 1
        return progress
    }
    public mutating func checking() -> ModelDownloadProgress {
        progress.stage = .checking; progress.bytesPerSecond = nil; progress.remainingSeconds = nil
        progress.sequence += 1
        return progress
    }
    public mutating func consume(_ output: String, at date: Date = Date()) -> ModelDownloadProgress? {
        let text = output.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = text.firstIndex(of: ":") else { return nil }
        let title = String(text[..<separator]).lowercased()
        let payload = String(text[(text.lastIndex(of: "|") ?? separator)...].dropFirst())
        let pair = Self.captures(Self.quantity + #"\s*/\s*"# + Self.quantity, in: payload)
        let reconstructing = title.hasPrefix("reconstructing") || title.hasPrefix("reconstruction complete")
        let network = title.hasPrefix("downloading bytes") || (title.hasPrefix("download complete") && pair == nil)
        let legacyAggregate = title == "downloading" || title.hasPrefix("downloading (") || (title.hasPrefix("download complete") && pair != nil)
        guard network || reconstructing || legacyAggregate else { return nil }
        progress.stage = .downloading
        if network {
            guard let amount = Self.captures(Self.quantity, in: payload), let count = Self.count(amount[0], amount[1]) else { return nil }
            let rate = Self.rate(in: payload)
            var measured = rate
            if let networkBytes, let networkAt, count >= networkBytes {
                let elapsed = date.timeIntervalSince(networkAt)
                // Several log frames can arrive in one read. Do not turn their
                // microsecond callback spacing into a fictitious network rate.
                if elapsed >= 0.5 {
                    if measured == nil { measured = (count - networkBytes) / elapsed }
                    self.networkBytes = count; self.networkAt = date
                }
            } else {
                networkBytes = count; networkAt = date
            }
            if let measured { progress.bytesPerSecond = measured; progress.speedUpdatedAt = date }
        } else {
            guard let pair, let completed = Self.count(pair[0], pair[1]), let total = Self.count(pair[2], pair[3]) else { return nil }
            progress.completedBytes = completed
            // The CLI grows "incomplete total" as workers open files. Use the
            // dry-run total, or remain indeterminate until a stable total exists.
            progress.totalBytes = expectedBytes ?? (title.contains("incomplete") ? nil : total > 0 ? total : nil)
            if let expectedBytes, completed > expectedBytes * 1.02 { progress.totalBytes = nil }
            if let lastCompletedAt {
                let elapsed = date.timeIntervalSince(lastCompletedAt), delta = completed - lastCompleted
                if delta < 0 { completionRate = nil }
                else if delta > 0 && elapsed > 0.1 {
                    let rate = delta / elapsed
                    completionRate = completionRate.map { $0 * 0.75 + rate * 0.25 } ?? rate
                }
            }
            lastCompletedAt = date; lastCompleted = completed
            progress.remainingSeconds = completionRate.flatMap { rate in
                progress.totalBytes.map { max(0, $0 - completed) / rate }
            }
            if legacyAggregate, let rate = Self.rate(in: payload) {
                progress.bytesPerSecond = rate; progress.speedUpdatedAt = date
            }
        }
        progress.sequence += 1
        return progress
    }
    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
    }
    private static func count(_ number: String, _ unit: String) -> Double? {
        guard let value = Double(number), value.isFinite, value >= 0 else { return nil }
        let prefix = unit.prefix(1).uppercased()
        let exponent = ["K": 1, "M": 2, "G": 3, "T": 4, "P": 5, "E": 6][prefix] ?? 0
        let count = value * pow(unit.contains("i") ? 1024 : 1000, Double(exponent))
        return count.isFinite ? count : nil
    }
    private static func rate(in payload: String) -> Double? {
        guard let values = captures(#"([0-9]+(?:\.[0-9]+)?)\s*([kKMGTPE]?i?B)/s"#, in: payload) else { return nil }
        return count(values[0], values[1])
    }
}
