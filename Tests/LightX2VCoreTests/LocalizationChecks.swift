import Foundation
import LightX2VCore

func localizationChecks() throws {
    let english = L10n.catalog("en")
    try expect(english.count >= 380, "English localization bundle missing")
    let slots = try NSRegularExpression(pattern: "%@|%\\.[0-9]+f")
    func count(_ value: String) -> Int { slots.numberOfMatches(in: value, range: NSRange(value.startIndex..., in: value)) }
    for code in L10n.languageCodes {
        let table = L10n.catalog(code)
        try expect(Set(table.keys) == Set(english.keys), "incomplete translations: \(code)")
        for (key, value) in table {
            try expect(!value.isEmpty && count(key) == count(value), "invalid placeholders: \(code) \(key)")
        }
        L10n.languageCode = code
        try expect(L10n.english("Prompt enhancement completed\n") == "Prompt enhancement completed\n", "log language follows interface")
        try expect(L10n.english("Missing %@", ["loguru"]) == "Missing loguru", "diagnostic not English")
        let path = "/fixture/模型 folder/model.gguf"
        try expect(L10n.text("Choose %@.", [path]).contains(path), "localization changed a user path")
    }
    L10n.languageCode = "ja"
    try expect(L10n.render("Missing huggingface_hub") == "huggingface_hubがありません", "persisted dynamic error did not switch language")
    try expect(L10n.text("Image %@: %@", ["1", "Ready"]).contains("Ready"), "localization translated a user filename")
    L10n.languageCode = "de"
    try expect(L10n.text("No translation for this identifier") == "No translation for this identifier", "English fallback failed")
    try expect(L10n.resolve(["it-IT", "fr-CA"]) == "fr", "system language matching failed")
    try expect(L10n.resolve(["zh-TW"]) == "zh-Hans" && L10n.resolve(["pt-BR"]) == "pt", "language family matching failed")
    try expect(L10n.resolve(["it-IT"]) == "en", "unsupported system language did not fall back")
    L10n.languageCode = "unsupported"
    try expect(L10n.languageCode == "en", "invalid stored language did not fall back")
    print("PASS nine language catalogs, placeholders, live status translation, system matching and English diagnostics")
}
