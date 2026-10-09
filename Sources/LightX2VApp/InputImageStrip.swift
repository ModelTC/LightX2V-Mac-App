import AppKit
import SwiftUI
import LightX2VCore

struct InputImageStrip: View {
    let images: [InputImage]
    var remove: ((InputImage) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                    InputThumbnail(image: image)
                        .frame(width: 72, height: 72)
                        .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line, lineWidth: 1))
                        .overlay(alignment: .bottomLeading) {
                            Text("\(index + 1)").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.black.opacity(0.55), in: Capsule()).padding(5)
                        }
                        .overlay(alignment: .topTrailing) {
                            if let remove {
                                Button { remove(image) } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                                        .frame(width: 20, height: 20).background(Palette.surface, in: Circle())
                                        .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
                                }.buttonStyle(HoverButtonStyle(radius: 10)).padding(4)
                                    .accessibilityLabel("移除图片 \(index + 1)")
                            }
                        }
                        .help(image.name)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("图片 \(index + 1)：\(image.name)")
                        .onDrag { NSItemProvider(object: URL(fileURLWithPath: image.path) as NSURL) }
                }
            }.padding(.vertical, 2)
        }.frame(height: 76)
            .onHover { if $0 { NSCursor.arrow.set() } }
    }
}

private struct InputThumbnail: View {
    let image: InputImage
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(Palette.muted) }
        }.task(id: image.path) {
            thumbnail = nil
            let loaded = await LocalImagePreview.load(image.path, maximumDimension: 180)
            if !Task.isCancelled { thumbnail = loaded }
        }
    }
}
