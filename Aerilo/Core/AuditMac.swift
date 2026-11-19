import AppKit

extension Audit {
    @MainActor static func export() {
        let panel = NSSavePanel()
        let name = DateFormatter()
        name.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Aerilo activity \(name.string(from: Date())).txt"
        panel.message = "The report lists what Aerilo measured, cleared and skipped. It contains app and folder names from this Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report().write(to: url, atomically: true, encoding: .utf8)
        record("log.export")
    }

    @MainActor static func reveal() {
        if !FileManager.default.fileExists(atPath: fileURL.path) { try? Data().write(to: fileURL) }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
