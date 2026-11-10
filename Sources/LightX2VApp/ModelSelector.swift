import SwiftUI
import LightX2VCore

struct ModelSelector: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject var store: AppStore
    @State private var showsModels = false
    @FocusState private var focused: Bool

    var body: some View {
        Button { showsModels.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "cube.transparent")
                Text(store.selectedModel?.selectorTitle ?? L10n.text("Choose model"))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .frame(width: 230, height: 30)
            .padding(.horizontal, 8)
            .foregroundStyle(store.selectedModel == nil ? Palette.accent : Palette.ink)
            .background(store.selectedModel == nil ? Palette.accentSurface : Palette.surfaceSubtle,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                if store.selectedModel == nil { ModelSelectionRing() }
            }
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(focused ? Palette.borderStrong : .clear, lineWidth: 1))
        }
        .buttonStyle(HoverButtonStyle(radius: 7))
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(.space) {
            guard !store.busy else { return .ignored }
            showsModels.toggle()
            return .handled
        }
        .popover(isPresented: $showsModels, arrowEdge: .top) {
            ModelFamilyPicker(selectedModel: store.selectedModel) { model in
                store.selectModel(model)
                showsModels = false
            }
        }
        .onChange(of: store.busy) { _, busy in if busy { showsModels = false } }
        .disabled(store.busy)
        .help(L10n.text("Choose generation model"))
        .accessibilityLabel(L10n.text("Choose model"))
        .accessibilityValue(store.selectedModel?.selectorTitle ?? L10n.text("Not selected"))
        .accessibilityIdentifier("model-selector")
    }
}

private struct ModelFamilyPicker: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let selectedModel: GenerationModel?
    let select: (GenerationModel) -> Void
    @State private var showsVariants = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Choose model"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 9)
            Button { showsVariants = true } label: {
                HStack(spacing: 10) {
                    Text(selectedModel?.selectorTitle ?? QwenImage21Turbo.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "checkmark")
                        .opacity(selectedModel == nil ? 0 : 1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
                }
                .padding(9)
                .background(showsVariants ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focused ? Palette.borderStrong : .clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(HoverButtonStyle(radius: 7))
            .focusable().focusEffectDisabled().focused($focused)
            .onHover { inside in if inside { showsVariants = true } }
            .onKeyPress(.rightArrow) { showsVariants = true; return .handled }
            .onKeyPress(.space) { showsVariants = true; return .handled }
            .popover(isPresented: $showsVariants, arrowEdge: .trailing) {
                ModelVariantPicker(selectedModel: selectedModel, select: select)
            }
            .accessibilityLabel(selectedModel?.selectorTitle ?? QwenImage21Turbo.title)
            .accessibilityValue(L10n.text("Model variants"))
            .accessibilityIdentifier("model-family-qwen-image-21-turbo")
        }
        .padding(10).frame(width: 276)
        .foregroundStyle(Palette.ink).background(Palette.surface)
        .defaultFocus($focused, true, priority: .userInitiated)
        .onDisappear { showsVariants = false }
    }
}

private struct ModelVariantPicker: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let selectedModel: GenerationModel?
    let select: (GenerationModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(QwenImage21Turbo.title).font(.system(size: 13, weight: .medium))
            HStack(spacing: 4) {
                ForEach(GenerationModel.allCases) { model in
                    ModelVariantButton(model: model, selected: selectedModel == model) { select(model) }
                }
            }
            .padding(4)
            .background(Palette.selection, in: Capsule())
        }
        .padding(16).frame(width: 302)
        .foregroundStyle(Palette.ink).background(Palette.surface)
    }
}

private struct ModelVariantButton: View {
    let model: GenerationModel
    let selected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(model.variantLabel)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "checkmark").font(.system(size: 10, weight: .medium))
                    .opacity(selected ? 1 : 0)
            }
            .frame(maxWidth: .infinity).frame(height: 32)
            .foregroundStyle(selected ? Palette.ink : Palette.muted)
            .background(selected ? Palette.surface : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(focused ? Palette.borderStrong : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(HoverButtonStyle(radius: 16))
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(.space) { action(); return .handled }
        .help(model.title)
        .accessibilityLabel(model.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("model-variant-" + model.id)
    }
}

private extension GenerationModel {
    var variantLabel: String { self == .qwenImage21Turbo ? L10n.text("Standard") : "INT8" }
    var selectorTitle: String { QwenImage21Turbo.title + "·" + variantLabel }
}

/// A quiet breathing outline draws attention without changing layout or hit areas.
private struct ModelSelectionRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Palette.accent.opacity(reduceMotion ? 0.8 : bright ? 0.9 : 0.35), lineWidth: 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: bright)
            .onAppear { bright = true }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
