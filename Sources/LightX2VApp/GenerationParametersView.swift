import SwiftUI
import LightX2VCore

struct GenerationParametersView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("画面尺寸")
            Picker("分辨率", selection: Binding(
                get: { store.generationSize.resolution },
                set: { store.generationSize.selectResolution($0) }
            )) {
                Text("1K").tag(ImageResolution.oneK)
                Text("2K").tag(ImageResolution.twoK)
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel("分辨率")
            .help("切换 1K / 2K 并保留画面比例")

            label("画面比例").padding(.top, 3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                AspectRatioButton(ratio: nil, resolution: store.generationSize.resolution,
                                  selected: store.generationSize.aspectRatio == nil) {
                    store.generationSize.selectAspectRatio(nil)
                }
                ForEach(ImageAspectRatio.allCases) { ratio in
                    AspectRatioButton(ratio: ratio, resolution: store.generationSize.resolution,
                                      selected: store.generationSize.aspectRatio == ratio) {
                        store.generationSize.selectAspectRatio(ratio)
                    }
                }
            }

            HStack(spacing: 8) {
                label("输出尺寸")
                Spacer(minLength: 0)
                if let dimensions = store.generationSize.dimensions {
                    Text("\(String(dimensions.width)) × \(String(dimensions.height))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text("px").font(.system(size: 9)).foregroundStyle(Palette.muted)
                } else {
                    Text(automaticSizeDescription).font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("输出尺寸")
            .accessibilityValue(store.generationSize.dimensions.map { "宽 \($0.width)，高 \($0.height) 像素" } ?? automaticSizeDescription)
        }
    }

    private var automaticSizeDescription: String {
        switch store.inputImages.count {
        case 0: return "无参考图时为 1:1"
        case 1: return "跟随参考图"
        default: return "跟随最后一张参考图"
        }
    }

    private func label(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
    }
}

private struct AspectRatioButton: View {
    let ratio: ImageAspectRatio?
    let resolution: ImageResolution
    let selected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    @FocusState private var focused: Bool

    private var title: String { ratio?.rawValue ?? "自适应" }
    private var sizeDescription: String {
        guard let dimensions = ratio?.dimensions(at: resolution) else { return "由参考图确定比例，无参考图时为 1:1" }
        return "\(dimensions.width) × \(dimensions.height) 像素"
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                if let ratio {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(selected ? Palette.accent.opacity(0.14) : Palette.muted.opacity(0.07))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(lineWidth: 1.2))
                        .frame(width: ratio.ratio >= 1 ? 22 : 22 * ratio.ratio,
                               height: ratio.ratio >= 1 ? 22 / ratio.ratio : 22)
                        .frame(height: 22)
                } else {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 16, weight: .regular)).frame(height: 22)
                }
                Text(title).font(.system(size: 10, weight: selected ? .semibold : .medium)).monospacedDigit()
            }
            .foregroundStyle(selected ? Palette.accent : Palette.muted)
            .frame(maxWidth: .infinity).frame(height: 60)
            .background(selected ? Palette.accentSurface : hovered ? Palette.hover : Palette.surface,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Palette.accent : selected ? Palette.accent.opacity(0.65) : hovered ? Palette.borderStrong : Palette.line,
                              lineWidth: focused ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Circle().fill(Palette.accent).frame(width: 4, height: 4).padding(5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(.space) { guard enabled else { return .ignored }; action(); return .handled }
        .onHover { hovered = $0 && enabled }
        .onChange(of: enabled) { _, value in if !value { hovered = false } }
        .animation(InteractionMotion.hover(reduced: reduceMotion), value: hovered)
        .animation(InteractionMotion.hover(reduced: reduceMotion), value: selected)
        .help("\(resolution.rawValue) · \(sizeDescription)")
        .accessibilityLabel("画面比例 \(title)")
        .accessibilityValue(sizeDescription)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
