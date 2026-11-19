import Foundation

/// A look inside one app: what its helper processes are and how much each kind holds.
///
/// Browsers built on Chromium (Chrome, Edge, Brave, Arc) and apps built on Electron (VS Code,
/// Slack, Discord and many more) run as dozens of processes, and each one says what it is on its
/// command line. Aerilo reads that label; it never reads the app's data, tabs or files.
struct AppInsight {
    struct Part: Identifiable {
        let pid: pid_t
        let title: String
        var footprint: UInt64
        var cpu: Double
        /// Ending it is safe for the app: the tab reloads, or the app restarts the helper.
        let canEnd: Bool
        var id: pid_t { pid }
    }

    struct Section: Identifiable {
        let kind: Kind
        var parts: [Part]
        var id: String { kind.rawValue }
        var footprint: UInt64 { parts.reduce(0) { $0 + $1.footprint } }
    }

    enum Kind: String, CaseIterable {
        case tabs = "Tabs and windows"
        case extensions = "Extensions"
        case tools = "Language tools and tasks"
        case graphics = "Graphics"
        case services = "Background services"
        case app = "The app itself"

        var note: String {
            switch self {
            case .tabs: return "Each open tab or window is its own process. Ending one frees its memory; the tab stays and reloads when you ask."
            case .extensions: return "Add-ons that run alongside the app. A heavy one is worth switching off in the app's own settings."
            case .tools: return "Helpers that extensions start, such as language servers. The app starts them again when it needs them."
            case .graphics: return "Draws the app on screen. Shared by every tab."
            case .services: return "Networking, audio, storage and similar helpers."
            case .app: return "The main process. Ending it quits the app."
            }
        }
        var icon: String {
            switch self {
            case .tabs: return "macwindow.on.rectangle"
            case .extensions: return "puzzlepiece.extension"
            case .tools: return "hammer"
            case .graphics: return "sparkles.tv"
            case .services: return "gearshape.2"
            case .app: return "app"
            }
        }
    }

    let app: String
    var sections: [Section]
    var total: UInt64 { sections.reduce(0) { $0 + $1.footprint } }

    /// A plain sentence on where the memory is, used when the on-device model is unavailable.
    var summary: String {
        guard let top = sections.first, total > 0 else { return "\(app) is using very little right now." }
        let share = Int(Double(top.footprint) / Double(total) * 100)
        var text = "\(share)% of \(app)'s memory is in \(top.kind.rawValue.lowercased()) (\(Fmt.mem(top.footprint)) across \(top.parts.count))."
        if let heavy = top.parts.first, top.parts.count > 1, heavy.footprint > top.footprint / 3 {
            text += " One of them alone holds \(Fmt.mem(heavy.footprint))."
        }
        return text
    }
}

enum Insights {
    /// Says what one process is, from its name and command line. Pure, so it can be tested.
    static func classify(name: String, arguments: String, isMain: Bool, insideApp: Bool) -> (kind: AppInsight.Kind, title: String) {
        if isMain { return (.app, name) }
        // Chromium and Electron helpers label themselves with --type=.
        if let type = value(of: "--type", in: arguments) {
            switch type {
            case "renderer":
                if arguments.contains("--extension-process") { return (.extensions, "Extension") }
                return (.tabs, "Tab or window")
            case "gpu-process":
                return (.graphics, "Graphics")
            case "utility":
                let sub = value(of: "--utility-sub-type", in: arguments) ?? ""
                if sub.contains("NodeService") || name.contains("(Plugin)") { return (.extensions, "Extension host") }
                if sub.contains("network") { return (.services, "Network") }
                if sub.contains("audio") { return (.services, "Audio") }
                if sub.contains("storage") { return (.services, "Storage") }
                if sub.contains("video_capture") { return (.services, "Camera") }
                return (.services, "Service")
            default:
                return (.services, type.replacingOccurrences(of: "-", with: " ").capitalized)
            }
        }
        if name.contains("(Plugin)") { return (.extensions, "Extension host") }
        if name.contains("(Renderer)") { return (.tabs, "Tab or window") }
        if name.contains("(GPU)") { return (.graphics, "Graphics") }
        // Tools started by an editor's extensions name the extension in their path.
        if let ext = editorExtension(in: arguments) { return (.tools, ext) }
        if arguments.contains("tsserver") { return (.tools, "TypeScript language service") }
        return (insideApp ? .services : .tools, name)
    }

    /// The value of `--flag=value` on a command line.
    static func value(of flag: String, in arguments: String) -> String? {
        guard let range = arguments.range(of: flag + "=") else { return nil }
        return String(arguments[range.upperBound...].prefix { $0 != " " })
    }

    /// "ms-python.vscode-pylance" from a path under an editor's extensions folder.
    static func editorExtension(in arguments: String) -> String? {
        guard let range = arguments.range(of: "/extensions/") else { return nil }
        let before = arguments[..<range.lowerBound]
        guard let folder = before.split(separator: "/").last, folder.hasPrefix(".") else { return nil } // .vscode, .cursor, …
        let id = arguments[range.upperBound...].prefix { $0 != "/" && $0 != " " }
        // Drop the version: "publisher.name-1.2.3" -> "publisher.name".
        let parts = id.split(separator: "-")
        let name = parts.count > 1 && parts.last!.first?.isNumber == true ? parts.dropLast().joined(separator: "-") : String(id)
        return name.isEmpty ? nil : name
    }

    /// Everything that belongs to an app: the processes inside its bundle, and whatever they started.
    static func build(app: String, mainPID: pid_t?, procs: [ProcInfo], arguments: (pid_t) -> String = ProcessProbe.arguments(of:)) -> AppInsight {
        var members = Set(procs.filter { ($0.ownerApp ?? $0.name) == app }.map(\.pid))
        // Children of members, to any depth: language servers and tasks live outside the bundle.
        var grew = true
        while grew {
            grew = false
            for p in procs where !members.contains(p.pid) && members.contains(p.parent) {
                members.insert(p.pid)
                grew = true
            }
        }
        var buckets: [AppInsight.Kind: [AppInsight.Part]] = [:]
        for p in procs where members.contains(p.pid) {
            let inside = (p.ownerApp ?? p.name) == app
            let (kind, title) = classify(name: p.name, arguments: arguments(p.pid), isMain: p.pid == mainPID, insideApp: inside)
            buckets[kind, default: []].append(AppInsight.Part(pid: p.pid, title: title, footprint: p.footprint, cpu: p.cpu, canEnd: kind == .tabs || kind == .tools))
        }
        var sections = buckets.map { kind, parts -> AppInsight.Section in
            var sorted = parts.sorted { $0.footprint > $1.footprint }
            // Tabs have no names an outside app may read, so they are numbered by size.
            if kind == .tabs {
                sorted = sorted.enumerated().map { index, part in
                    AppInsight.Part(pid: part.pid, title: index == 0 && sorted.count > 1 ? "Heaviest tab or window" : "Tab or window \(index + 1)",
                                    footprint: part.footprint, cpu: part.cpu, canEnd: part.canEnd)
                }
            }
            return AppInsight.Section(kind: kind, parts: sorted)
        }
        sections.sort { $0.footprint > $1.footprint }
        return AppInsight(app: app, sections: sections)
    }

    /// True for apps worth looking inside: more than a handful of processes.
    static func isWorthOpening(_ group: AppGroup) -> Bool { group.count >= 4 }
}
