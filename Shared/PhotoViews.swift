import Photos
import SwiftUI

/// One picture from the library, or a drawn sample in demo mode.
struct PhotoThumb: View {
    let item: PhotoItem
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if item.id.hasPrefix("demo-") {
                SamplePicture(seed: item.seed)
            } else if let image {
                Image(platform: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.primary.opacity(0.08))
            }
        }
        .task(id: item.id) {
            guard !item.id.hasPrefix("demo-"), image == nil else { return }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject else { return }
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 360, height: 360), contentMode: .aspectFill, options: options) { result, _ in
                if let result { Task { @MainActor in image = result } }
            }
        }
    }
}

/// A small drawn landscape, so screenshots never show anyone's real photos.
struct SamplePicture: View {
    let seed: Int

    private func unit(_ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ salt &* 40_503) &+ 0x9E37_79B9
        x ^= x >> 15; x &*= 0x2C1B_3C6D
        x ^= x >> 12; x &*= 0x297A_2D39
        x ^= x >> 15
        return Double(x % 1000) / 1000
    }

    var body: some View {
        Canvas { context, size in
            let hue = unit(1)
            let sky = Gradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.98),
                                        Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.25, brightness: 1)])
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(sky, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let sun = CGPoint(x: size.width * (0.2 + unit(2) * 0.6), y: size.height * (0.2 + unit(3) * 0.25))
            let r = size.width * (0.08 + unit(4) * 0.06)
            context.fill(Path(ellipseIn: CGRect(x: sun.x - r, y: sun.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.9)))
            for layer in 0..<3 {
                var hill = Path()
                let base = size.height * (0.55 + Double(layer) * 0.14)
                hill.move(to: CGPoint(x: 0, y: size.height))
                hill.addLine(to: CGPoint(x: 0, y: base))
                for step in 0...8 {
                    let x = size.width * Double(step) / 8
                    let y = base - sin(Double(step) * (0.7 + unit(5 + layer)) + unit(8 + layer) * 6) * size.height * 0.07
                    hill.addLine(to: CGPoint(x: x, y: y))
                }
                hill.addLine(to: CGPoint(x: size.width, y: size.height))
                hill.closeSubpath()
                context.fill(hill, with: .color(Color(hue: (hue + 0.45 + Double(layer) * 0.04).truncatingRemainder(dividingBy: 1),
                                                      saturation: 0.3 + Double(layer) * 0.12, brightness: 0.85 - Double(layer) * 0.14)))
            }
        }
    }
}

// MARK: - Summary

/// One row per kind of thing found, with its count and size.
struct PhotoSummary: View {
    @Environment(PhotoModel.self) private var model
    let open: (PhotoKind) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.kindsFound.enumerated()), id: \.element) { index, kind in
                if index > 0 { Divider().padding(.vertical, 10) }
                Button { open(kind) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: kind.icon).font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title).font(.system(.body, design: .rounded, weight: .semibold))
                            Text("\(Fmt.items(model.items(kind).count)) · \(Fmt.bytes(model.bytes(kind)))").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        let ticked = model.selectedItems(kind).count
                        if ticked > 0 { Badge(text: "\(ticked) suggested", color: .accentColor) }
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .glassCard()
    }
}

// MARK: - Review and delete

/// Everything of one kind, for the user to tick or untick before anything is deleted.
struct PhotoReview: View {
    @Environment(PhotoModel.self) private var model
    let kind: PhotoKind

    private let grid = [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: 6)]

    var body: some View {
        let groups = model.groups.filter { $0.kind == kind }
        let ticked = model.selectedItems(kind)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(kind.note).font(.callout).foregroundStyle(.secondary)
                if groups.isEmpty {
                    Label("Nothing left here.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    LazyVGrid(columns: grid, alignment: .leading, spacing: 6) {
                        ForEach(group.items) { item in tile(item, in: group) }
                    }
                    if group.keepID != nil, group.id != groups.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(ticked.isEmpty ? "Nothing ticked" : "\(ticked.count) ticked · \(Fmt.bytes(ticked.reduce(0) { $0 + $1.bytes }))")
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                    Text("Deleted items stay in Recently Deleted for 30 days.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(role: .destructive) {
                    Task { await model.deleteSelected(in: kind) }
                } label: {
                    Text(model.deleting ? "Deleting…" : "Delete").padding(.horizontal, 8)
                }
                .prominentButton()
                .tint(.red)
                .disabled(ticked.isEmpty || model.deleting)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .aeriloGlass(in: .rect(cornerRadius: 22))
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private func tile(_ item: PhotoItem, in group: PhotoGroup) -> some View {
        let ticked = model.selected.contains(item.id)
        return Button { model.toggle(item.id) } label: {
            // The square comes from an empty view and the picture is laid over it. Sizing the picture itself made a
            // tall one (a screen recording, a screenshot) spill over its neighbours and swallow their taps.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(minWidth: 0, maxWidth: .infinity)
                .overlay { PhotoThumb(item: item) }
                .clipShape(.rect(cornerRadius: 10))
                .contentShape(.rect(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                        .font(.title3).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, ticked ? Color.accentColor : Color.black.opacity(0.25))
                        .padding(6)
                }
                .overlay(alignment: .bottomLeading) {
                    if item.id == group.keepID, !ticked {
                        Text("Keep").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.green, in: .capsule).foregroundStyle(.white).padding(6)
                    } else if item.isVideo {
                        Text(Fmt.bytes(item.bytes)).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: .capsule).foregroundStyle(.white).padding(6)
                    }
                }
                .opacity(ticked ? 0.72 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ticked ? "Ticked for deletion" : item.id == group.keepID ? "Suggested to keep" : "Not ticked")
    }
}
