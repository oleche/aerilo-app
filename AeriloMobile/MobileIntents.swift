import AppIntents
import Foundation

#if os(iOS) || os(visionOS)
/// "Tidy my photos with Aerilo": opens the app and starts a look through the library. Siri,
/// Spotlight and Shortcuts can all run it; nothing is deleted from here.
struct TidyPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Tidy My Photos"
    static let description = IntentDescription("Opens Aerilo and looks through your photo library for duplicates, similar shots, old screenshots and large videos. You review before anything is deleted.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Task { await PhotoModel.shared.breathe() }
        return .result()
    }
}

/// "How much storage is free": answered without opening the app.
struct FreeStorageIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Free Storage"
    static let description = IntentDescription("Says how much storage is free on this device.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        return .result(dialog: "\(Fmt.bytes(free)) is free of \(Fmt.bytes(total)). Open Aerilo to see what could go.")
    }
}

struct AeriloMobileShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TidyPhotosIntent(), phrases: ["Tidy my photos with \(.applicationName)", "Breathe with \(.applicationName)"],
                    shortTitle: "Tidy Photos", systemImageName: "wind")
        AppShortcut(intent: FreeStorageIntent(), phrases: ["How much storage is free in \(.applicationName)", "Check storage with \(.applicationName)"],
                    shortTitle: "Free Storage", systemImageName: "internaldrive")
    }
}
#endif
