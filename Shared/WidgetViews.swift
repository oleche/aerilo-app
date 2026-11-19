#if canImport(WidgetKit) && !os(tvOS)
import SwiftUI
import WidgetKit

/// What the widget shows. On a Mac: the health score with memory and storage. On iPhone and iPad:
/// free storage with memory in use. Read by the widget itself, so it needs nothing from the app.
struct StatusReading {
    struct Line: Identifiable {
        let label: String
        let value: String
        let fraction: Double
        var id: String { label }
    }
    var word: String
    var value: String
    var unit: String
    var lines: [Line]

    static let sample = StatusReading(word: "Steady", value: "71", unit: "of 100", lines: [
        Line(label: "Memory", value: "62%", fraction: 0.62), Line(label: "Storage", value: "81 GB free", fraction: 0.84),
    ])

    static func now() -> StatusReading {
        #if os(macOS)
        let s = SystemProbe().read()
        return StatusReading(word: s.healthWord, value: "\(s.health)", unit: "of 100", lines: [
            Line(label: "Memory", value: "\(Int(s.memFraction * 100))%", fraction: s.memFraction),
            Line(label: "Storage", value: "\(Fmt.bytes(s.diskFree)) free", fraction: 1 - s.diskFreeFraction),
        ])
        #else
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let used = total > 0 ? 1 - Double(free) / Double(total) : 0
        let memory = DeviceLoad.memoryFraction() ?? 0
        let gigabytes = Measurement(value: Double(free), unit: UnitInformationStorage.bytes).converted(to: .gigabytes).value
        return StatusReading(word: used > 0.9 ? "Nearly full" : used > 0.75 ? "Filling up" : "Room to breathe",
                             value: gigabytes >= 10 ? String(format: "%.0f", gigabytes) : String(format: "%.1f", gigabytes), unit: "GB free", lines: [
            Line(label: "Storage used", value: "\(Int(used * 100))%", fraction: used),
            Line(label: "Memory", value: "\(Int(memory * 100))%", fraction: memory),
        ])
        #endif
    }
}

/// The widget's sky: the app's colours, with ripples from one corner.
struct WidgetSky: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(colors: scheme == .dark ? [Color(hex: 0x2A2A5C), Color(hex: 0x3B2152), Color(hex: 0x14324A)]
                                                   : [Color(hex: 0xF9C9DA), Color(hex: 0xFFE7D6), Color(hex: 0xC9DDF7)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { geo in
                ForEach(0..<4, id: \.self) { ring in
                    Circle().stroke(.white.opacity(scheme == .dark ? 0.10 : 0.45 - Double(ring) * 0.08), lineWidth: 1.5)
                        .frame(width: geo.size.height * (0.9 + CGFloat(ring) * 0.55), height: geo.size.height * (0.9 + CGFloat(ring) * 0.55))
                        .position(x: geo.size.width, y: 0)
                }
            }
        }
    }
}

struct StatusWidgetView: View {
    let reading: StatusReading
    /// Set only when the view is shown outside a widget, for previews.
    var preview: WidgetFamily?
    @Environment(\.widgetFamily) private var systemFamily
    private var family: WidgetFamily { preview ?? systemFamily }

    var body: some View {
        if family == .systemSmall {
            VStack(alignment: .leading, spacing: 0) {
                heading
                Spacer(minLength: 2)
                number
                Text(reading.word).font(.system(.caption, design: .rounded, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if let line = reading.lines.first { meter(line) }
            }
        } else {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    Spacer(minLength: 2)
                    number
                    Text(reading.word).font(.system(.caption, design: .rounded, weight: .semibold)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(reading.lines) { meter($0) }
                    Text("Tap to open Aerilo and breathe").font(.system(.caption2, design: .rounded)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var heading: some View {
        Label("Aerilo", systemImage: "wind").font(.system(.caption, design: .rounded, weight: .semibold)).foregroundStyle(.secondary)
    }

    private var number: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(reading.value).font(.system(size: 38, weight: .medium, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
            Text(reading.unit).font(.system(.caption, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func meter(_ line: StatusReading.Line) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(line.label).font(.system(.caption2, design: .rounded))
                Spacer(minLength: 4)
                Text(line.value).font(.system(.caption2, design: .rounded, weight: .semibold)).monospacedDigit()
            }
            Meter(fraction: line.fraction, tint: line.fraction > 0.85 ? .orange : .accentColor)
        }
    }
}
#endif
