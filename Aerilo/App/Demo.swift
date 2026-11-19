import Foundation

/// Fixed sample data for App Store screenshots (`--demo`), so no real process names are shown.
@MainActor
enum Demo {
    static let question = "Why does my Mac feel slow today?"
    static let answer = "Memory is the main reason. Your browser holds almost a third of it and one tab's helper has kept growing for 25 minutes, so the Mac moved 5 GB to disk. Quitting and reopening the browser gives that back. Storage and the processor are fine."

    private static let G: Int64 = 1_000_000_000

    static func fill(_ m: AppModel) {
        var s = SystemSnapshot()
        s.memTotal = 24 << 30
        s.memUsed = UInt64(19.4 * 1_073_741_824)
        s.swapUsed = UInt64(5.1 * 1_073_741_824)
        s.pressure = 2
        s.cpuLoad = 0.34
        s.diskTotal = 494 * G
        s.diskFree = 81 * G
        s.uptime = 12 * 86_400
        s.netIn = 3_400_000
        s.netOut = 420_000
        s.launchAgents = 9
        m.sys = s

        let apps: [(String, Double, Double, Int)] = [
            ("Browser", 7.6, 22, 31), ("Code Editor", 3.9, 12, 14), ("Design Studio", 2.8, 6, 9),
            ("Video Calls", 1.9, 96, 5), ("Team Chat", 1.4, 3, 7), ("Music", 0.6, 2, 3),
            ("Mail", 0.5, 1, 4), ("Notes", 0.3, 0, 2), ("Calendar", 0.2, 0, 2),
        ]
        var procs: [ProcInfo] = []
        var groups: [AppGroup] = []
        var pid: pid_t = 600
        for (name, gb, cpu, count) in apps {
            pid += 10
            var p = ProcInfo(pid: pid, name: name)
            p.ownerApp = name
            p.footprint = UInt64(gb * 1_073_741_824)
            p.cpu = cpu
            if name == "Browser" { p.growth = UInt64(1.2 * 1_073_741_824); p.growthMinutes = 25 }
            if name == "Video Calls" { p.hotSeconds = 420 }
            procs.append(p)
            groups.append(AppGroup(name: name, footprint: p.footprint, cpu: cpu, count: count, mainPID: pid, isApp: true))
        }
        // Screenshots of the App Store edition are taken from the App Store build itself, so they
        // show exactly what it can do: activity yes, per-app network and simulators no.
        let store = Env.isSandboxed
        m.procs = procs
        m.groups = groups
        m.net = store ? [] : [
            NetProc(pid: 610, name: "Browser", bytesIn: 2_600_000, bytesOut: 210_000),
            NetProc(pid: 640, name: "Video Calls", bytesIn: 640_000, bytesOut: 180_000),
            NetProc(pid: 650, name: "Team Chat", bytesIn: 96_000, bytesOut: 22_000),
            NetProc(pid: 660, name: "Music", bytesIn: 64_000, bytesOut: 4_000),
            NetProc(pid: 670, name: "Mail", bytesIn: 9_000, bytesOut: 3_000),
        ]

        let none = CleanItem.Kind.contents([])
        m.items = [
            CleanItem(id: "simulators", name: "Unusable simulators", detail: "Simulators of iOS versions that are no longer installed.", tier: .safe, kind: none),
            CleanItem(id: "derived", name: "Xcode build data", detail: "DerivedData. The next build takes longer.", tier: .safe, kind: none),
            CleanItem(id: "updaters", name: "App update leftovers", detail: "Installers that apps kept after updating.", tier: .safe, kind: none),
            CleanItem(id: "npm", name: "npm cache", detail: "Downloaded packages, fetched again when needed.", tier: .safe, kind: none),
            CleanItem(id: "pods", name: "CocoaPods cache", detail: "The next iOS build downloads its pods again.", tier: .rebuildable, kind: none),
            CleanItem(id: "gradle", name: "Gradle caches", detail: "The next Android build downloads them again.", tier: .rebuildable, kind: none),
            CleanItem(id: "archives", name: "Xcode archives", detail: "Keep the ones for shipped releases: they hold crash symbols.", tier: .ask,
                      kind: .reveal(URL(fileURLWithPath: "/"))),
        ]
        m.sizes = ["simulators": 52 * G, "derived": 11 * G, "updaters": G * 5 / 2, "npm": G * 16 / 5,
                   "pods": 34 * G, "gradle": 13 * G, "archives": G * 49 / 10]
        m.selected = ["simulators", "derived", "updaters", "npm"]
        if store {
            // Simulators are cleared through a developer tool the sandbox can't run.
            m.items.removeAll { $0.id == "simulators" }
            m.sizes["simulators"] = nil
        }
        m.hasHome = true
        m.bigFiles = [("Holiday film final.mov", "Movies", 6.4, 420), ("Design archive 2024.zip", "Downloads", 3.1, 200), ("Installer.dmg", "Downloads", 1.8, 95)].map {
            BigFile(url: URL(fileURLWithPath: "/Users/you/\($0.1)/\($0.0)"), bytes: Int64($0.2 * 1_000_000_000), lastOpened: Date().addingTimeInterval(-Double($0.3) * 86_400))
        }

        if Env.arg("--shot") == "exhale" {
            finish(m)
            m.activity = "Letting go of \(Fmt.bytes(m.lastFreed))"
            m.steps = ["Measuring caches and leftovers", "Clearing Xcode build data (11 GB)", "Clearing npm cache (3.2 GB)", m.activity]
            m.phase = .exhale
            m.phaseStart = Date().addingTimeInterval(1.2)
        } else if let shot = Env.arg("--shot"), shot != "home" {
            // The storage shot shows the list before cleaning.
            if shot != "storage" { finish(m) }
            m.phase = .done
            if let screen = AppModel.Screen.allCases.first(where: { $0.rawValue.lowercased() == shot }) { m.screen = screen }
        }
    }

