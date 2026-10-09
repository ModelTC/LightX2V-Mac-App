import AppKit
import SwiftUI

// Render the production reveal at intermediate animation values, including
// reversals. Distinct colors expose even a single row bleeding into a title.
let app = NSApplication.shared
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL \(message)\n", stderr); exit(1) }
    print("PASS \(message)")
}

@MainActor func render(progress: CGFloat, height: CGFloat, width: CGFloat) -> NSBitmapImageRep {
    let view = VStack(spacing: 0) {
        Color.white.frame(height: 28)
        Color(.sRGB, red: 1, green: 0, blue: 0).frame(height: 36)
        ClippedReveal(progress: progress) {
            Color(.sRGB, red: 0, green: 1, blue: 0).frame(height: height)
        }
        Color(.sRGB, red: 0, green: 0, blue: 1).frame(height: 36)
        ClippedReveal(progress: progress) {
            Color.purple.frame(height: 90)
        }
        Spacer(minLength: 0)
    }.frame(width: width, height: 600, alignment: .top).background(Color.white)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let image = renderer.cgImage else { fatalError("Could not render disclosure fixture") }
    return NSBitmapImageRep(cgImage: image)
}

@MainActor func runChecks() {
    for width: CGFloat in [200, 240] {
        for height: CGFloat in [120, 240] {
            for progress: CGFloat in [0, 0.05, 0.25, 0.5, 0.8, 1, 0.7, 0.2, 0.6, 0] {
                let bitmap = render(progress: progress, height: height, width: width)
                let bottom = 64 + height * progress
                var headerCorrect = true
                var nextHeaderCorrect = true
                var contained = true
                var visibleRows = 0
                for y in 0..<bitmap.pixelsHigh {
                    let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)!.usingColorSpace(.sRGB)!
                    let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                    if (29..<63).contains(y) && !(r > 0.9 && g < 0.25 && b < 0.25) {
                        headerCorrect = false
                    }
                    if CGFloat(y) > bottom + 1 && CGFloat(y) < bottom + 34,
                       !(b > 0.9 && r < 0.25 && g < 0.25) {
                        nextHeaderCorrect = false
                    }
                    if g > r + 0.02 && g > b + 0.02 {
                        visibleRows += 1
                        if y < 64 || CGFloat(y) >= ceil(bottom) { contained = false }
                    }
                }
                let label = "reveal \(Int(width))×\(Int(height)), progress \(progress)"
                check(headerCorrect && nextHeaderCorrect && contained, "\(label): neither title is overdrawn")
                check(progress == 0 ? visibleRows == 0 : abs(CGFloat(visibleRows) - height * progress) <= 1,
                      "\(label): natural-height content is clipped to the visible region")
            }
        }
    }
}
MainActor.assumeIsolated { runChecks() }
print("Inspector disclosure checks passed")
