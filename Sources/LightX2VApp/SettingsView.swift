import SwiftUI
import AppKit
import LightX2VCore

struct InspectorView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorScrollView(focus: store.modelPreparationFocus) {
                InspectorSectionsView().environmentObject(store).preferredColorScheme(.light)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }.padding(.top, 28).padding(.horizontal, 20).background(Palette.inspector)
    }

}

private struct InspectorSectionsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("模型准备", symbol: "cube.transparent", expanded: $store.modelPreparationExpanded)
            separator
            ClippedReveal(progress: store.selectedModel != nil && store.modelPreparationExpanded ? 1 : 0) {
                VStack(spacing: 0) {
                    ModelPreparationView().padding(.vertical, 12)
                    separator
                }
            }.animation(disclosureAnimation, value: store.modelPreparationExpanded)
            sectionHeader("生成参数", symbol: "slider.horizontal.3", expanded: $store.generationParametersExpanded)
            separator
            ClippedReveal(progress: store.selectedModel != nil && store.generationParametersExpanded ? 1 : 0) {
                GenerationParametersView().padding(.top, 16).padding(.bottom, 23)
            }.animation(disclosureAnimation, value: store.generationParametersExpanded)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var disclosureAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.24) }
    private var separator: some View { Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, -20) }

    private func sectionHeader(_ title: String, symbol: String, expanded: Binding<Bool>) -> some View {
        Button {
            expanded.wrappedValue.toggle()
        } label: {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Image(systemName: symbol).foregroundStyle(Palette.muted)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    .animation(disclosureAnimation, value: expanded.wrappedValue)
                    .foregroundStyle(Palette.muted)
            }.frame(height: 58).contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(radius: 8))
        .disabled(store.selectedModel == nil)
        .accessibilityLabel(title)
        .accessibilityValue(expanded.wrappedValue ? "已展开" : "已收起")
    }
}

struct FirstLaunchSetupView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        SettingsView(settings: store.settings)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.03), radius: 20, y: 6)
            .padding(24)
            .frame(minWidth: 688, minHeight: 668)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.sidebar)
            .overlay(alignment: .top) { WindowDragArea(isNativeTitleBar: true).frame(height: 28) }
    }
}

struct PathSettingField: View {
    let title: String
    @Binding var value: String
    let directory: Bool
    var allowsCreatingDirectories = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium))
            HStack(spacing: 8) {
                TextField(title, text: $value).font(.system(size: 11, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(title).help(value)
                    .dismissEditingOnOutsideClick()
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = allowsCreatingDirectories
                    panel.directoryURL = value.isEmpty ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: value).deletingLastPathComponent()
                    if panel.runModal() == .OK, let url = panel.url { value = url.path }
                } label: {
                    Text("选择…")
                }.font(.system(size: 11)).help("选择\(title)").accessibilityLabel("选择\(title)")
            }
        }
    }
}
