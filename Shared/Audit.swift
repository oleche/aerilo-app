import CryptoKit
import Foundation

/// The record of everything Aerilo did, for support and for audits.
///
/// One JSON object per line in `~/Library/Logs/Aerilo/audit.jsonl` (inside the app's container in the
/// App Store edition). Every entry carries the SHA-256 of the entry before it, so an entry that is
/// edited, or removed from the middle, no longer fits and `entries()` marks it. Aerilo also keeps the hash
/// of the newest entry in its own settings, apart from the file, so a log that was cut short at the end or
/// swapped for another shows up too (`cutShort`).
///
/// This is a consistency check, not a seal. It shows accidental damage and casual edits. Someone who can
/// change both the file and Aerilo's settings, with the time to recompute the hashes, can produce a log
/// that passes; nothing here proves otherwise, and the interface does not say it does.
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
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let fileURL: URL = {
        let library = Env.isHomeOverridden ? Env.realHome.appendingPathComponent("Library") : FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = library.appendingPathComponent("Logs/Aerilo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audit.jsonl")
    }()

    static var edition: String {
        #if os(macOS)
        return Env.isSandboxed ? "Mac App Store" : "Direct"
        #else
        return "iPhone and iPad"
        #endif
    }
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
            // From the file each time, not from memory: another copy of Aerilo (the menu bar, a self-test)
            // may have written since, and its entry is the one to follow.
            let prev = readLastHash() ?? "start"
            let hash = digest(time: time, event: event, detail: detail, prev: prev)
            let line: [String: Any] = ["t": time, "event": event, "detail": detail, "prev": prev, "hash": hash]
            guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else if !FileManager.default.fileExists(atPath: fileURL.path) {
                // Only ever start a new file. A log that exists but cannot be opened is left as it is.
                try? data.write(to: fileURL, options: .withoutOverwriting)
            } else {
                return
            }
            UserDefaults.standard.set(hash, forKey: checkpointKey)
        }
    }

    /// Where the newest entry's hash is kept, apart from the log. One per log file, so a test's stand-in
    /// log and the real one never share it.
    private static let checkpointKey: String = {
        let id = SHA256.hash(data: Data(fileURL.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "auditLastEntry.\(id)"
    }()

    /// True when the log on disk does not end with the entry Aerilo wrote last: entries were removed from
    /// the end, or the file was replaced. False for a log from before this note was kept.
    static func cutShort(_ entries: [Entry]) -> Bool {
        guard !Env.isDemo, let noted = UserDefaults.standard.string(forKey: checkpointKey) else { return false }
        return entries.last?.hash != noted
    }

    private static func readLastHash() -> String? {
        // The end of the file is enough: one entry is far shorter than this.
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? handle.readToEnd(),
              let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last,
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
        case "check.start": return "Checked again from \(s("source")), without clearing anything"
        case "scan": return "Measured: memory \(d["memoryPercent"] ?? "?")%, \(b("diskFree")) storage free, health \(d["health"] ?? "?")"
        case "clean.item": return "Cleared \(s("name")): \(b("bytesBefore")) before, \(b("bytesAfter")) after"
        case "clean.skipped": return "Skipped \(s("name")): \(s("reason"))"
        case "clean.done": return "Clean-up finished: \(b("bytes")) removed"
        case "breathe.end": return "Breathe finished: \(b("bytes")) removed, \((d["findings"] as? [Any])?.count ?? 0) findings, advice from \(s("advice"))"
        case "action.quit": return "\((d["force"] as? Bool) == true ? "Force quit" : "Quit") \(s("name")) (process \(d["pid"] ?? "?")): \((d["accepted"] as? Bool) == true ? "accepted" : "refused")"
        case "files.scan": return "Looked for large files: \(d["found"] ?? 0) found, \(b("bytes")) together"
        case "files.trash": return "Moved \(s("name")) to the Trash (\(b("bytes")))"
        case "files.trash.failed": return "Could not move \(s("name")) to the Trash"
        case "action.end": return "Ended \(s("what").lowercased()) in \(s("app")) (process \(d["pid"] ?? "?")): \((d["accepted"] as? Bool) == true ? "accepted" : "refused")"
        case "action.show": return "Brought \(s("name")) forward for you to quit"
        case "action.refused": return "Did not \(s("what")): \(s("reason")) (process \(d["pid"] ?? "?"))"
        case "access.temp": return (d["granted"] as? Bool) == true ? "System temp folder access allowed" : "System temp folder access not given"
        case "action.open": return "Opened \(s("url"))"
        case "access.home": return (d["granted"] as? Bool) == true ? "Home folder access allowed" : "Home folder access not given"
        case "settings": return "Setting changed: \(s("name")) = \(d["value"] ?? "")"
        case "update.check": return "Checked for updates: \(s("result"))"
        case "notify": return "Notification sent: \(s("title"))"
        case "log.export": return "Log exported"
        case "photos.access": return "Photo library access: \(s("status"))"
        case "photos.scan": return "Looked through \(d["assets"] ?? "?") photos and videos: \(d["found"] ?? 0) could go, \(b("bytes"))"
        case "photos.delete": return "Moved \(Fmt.items((d["count"] as? NSNumber)?.intValue ?? 0)) to Recently Deleted (\(b("bytes"))): \(s("kinds"))"
        case "photos.delete.cancelled": return "Deleting \(Fmt.items((d["count"] as? NSNumber)?.intValue ?? 0)) was cancelled"
        default: return e.event
        }
    }

    /// A plain-text report that can be attached to a support request or filed as an audit record.
    static func report() -> String {
        let all = entries()
        let broken = all.filter { !$0.intact }.count
        let short = cutShort(all)
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var lines = [
            "Aerilo activity report",
            "Created: \(day.string(from: Date()))",
            "Aerilo: \(version), \(edition) edition",
            "System: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Entries: \(all.count)",
            "Consistency: " + (broken > 0 ? "\(broken) entries do NOT follow from the one before them; the log was changed outside Aerilo"
                               : short ? "the log does NOT end with the entry Aerilo wrote last; entries were removed or the file was replaced"
                               : "consistent (every entry follows from the one before it, and the log ends with the entry Aerilo wrote last)"),
            "Note: this check shows accidental damage and casual edits. It is not proof against someone who rewrites the whole log.",
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
}
