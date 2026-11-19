import SwiftUI

/// Photo tidying on the Mac: the same engine as the iPhone edition, started with its own button.
/// It is not part of Breathe, so the one tap never asks for the photo library.
struct PhotosView: View {
    @State private var model = PhotoModel.shared
    @State private var kind: PhotoKind?

    var body: some View {
        let working = model.phase == .inhale || model.phase == .exhale
        Group {
            if let kind {
                VStack(spacing: 0) {
                    HStack {
                        Button { self.kind = nil } label: { Label("Photos", systemImage: "chevron.left") }.buttonStyle(.glass)
                        Text(kind.title).font(.system(.title2, design: .rounded, weight: .semibold)).padding(.leading, 6)
                        Spacer()
                    }
                    .padding(.horizontal, 28).padding(.top, 8)
                    PhotoReview(kind: kind)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Photos").font(.system(size: 28, weight: .semibold, design: .rounded))
                            Text("Duplicates, similar shots, old screenshots and large videos in your Photos library. Aerilo compares them on this Mac and deletes nothing until you review it.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(working ? (model.steps.last ?? "Looking through your library") : model.phase == .done ? model.headline : "Look through your Photos library")
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                if model.assetCount > 0 {
                                    Text("\(model.assetCount.formatted()) photos and videos").font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if working { ProgressView().controlSize(.small) }
                            Button(model.phase == .done ? "Look Again" : "Look Through Photos") { Task { await model.breathe() } }
                                .buttonStyle(.glassProminent).disabled(working)
                        }
                        .glassCard()

                        if model.phase == .done, model.access == .denied {
                            Label("Aerilo isn't allowed to see Photos. Allow it in System Settings › Privacy & Security › Photos.", systemImage: "lock")
                                .foregroundStyle(.secondary).glassCard()
                        } else if !model.groups.isEmpty {
                            PhotoSummary { kind = $0 }
                            if model.lastFreed > 0 {
                                Text("Moved \(Fmt.items(model.lastDeleted)) (\(Fmt.bytes(model.lastFreed))) to Recently Deleted.").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
            }
        }
        .environment(model)
    }
}
