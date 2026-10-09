import SwiftUI

/// Icon, text and padding form one editable target. The adjacent chooser stays
/// outside this view so it retains its own arrow cursor and button feedback.
struct PathInputField: View {
    let title: String
    let placeholder: String
    let symbol: String
    @Binding var text: String
    var onCommit: () -> Void = {}
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(Palette.muted).font(.system(size: 12))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.system(size: 11))
                .accessibilityLabel(title).help(text)
                .focused($focused)
                .onSubmit(onCommit)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .simultaneousGesture(TapGesture().onEnded { if enabled { focused = true } })
        .inputHoverSurface(hovered: hovered)
        .background(OutsideClickObserver(isEditing: focused, isEnabled: enabled,
                                        onHoverChange: { hovered = $0 }, cornerRadius: 8))
        .onChange(of: focused) { wasFocused, isFocused in
            if wasFocused && !isFocused { onCommit() }
        }
    }
}
