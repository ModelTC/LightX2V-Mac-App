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
            .help("切换 1K / 2K 并保留画面比例；自定义尺寸会匹配最接近的比例预设")

            HStack {
                label("画面比例")
                Spacer()
                if store.generationSize.aspectRatio == nil {
                    Text("自定义").font(.system(size: 10)).foregroundStyle(Palette.accent)
                }
            }.padding(.top, 3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(ImageAspectRatio.allCases) { ratio in
                    AspectRatioButton(ratio: ratio, resolution: store.generationSize.resolution,
                                      selected: store.generationSize.aspectRatio == ratio) {
                        store.generationSize.selectAspectRatio(ratio)
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                DimensionField(title: "宽", value: $store.width)
                Button { store.generationSize.swapOrientation() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                        .frame(width: 24, height: 35).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(store.width == store.height)
                    .help("交换宽高").accessibilityLabel("交换宽高")
                DimensionField(title: "高", value: $store.height)
            }
            if !store.generationSize.dimensions.isValid {
                Text(ImageDimensions.validationMessage)
                    .font(.system(size: 10)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func label(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
    }
}

private struct AspectRatioButton: View {
    let ratio: ImageAspectRatio
    let resolution: ImageResolution
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    private var dimensions: ImageDimensions { ratio.dimensions(at: resolution) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(selected ? Palette.accent.opacity(0.14) : Palette.muted.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(lineWidth: 1.2))
                    .frame(width: ratio.ratio >= 1 ? 22 : 22 * ratio.ratio,
                           height: ratio.ratio >= 1 ? 22 / ratio.ratio : 22)
                    .frame(height: 22)
                Text(ratio.rawValue).font(.system(size: 10, weight: selected ? .semibold : .medium)).monospacedDigit()
            }
            .foregroundStyle(selected ? Palette.accent : Palette.ink.opacity(0.7))
            .frame(maxWidth: .infinity).frame(height: 60)
            .background(selected ? Palette.accent.opacity(0.07) : hovered ? Color.white : Color.white.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Palette.accent : selected ? Palette.accent.opacity(0.6) : hovered ? Palette.muted.opacity(0.4) : Palette.line,
                              lineWidth: focused ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Circle().fill(Palette.accent).frame(width: 4, height: 4).padding(5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).focusable().focused($focused)
        .onKeyPress(.space) { action(); return .handled }
        .onHover { hovered = $0 }
        .help("\(resolution.rawValue) · \(dimensions.width) × \(dimensions.height) 像素")
        .accessibilityLabel("画面比例 \(ratio.rawValue)")
        .accessibilityValue("\(dimensions.width) × \(dimensions.height) 像素")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct DimensionField: View {
    let title: String
    @Binding var value: Int
    @State private var text: String

    init(title: String, value: Binding<Int>) {
        self.title = title
        _value = value
        _text = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(Palette.muted)
            HStack(spacing: 3) {
                TextField(title, text: Binding(get: { text }, set: {
                    text = $0
                    // Invalid drafts must disable generation, never reuse a stale number.
                    value = Int($0) ?? 0
                }))
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .accessibilityLabel(title == "宽" ? "图片宽度" : "图片高度")
                    .dismissEditingOnOutsideClick()
                    .onChange(of: value) { _, newValue in
                        if (Int(text) ?? 0) != newValue { text = String(newValue) }
                    }
                Text("px").font(.system(size: 9)).foregroundStyle(Palette.muted).accessibilityHidden(true)
            }.padding(.horizontal, 10).frame(height: 35)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
        }
    }
}
