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

struct InspectorWidthFixture: View {
    let progress: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Text("模型准备").frame(maxWidth: .infinity, alignment: .leading).frame(height: 58)
            ClippedReveal(progress: progress) {
                VStack(spacing: 12) {
                    ForEach(0..<3) { _ in
                        TextField("模型文件夹", text: .constant("/workspace/models/model"))
                            .frame(height: 110).frame(maxWidth: .infinity)
                    }
                }
            }
            Text("生成参数").frame(maxWidth: .infinity, alignment: .leading).frame(height: 58)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

MainActor.assumeIsolated {
    let scroll = NativeInspectorScrollView(content: InspectorWidthFixture(progress: 0))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 300),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = scroll
    defer { window.contentView = nil }
    for width: CGFloat in [280, 240, 280] {
        window.setContentSize(NSSize(width: width, height: 300))
        for progress: CGFloat in [0, 0.2, 0.6, 1, 0.3, 0.7, 0] {
            // Simulate AppKit applying the Always preference during a disclosure.
            scroll.scrollerStyle = .legacy
            scroll.host.rootView = InspectorWidthFixture(progress: progress)
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            scroll.layoutSubtreeIfNeeded()
            check(scroll.scrollerStyle == .overlay && scroll.verticalScroller is SubtleScroller,
                  "inspector keeps its overlay scroller at progress \(progress)")
            check(abs(scroll.contentView.bounds.width - width) < 0.5 && abs(scroll.host.frame.width - width) < 0.5,
                  "inspector viewport and document retain width \(Int(width)) through disclosure")
            check(progress == 0 ? scroll.host.frame.height < 300 : progress == 1 ? scroll.host.frame.height > 300 : true,
                  "inspector document resizes naturally across the overflow threshold")
        }
    }
    scroll.host.rootView = InspectorWidthFixture(progress: 1)
    RunLoop.current.run(until: Date().addingTimeInterval(0.04))
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 100)); scroll.reflectScrolledClipView(scroll.contentView)
    check(scroll.contentView.bounds.origin.y > 90, "inspector scrolls without a reserved gutter")
    scroll.scrollToTop()
    check(abs(scroll.contentView.bounds.origin.y) < 0.5, "model preparation focus returns to the top")
}
print("Inspector stable-width scrolling checks passed")
