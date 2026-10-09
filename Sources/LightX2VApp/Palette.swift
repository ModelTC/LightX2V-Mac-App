import SwiftUI

/// Neutral light surfaces, with color reserved for selection and status.
enum Palette {
    static let canvas = hex(0xFFFFFF)
    static let sidebar = hex(0xF8F8F7)
    static let inspector = hex(0xFAFAFA)
    static let surface = hex(0xFFFFFF)
    static let surfaceSubtle = hex(0xF5F5F5)
    static let selection = hex(0xEEEEEE)
    static let hover = hex(0xF0F0F0)
    static let ink = hex(0x242424)
    static let muted = hex(0x6B6B6B)
    static let line = hex(0xE5E5E5)
    static let borderStrong = hex(0xBDBDBD)
    static let focus = hex(0x9A9A9A)
    static let button = hex(0x151515)
    static let onButton = hex(0xFFFFFF)
    static let disabledFill = hex(0xE8E8E8)
    static let disabledInk = hex(0x8A8A8A)
    static let prompt = hex(0x151515)
    static let onPrompt = hex(0xFAFAFA)
    static let accent = hex(0xA45145)
    static let accentSurface = hex(0xF7EEEC)
    static let green = hex(0x47755D)

    private static func hex(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255, opacity: 1)
    }
}
