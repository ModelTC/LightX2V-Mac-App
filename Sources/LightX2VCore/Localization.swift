import Foundation

/// Operational messages use English templates. Translation happens only at the UI boundary.
public enum L10n {
    public static let languageCodes = ["en", "zh-Hans", "fr", "ja", "ko", "de", "ru", "es", "pt"]
    private static let lock = NSLock()
    private static var selected = "en"
    public static var languageCode: String {
        get { lock.lock(); defer { lock.unlock() }; return selected }
        set { lock.lock(); selected = languageCodes.contains(newValue) ? newValue : "en"; lock.unlock() }
    }
    public static func resolve(_ preferred: [String]) -> String {
        for language in preferred {
            let code = language.lowercased().replacingOccurrences(of: "_", with: "-")
            if code.hasPrefix("zh") { return "zh-Hans" }
            if let match = languageCodes.first(where: { code == $0 || code.hasPrefix($0 + "-") }) { return match }
        }
        return "en"
    }
    private static let resources: Bundle = {
        if Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en") != nil { return .main }
        return .module
    }()
    public static func catalog(_ code: String) -> [String: String] {
        guard let url = resources.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: code),
              let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return value
    }
    private static let tables = Dictionary(uniqueKeysWithValues: languageCodes.map { ($0, catalog($0)) })
    private static let slots = try! NSRegularExpression(pattern: "%@|%\\.[0-9]+f")
    private static func substitute(_ template: String, _ values: [String]) -> String {
        var result = template
        let matches = slots.matches(in: template, range: NSRange(template.startIndex..., in: template))
        guard matches.count == values.count else { return template }
        for (match, value) in zip(matches, values).reversed() {
            if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: value) }
        }
        return result
    }
    public static func english(_ key: String, _ values: [String] = []) -> String { substitute(key, values) }
    public static func text(_ key: String, _ values: [String] = []) -> String {
        let code = languageCode
        let template = tables[code]?[key] ?? key
        // Formatting arguments are user data unless the caller explicitly renders a message.
        return substitute(template, values)
    }
    private struct Pattern {
        let key: String
        let expression: NSRegularExpression
    }
    private static let patterns: [Pattern] = (tables["en"] ?? [:]).keys.compactMap { key in
        let matches = slots.matches(in: key, range: NSRange(key.startIndex..., in: key))
        guard !matches.isEmpty else { return nil }
        var pattern = ""; var cursor = key.startIndex
        for match in matches {
            guard let range = Range(match.range, in: key) else { return nil }
            pattern += NSRegularExpression.escapedPattern(for: String(key[cursor..<range.lowerBound])) + "([\\s\\S]*?)"
            cursor = range.upperBound
        }
        pattern += NSRegularExpression.escapedPattern(for: String(key[cursor...]))
        guard let regex = try? NSRegularExpression(pattern: "\\A" + pattern + "\\z") else { return nil }
        return Pattern(key: key, expression: regex)
    }.sorted { $0.key.count > $1.key.count }
    /// Renders persisted English status/error messages without changing their stored value.
    public static func render(_ value: String) -> String { render(value, code: languageCode, depth: 0) }
    private static func render(_ value: String, code: String, depth: Int) -> String {
        guard code != "en", depth < 5 else { return value }
        if let translated = tables[code]?[value] { return translated }
        for pattern in patterns {
            guard let match = pattern.expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { continue }
            let arguments = (1..<match.numberOfRanges).compactMap { index -> String? in
                guard let range = Range(match.range(at: index), in: value) else { return nil }
                return render(String(value[range]), code: code, depth: depth + 1)
            }
            let template = tables[code]?[pattern.key] ?? pattern.key
            return substitute(template, arguments)
        }
        if let newline = value.firstIndex(of: "\n") {
            let boundary = value.index(after: newline)
            let header = String(value[..<boundary])
            if boundary < value.endIndex {
                let translated = render(header, code: code, depth: depth + 1)
                if translated != header { return translated + value[boundary...] }
            }
            return value.components(separatedBy: "\n").map { render($0, code: code, depth: depth + 1) }.joined(separator: "\n")
        }
        return value
    }
}
