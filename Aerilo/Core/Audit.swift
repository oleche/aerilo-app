import AppKit
import CryptoKit
import Foundation

/// The record of everything Aerilo did, for support and for audits.
///
/// One JSON object per line in `~/Library/Logs/Aerilo/audit.jsonl` (inside the app's container in the
/// App Store edition). Every entry carries the SHA-256 of the entry before it, so an entry that is
/// edited or removed afterwards breaks the chain and `verify()` reports it.
enum Audit {
    struct Entry: Identifiable {
        let id: Int
        let time: Date
        let event: String
        let detail: [String: Any]
        let hash: String
        /// False when this entry does not follow from the one before it.
        let intact: Bool
    }

    private static let queue = DispatchQueue(label: "app.aerilo.audit")
    private static var lastHash: String?
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Aerilo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audit.jsonl")
    }()

    static var edition: String { Env.isSandboxed ? "Mac App Store" : "Direct" }
    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private static func digest(time: String, event: String, detail: [String: Any], prev: String) -> String {
        let body: [String: Any] = ["t": time, "event": event, "detail": detail, "prev": prev]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Appends one entry. Values must be JSON types (strings, numbers, booleans, arrays, dictionaries).
    static func record(_ event: String, _ detail: [String: Any] = [:]) {
        guard !Env.isDemo else { return }
        let time = stamp.string(from: Date())
        queue.async {
            let prev = lastHash ?? readLastHash() ?? "start"
            let hash = digest(time: time, event: event, detail: detail, prev: prev)
            let line: [String: Any] = ["t": time, "event": event, "detail": detail, "prev": prev, "hash": hash]
            guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
            lastHash = hash
        }
    }

    private static func readLastHash() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              let last = text.split(separator: "\n").last,
              let obj = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any] else { return nil }
        return obj["hash"] as? String
    }

    /// Every entry, oldest first, each checked against the one before it.
    static func entries(at url: URL = fileURL) -> [Entry] {
        queue.sync {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            var out: [Entry] = []
            var expected = "start"
            for (index, line) in text.split(separator: "\n").enumerated() {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let t = obj["t"] as? String, let event = obj["event"] as? String,
                      let prev = obj["prev"] as? String, let hash = obj["hash"] as? String else {
                    out.append(Entry(id: index, time: .distantPast, event: "unreadable line", detail: [:], hash: "", intact: false))
                    expected = ""
                    continue
                }
                let detail = obj["detail"] as? [String: Any] ?? [:]
                let ok = prev == expected && digest(time: t, event: event, detail: detail, prev: prev) == hash
                out.append(Entry(id: index, time: stamp.date(from: t) ?? .distantPast, event: event, detail: detail, hash: hash, intact: ok))
                expected = hash
            }
            return out
        }
    }

    // MARK: Reading it as a person

    static func title(_ e: Entry) -> String {
        let d = e.detail
        func s(_ key: String) -> String { d[key] as? String ?? "" }
        func b(_ key: String) -> String { Fmt.bytes((d[key] as? NSNumber)?.int64Value ?? 0) }
        switch e.event {
        case "app.start": return "Aerilo \(s("version")) started (\(s("edition")), macOS \(s("os")))"
        case "breathe.start": return "Breathe started from \(s("source"))"
        case "scan": return "Measured: memory \(d["memoryPercent"] ?? "?")%, \(b("diskFree")) storage free, health \(d["health"] ?? "?")"
        case "clean.item": return "Cleared \(s("name")): \(b("bytesBefore")) before, \(b("bytesAfter")) after"
        case "clean.skipped": return "Skipped \(s("name")): \(s("reason"))"
        case "clean.done": return "Clean-up finished: \(b("bytes")) removed"
        case "breathe.end": return "Breathe finished: \(b("bytes")) removed, \((d["findings"] as? [Any])?.count ?? 0) findings, advice from \(s("advice"))"
        case "action.quit": return "\((d["force"] as? Bool) == true ? "Force quit" : "Quit") \(s("name")) (process \(d["pid"] ?? "?")): \((d["accepted"] as? Bool) == true ? "accepted" : "refused")"
        case "action.open": return "Opened \(s("url"))"
        case "access.home": return (d["granted"] as? Bool) == true ? "Home folder access allowed" : "Home folder access not given"
        case "settings": return "Setting changed: \(s("name")) = \(d["value"] ?? "")"
        case "update.check": return "Checked for updates: \(s("result"))"
        case "notify": return "Notification sent: \(s("title"))"
        case "log.export": return "Log exported"
        default: return e.event
        }
    }

    /// A plain-text report that can be attached to a support request or filed as an audit record.
    static func report() -> String {
        let all = entries()
        let broken = all.filter { !$0.intact }.count
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var lines = [
            "Aerilo activity report",
            "Created: \(day.string(from: Date()))",
            "Aerilo: \(version), \(edition) edition",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Entries: \(all.count)",
            "Integrity: " + (broken == 0 ? "intact (every entry follows from the one before it)" : "\(broken) entries do NOT follow from the one before them; the log was changed outside Aerilo"),
            "Log file: \(fileURL.path)",
            "",
        ]
        for e in all {
            lines.append("\(day.string(from: e.time))  \(e.intact ? " " : "!") \(title(e))")
            if let paths = e.detail["paths"] as? [String], !paths.isEmpty {
                for p in paths { lines.append("      \(p)") }
            }
            lines.append("      sha256 \(e.hash)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

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