    private static func finish(_ m: AppModel) {
        m.lastFreed = ["simulators", "derived", "updaters", "npm"].reduce(0) { $0 + (m.sizes[$1] ?? 0) }
        for id in ["simulators", "derived", "updaters", "npm"] { m.sizes[id] = 0 }
        m.sys.diskFree += m.lastFreed
        m.rebuildFindings()
        let reasons = [
            "leak-610": "Its memory has only gone up for 25 minutes. Reopening it gives 1.2 GB back at once.",
            "runaway-640": "It has kept one processor core busy for 7 minutes. Quitting it cools the Mac down.",
            "mem-Browser": "It holds a third of your memory while the Mac is short of it.",
            "caches": "47 GB that the next build downloads again. Worth clearing when storage runs low.",
        ]
        let order = ["leak-610", "runaway-640", "mem-Browser", "caches"]
        let known = m.findings.map(\.id)
        var steps = order.filter(known.contains).map { Advice.Step(id: $0, reason: reasons[$0]!) }
        steps += m.findings.filter { !order.contains($0.id) }.map { Advice.Step(id: $0.id, reason: $0.detail) }
        m.advice = Advice(headline: "Lighter already. Two apps are still holding your Mac back.", steps: steps, source: .onDevice)
    }

    static let insightAdvice = "Most of Browser's memory is in its tabs, and one tab alone holds 1.9 GB. Freeing that tab gives the most back without closing anything else."

    /// A sample look inside the browser, for screenshots.
    static func insight(for app: String) -> AppInsight {
        func parts(_ titles: [(String, Double, Double)], canEnd: Bool) -> [AppInsight.Part] {
            titles.enumerated().map { i, t in AppInsight.Part(pid: pid_t(900 + i), title: t.0, footprint: UInt64(t.1 * 1_073_741_824), cpu: t.2, canEnd: canEnd) }
        }
        return AppInsight(app: app, sections: [
            AppInsight.Section(kind: .tabs, parts: parts([("Heaviest tab or window", 1.9, 14), ("Tab or window 2", 0.9, 3), ("Tab or window 3", 0.7, 1), ("Tab or window 4", 0.6, 0),
                                                           ("Tab or window 5", 0.5, 0), ("Tab or window 6", 0.4, 2)], canEnd: true)),
            AppInsight.Section(kind: .extensions, parts: parts([("Extension", 0.6, 1), ("Extension", 0.3, 0), ("Extension", 0.2, 0)], canEnd: false)),
            AppInsight.Section(kind: .graphics, parts: parts([("Graphics", 0.8, 2)], canEnd: false)),
            AppInsight.Section(kind: .app, parts: parts([(app, 0.5, 1)], canEnd: false)),
            AppInsight.Section(kind: .services, parts: parts([("Network", 0.15, 0), ("Storage", 0.08, 0)], canEnd: false)),
        ])
    }

    /// Sample log entries for the screenshot of the Log screen.
    static func log() -> [Audit.Entry] {
        let now = Date()
        let rows: [(String, [String: Any])] = [
            ("app.start", ["version": "1.0.0 (1)", "edition": Audit.edition, "os": "Version 27.2"]),
            ("breathe.start", ["source": "the window"]),
            ("scan", ["memoryPercent": 80, "diskFree": 81 * G, "health": 71]),
            ("clean.item", ["name": "Xcode build data", "bytesBefore": 11 * G, "bytesAfter": 0, "paths": ["~/Library/Developer/Xcode/DerivedData"]]),
            ("clean.item", ["name": "npm cache", "bytesBefore": G * 16 / 5, "bytesAfter": 0, "paths": ["~/.npm/_cacache"]]),
            ("clean.skipped", ["name": "App update leftovers", "reason": "ShipIt is running"]),
            ("clean.done", ["bytes": G * 142 / 10]),
            ("breathe.end", ["bytes": G * 142 / 10, "findings": ["swap", "caches", "uptime"], "advice": "the on-device model"]),
        ]
        return rows.enumerated().map { index, row in
            Audit.Entry(id: index, time: now.addingTimeInterval(Double(index - rows.count) * 2), event: row.0, detail: row.1, hash: "", intact: true)
        }
    }

    static func breathe(_ m: AppModel) async {
        m.steps = []
        m.setPhase(.inhale)
        for text in ["Reading memory, processor and storage", "Measuring caches and leftovers",
                     "Clearing Xcode build data (11 GB)", "Asking the on-device assistant what helps most"] {
            m.activity = text
            m.steps.append(text)
            try? await Task.sleep(for: .seconds(0.8))
        }
        finish(m)
        m.activity = "Letting go of \(Fmt.bytes(m.lastFreed))"
        m.setPhase(.exhale)
        try? await Task.sleep(for: .seconds(3.6))
        m.activity = ""
        m.setPhase(.done)
    }
}
