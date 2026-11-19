import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The slow pastel sky behind everything. Liquid Glass needs colour underneath to refract.
struct Aurora: View {
    @Environment(\.colorScheme) private var scheme
    /// 0 calm, 1 fully released: the sky brightens as the Mac lets go.
    var lift: Double = 0

    private var colors: [Color] {
        scheme == .dark
            ? [0x1A1B3D, 0x3B2152, 0x5A2B4F,
               0x14324A, 0x2A2A5C, 0x4A2A55,
               0x0F1B33, 0x16404F, 0x2B2550].map { Color(hex: $0) }
            : [0xF9C9DA, 0xFFDCC4, 0xFFF1E3,
               0xD9CFF8, 0xFBE3EE, 0xFFD3C2,
               0xB9DDF7, 0xC9EFE6, 0xCFC8F6].map { Color(hex: $0) }
    }

    var body: some View {
        // Still on purpose: a moving sky would make every glass surface re-render all the time,
        // and an app that keeps a Mac calm should not keep its processor busy.
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.56, 0], [1, 0],
            [0, 0.44], [0.46, 0.54], [1, 0.58],
            [0, 1], [0.42, 1], [1, 1],
        ], colors: colors)
        .overlay(Color.white.opacity(scheme == .dark ? 0.05 * lift : 0.22 * lift))
        .ignoresSafeArea()
    }
}

extension View {
    /// Liquid Glass where the system has it. Vision Pro has its own glass material instead.
    @ViewBuilder
    func aeriloGlass(in shape: some InsettableShape, interactive: Bool = false) -> some View {
        #if os(visionOS)
        self.glassBackgroundEffect(in: shape)
        #else
        self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        #endif
    }

    /// The main action of a screen.
    @ViewBuilder
    func prominentButton() -> some View {
        #if os(visionOS)
        self.buttonStyle(.borderedProminent)
        #else
        self.buttonStyle(.glassProminent)
        #endif
    }

    /// A second, quieter action beside the main one.
    @ViewBuilder
    func quietButton() -> some View {
        #if os(visionOS)
        self.buttonStyle(.bordered)
        #else
        self.buttonStyle(.glass)
        #endif
    }

    /// A Liquid Glass panel for a group of content.
    func glassCard(radius: CGFloat = 26, padding: CGFloat = 18) -> some View {
        self.padding(padding).aeriloGlass(in: .rect(cornerRadius: radius))
    }
}

struct Chip: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(.callout, design: .rounded, weight: .semibold)).monospacedDigit()
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .aeriloGlass(in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

struct Badge: View {
    let text: String
    var color: Color = .orange

    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
    }
}

/// A thin capsule meter, used for memory and storage shares.
struct Meter: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(tint.gradient).frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}
