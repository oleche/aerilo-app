import SwiftUI
import WidgetKit

struct StatusEntry: TimelineEntry {
    let date: Date
    let reading: StatusReading
}

/// Reads the device when the system asks, and asks to be called again in fifteen minutes. The
/// widget never cleans anything; tapping it opens Aerilo.
struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: .now, reading: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: .now, reading: context.isPreview ? .sample : .now()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let entry = StatusEntry(date: .now, reading: .now())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct AeriloStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AeriloStatus", provider: StatusProvider()) { entry in
            StatusWidgetView(reading: entry.reading)
                .containerBackground(for: .widget) { WidgetSky() }
        }
        .configurationDisplayName("Aerilo")
        #if os(macOS)
        .description("Your Mac's health, memory and free storage at a glance.")
        #else
        .description("Free storage and memory in use at a glance.")
        #endif
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct AeriloWidgets: WidgetBundle {
    var body: some Widget {
        AeriloStatusWidget()
    }
}
