import SwiftUI
import LightX2VCore

struct GenerationParametersView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            label(L10n.text("Image size"))
            Picker(L10n.text("Resolution"), selection: Binding(
                get: { store.generationSize.resolution },
                set: { store.generationSize.selectResolution($0) }
            )) {
                Text("1K").tag(ImageResolution.oneK)
                Text("2K").tag(ImageResolution.twoK)
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel(L10n.text("Resolution"))
            .help(L10n.text("Switch between 1K and 2K while preserving aspect ratio"))

            label(L10n.text("Aspect ratio")).padding(.top, 3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                AspectRatioButton(ratio: nil, resolution: store.generationSize.resolution,
                                  selected: store.generationSize.aspectRatio == nil,
                                  enhancementEnabled: store.settings.promptEnhancement.enabled) {
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
                label(L10n.text("Output size"))
                Spacer(minLength: 0)
                if let dimensions = store.generationSize.dimensions {
                    Text("\(String(dimensions.width)) × \(String(dimensions.height))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text("px").font(.system(size: 9)).foregroundStyle(Palette.muted)
                } else {
                    Text(L10n.text("Automatic")).font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Output size"))
            .accessibilityValue(store.generationSize.dimensions.map { L10n.text("Width %@, height %@ pixels", [String(describing: $0.width), String(describing: $0.height)]) } ?? L10n.text("Automatic"))
        }
    }

    private func label(_ title: String) -> some View {
        Text(L10n.render(title)).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
    }
}

private struct AspectRatioButton: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let ratio: ImageAspectRatio?
    let resolution: ImageResolution
    let selected: Bool
    var enhancementEnabled = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    @FocusState private var focused: Bool

    private var title: String { ratio?.rawValue ?? L10n.text("Adaptive") }
    private var sizeDescription: String {
        guard let dimensions = ratio?.dimensions(at: resolution) else {
            return enhancementEnabled ? L10n.text("Determine aspect ratio from the enhanced prompt") : L10n.text("Chosen by the model; 1:1 without reference images")
        }
        return L10n.text("%@ × %@ pixels", [String(describing: dimensions.width), String(describing: dimensions.height)])
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
                Text(L10n.render(title)).font(.system(size: 10, weight: selected ? .semibold : .medium)).monospacedDigit()
            }
            .foregroundStyle(selected ? Palette.accent : Palette.muted)
            .frame(maxWidth: .infinity).frame(height: 60)
            .background(selected ? Palette.accentSurface : hovered ? Palette.hover : Palette.surface,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Palette.accent.opacity(0.65) : (hovered || focused) ? Palette.borderStrong : Palette.line,
                              lineWidth: 1))
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
        .accessibilityLabel(L10n.text("Aspect ratio %@", [String(describing: title)]))
        .accessibilityValue(sizeDescription)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
