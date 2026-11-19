import AppKit
import Observation
import SwiftUI

// MARK: - Findings

struct Finding: Identifiable {
    enum Action {
        case quit(pid: pid_t, name: String)
        case show(pid: pid_t, name: String)
        case clean([String])
        case open(URL)
        case grantAccess
    }
    let id: String
    let icon: String
    let title: String
    let detail: String
    /// 1 worth knowing, 2 slows the Mac, 3 fix now.
    let severity: Int
    var action: Action?
    var actionLabel: String?
}

/// One app with all its helper processes added up, which is how people think about "Chrome".
struct AppGroup: Identifiable {
    let name: String
    var footprint: UInt64 = 0
    var cpu: Double = 0
    var count = 0
    var mainPID: pid_t?
    var isApp = false
    var id: String { name }
}

enum Rules {
    /// Things the Mac itself needs. Aerilo never offers to quit them.
    static let protected: Set<String> = ["Aerilo", "Finder", "Dock", "SystemUIServer", "loginwindow", "ControlCenter",
                                         "Spotlight", "NotificationCenter", "WindowManager", "Siri", "TextInputMenuAgent"]

    static func groups(_ procs: [ProcInfo], apps: [String: pid_t]) -> [AppGroup] {
        var map: [String: AppGroup] = [:]
        for p in procs {
            let key = p.ownerApp ?? p.name
            var g = map[key] ?? AppGroup(name: key)
            g.footprint += p.footprint
            g.cpu += p.cpu
            g.count += 1
            if let pid = apps[key] { g.mainPID = pid; g.isApp = true } else if g.mainPID == nil { g.mainPID = p.pid }
            map[key] = g
        }
        return Array(map.values)
    }

    static func build(sys: SystemSnapshot, procs: [ProcInfo], groups: [AppGroup], net: [NetProc],
                      items: [CleanItem], sizes: [String: Int64], hasHome: Bool, updatePrepared: Bool = false) -> [Finding] {
        var out: [Finding] = []
        let canStop: (AppGroup) -> Bool = { $0.isApp || !Env.isSandboxed }
        func quitAction(_ g: AppGroup) -> (Finding.Action?, String?) {
            guard let pid = g.mainPID, canStop(g), !protected.contains(g.name) else { return (nil, nil) }
            // App Store apps may not quit other apps, so there Aerilo brings the app forward for you to quit.
            if Env.isSandboxed { return (.show(pid: pid, name: g.name), "Show \(g.name)") }
            return (.quit(pid: pid, name: g.name), g.isApp ? "Quit \(g.name)" : "Stop")
        }

        // Runaway: one process pinned above 90% of a core for a minute or more.
        for p in procs.filter(\.isRunaway).sorted(by: { $0.cpu > $1.cpu }).prefix(3) {
            let g = groups.first { $0.name == (p.ownerApp ?? p.name) }
            let (action, label) = g.map(quitAction) ?? (nil, nil)
            out.append(Finding(id: "runaway-\(p.pid)", icon: "flame", title: "\(p.ownerApp ?? p.name) looks stuck",
                               detail: "\(p.name) has used \(Int(p.cpu))% of a core for \(Int(p.hotSeconds / 60)) min without a pause.",
                               severity: 3, action: action, actionLabel: label))
        }

        // Memory that keeps climbing.
        for p in procs.filter({ $0.growth != nil }).sorted(by: { $0.growth! > $1.growth! }).prefix(3) {
            let g = groups.first { $0.name == (p.ownerApp ?? p.name) }
            let (action, label) = g.map(quitAction) ?? (nil, nil)
            out.append(Finding(id: "leak-\(p.pid)", icon: "drop", title: "\(p.ownerApp ?? p.name) may be leaking memory",
                               detail: "\(p.name) grew by \(Fmt.mem(p.growth!)) in \(Int(p.growthMinutes)) min and never gave any back. Restarting it frees the memory.",
                               severity: sys.pressure >= 2 ? 3 : 2, action: action, actionLabel: label))
        }

        // The heaviest apps, when memory is actually tight.
        let heavyFloor = max(UInt64(2) << 30, sys.memTotal / 8)
        let tight = sys.pressure >= 2 || sys.memFraction > 0.8 || sys.swapUsed > UInt64(2) << 30
        for g in groups.filter({ $0.footprint >= heavyFloor && !protected.contains($0.name) }).sorted(by: { $0.footprint > $1.footprint }).prefix(tight ? 3 : 1) {
            let (action, label) = quitAction(g)
            let share = Int(Double(g.footprint) / Double(max(1, sys.memTotal)) * 100)
            out.append(Finding(id: "mem-\(g.name)", icon: "memorychip", title: "\(g.name) holds \(Fmt.mem(g.footprint))",
                               detail: "\(share)% of this Mac's memory" + (g.count > 1 ? " across \(g.count) processes." : ".") + (tight ? " Memory is tight right now." : " Fine while memory is free."),
                               severity: tight ? 2 : 1, action: tight ? action : nil, actionLabel: tight ? label : nil))
        }

        let zombies = procs.filter(\.isZombie).count
        if zombies >= 5 {
            out.append(Finding(id: "zombies", icon: "moon.zzz", title: "\(zombies) finished processes were never collected",
                               detail: "They use no memory but fill the process table. Restarting the app that started them clears them.", severity: 1))
        }

        if let top = net.first, top.total > 2_000_000 {
            out.append(Finding(id: "net-\(top.pid)", icon: "arrow.up.arrow.down", title: "\(top.name) is using the network heavily",
                               detail: "\(Fmt.rate(top.bytesIn)) down, \(Fmt.rate(top.bytesOut)) up. Other apps get what is left.", severity: 1))
        }

        if sys.diskTotal > 0, sys.diskFreeFraction < 0.10 || sys.diskFree < 20 << 30 {
            out.append(Finding(id: "disk", icon: "internaldrive", title: "Only \(Fmt.bytes(sys.diskFree)) of storage is free",
                               detail: "macOS needs free space for swap and updates. Below 10% everything slows down.",
                               severity: sys.diskFreeFraction < 0.05 ? 3 : 2))
        }

        let optional = items.filter { $0.tier == .rebuildable && (sizes[$0.id] ?? 0) >= 1 << 30 }
        if !optional.isEmpty {
            let total = optional.reduce(Int64(0)) { $0 + (sizes[$1.id] ?? 0) }
            out.append(Finding(id: "caches", icon: "shippingbox", title: "\(Fmt.bytes(total)) of rebuildable caches",
                               detail: optional.map(\.name).joined(separator: ", ") + ". Safe to clear; the next build downloads them again.",
                               severity: sys.diskFreeFraction < 0.15 ? 2 : 1, action: .clean(optional.map(\.id)), actionLabel: "Clear"))
        }

        if updatePrepared {
            out.append(Finding(id: "update", icon: "arrow.down.circle", title: "A macOS update is downloaded and waiting",
                               detail: "It holds several gigabytes until it is installed. Installing it gives the space back.", severity: 1,
                               action: .open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!), actionLabel: "Open"))
        }

        if sys.swapUsed > UInt64(4) << 30 {
            out.append(Finding(id: "swap", icon: "arrow.left.arrow.right", title: "\(Fmt.mem(sys.swapUsed)) moved to disk",
                               detail: "The Mac ran out of memory and is using the disk instead, which is far slower. Closing a heavy app helps most.", severity: 2))
        }

        if sys.thermal == .serious || sys.thermal == .critical {
            out.append(Finding(id: "thermal", icon: "thermometer.high", title: "This Mac is hot and slowing itself down",
                               detail: "macOS lowers speed to cool off. Stopping the busiest app brings it back.", severity: 2))
        }

        if sys.uptime > 10 * 86_400 {
            out.append(Finding(id: "uptime", icon: "arrow.clockwise", title: "Running for \(Fmt.uptime(sys.uptime)) without a restart",
                               detail: "A restart clears leaked memory and stuck background services in one go.", severity: 1))
        }

        if sys.launchAgents > 15 {
            out.append(Finding(id: "agents", icon: "power", title: "\(sys.launchAgents) background items start with your Mac",
                               detail: "Each one takes memory from the moment you log in. Turn off the ones you don't use.", severity: 1,
                               action: .open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!), actionLabel: "Review"))
        }

        if Env.isSandboxed, !hasHome {
            out.append(Finding(id: "access", icon: "folder.badge.plus", title: "Storage cleaning is waiting for access",
                               detail: "Allow your Home folder once and Aerilo can measure and clear caches inside it.", severity: 1,
                               action: .grantAccess, actionLabel: "Allow"))
        }
        return out.sorted { $0.severity > $1.severity }
    }
}

// MARK: - Model

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    typealias Phase = BreathPhase
    enum Screen: String, CaseIterable { case home = "Breathe", activity = "Activity", network = "Network", storage = "Storage", photos = "Photos", assistant = "Assistant", log = "Log" }

    var phase: Phase = .idle
    var phaseStart = Date()
    var screen: Screen = .home

    var sys = SystemSnapshot()
    var procs: [ProcInfo] = []
    var groups: [AppGroup] = []
    var net: [NetProc] = []
    var items: [CleanItem] = []
    var sizes: [String: Int64] = [:]
    var selected: Set<String> = []
    var measuring = false
    var cleaning = false

    var findings: [Finding] = []
    var advice: Advice?
    var lastFreed: Int64 = 0
    var lastCleaned: [String] = []
    var lastRun: Date?
    var hasHome = Cleaner.home != nil
    var hasTemp = Cleaner.tempRoot != nil
    var processesReadable = true
    var updatePrepared = false
    /// What Aerilo is doing right now, in plain words, and the steps of the current run so far.
    var activity = ""
    var steps: [String] = []

    @ObservationIgnored private let sysProbe = SystemProbe()
    @ObservationIgnored private let procProbe = ProcessProbe()
    @ObservationIgnored private var monitor: Task<Void, Never>?

    private init() {
        if Env.isDemo { Demo.fill(self); return }
        items = Cleaner.items()
        Audit.record("app.start", ["version": Audit.version, "edition": Audit.edition,
                                   "os": ProcessInfo.processInfo.operatingSystemVersionString])
        start()
    }

    private func note(_ text: String) {
        activity = text
        steps.append(text)
    }

    // MARK: Monitoring

    private func start() {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await Updater.shared.checkDailyIfEnabled()
                // Sample often only while someone is looking at the numbers; otherwise stay light.
                let watching = self?.screen == .activity || self?.phase == .inhale
                try? await Task.sleep(for: .seconds(watching ? 3 : 10))
            }
        }
    }

    func refresh() async {
        guard !Env.isDemo else { return }
        let sysProbe = sysProbe, procProbe = procProbe
        let (s, p, readable) = await Task.detached(priority: .utility) { () -> (SystemSnapshot, [ProcInfo], Int) in
            var s = sysProbe.read()
            let agents = Env.realHome.appendingPathComponent("Library/LaunchAgents")
            s.launchAgents = ((try? FileManager.default.contentsOfDirectory(atPath: agents.path)) ?? []).filter { $0.hasSuffix(".plist") }.count
            let p = procProbe.sample()
            return (s, p, procProbe.readable)
        }.value
        sys = s
        Notifier.check(s)
        procs = p
        processesReadable = readable > 1
        groups = Rules.groups(p, apps: runningApps())
    }

    private func runningApps() -> [String: pid_t] {
        var map: [String: pid_t] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let name = app.bundleURL?.deletingPathExtension().lastPathComponent { map[name] = app.processIdentifier }
        }
        return map
    }

    func refreshNetwork() async {
        guard !Env.isDemo else { return }
        net = await Task.detached(priority: .utility) { NetworkProbe.sample() }.value
    }

    func measureStorage() async {
        guard !Env.isDemo else { return }
        hasHome = Cleaner.home != nil
        items = Cleaner.items()
        measuring = true
        let list = items
        sizes = await Task.detached(priority: .utility) {
            var out: [String: Int64] = [:]
            for item in list { out[item.id] = Cleaner.measure(item) }
            return out
        }.value
        if selected.isEmpty { selected = Set(items.filter { $0.tier == .safe }.map(\.id)) }
        measuring = false
    }

    func rebuildFindings() {
        findings = Rules.build(sys: sys, procs: procs, groups: groups, net: net, items: items, sizes: sizes, hasHome: hasHome, updatePrepared: updatePrepared)
    }

    // MARK: Cleaning

    /// Clears the given items one at a time, skipping any that are blocked right now, and writes
    /// each step to the log. Returns the bytes removed.
    @discardableResult
    func clean(ids: Set<String>, reason: String = "selected in Storage") async -> Int64 {
        guard !Env.isDemo, !cleaning else { return 0 }
        cleaning = true
        defer { cleaning = false }
        // A test run on a stand-in home must not depend on which apps happen to be open.
        let procsNow = Env.isHomeOverridden ? [] : procs
        var freed: Int64 = 0
        var names: [String] = []
        for item in items where ids.contains(item.id) && item.tier != .ask {
            let before = sizes[item.id] ?? 0
            guard before > 0 else { continue }
            if let why = item.blocker(procsNow) {
                note("Skipped \(item.name): \(why)")
                Audit.record("clean.skipped", ["item": item.id, "name": item.name, "reason": why, "bytes": before])
                continue
            }
            note("Clearing \(item.name) (\(Fmt.bytes(before)))")
            let after = await Task.detached(priority: .utility) { () -> Int64 in
                Cleaner.clean(item)
                return Cleaner.measure(item)
            }.value
            sizes[item.id] = after
            Audit.record("clean.item", ["item": item.id, "name": item.name, "bytesBefore": before, "bytesAfter": after, "paths": item.paths])
            if before > after { freed += before - after; names.append(item.name) }
        }
        lastCleaned = names
        Audit.record("clean.done", ["reason": reason, "bytes": freed])
        return freed
    }

    // MARK: The one button

    func breathe(source: String = "the window") async {
        guard phase == .idle || phase == .done, !cleaning else { return }
        if Env.isDemo { await Demo.breathe(self); return }
        steps = []
        setPhase(.inhale)
        let began = Date()
        Audit.record("breathe.start", ["source": source])

        note("Reading memory, processor and storage")
        await refresh()
        async let network: Void = refreshNetwork()
        note("Measuring caches and leftovers")
        await measureStorage()
        note("Looking at running apps")
        await refresh() // a second sample one beat later, so processor figures are real
        await network
        updatePrepared = await Task.detached(priority: .utility) { Cleaner.hasPreparedUpdate() }.value
        Audit.record("scan", ["memoryPercent": Int(sys.memFraction * 100), "pressure": sys.pressure, "swap": Int64(sys.swapUsed),
                              "cpuPercent": Int(sys.cpuLoad * 100), "diskFree": sys.diskFree, "health": sys.health,
                              "processes": procs.count])

        let safe = Set(items.filter { $0.tier == .safe }.map(\.id))
        lastFreed = await clean(ids: safe, reason: "Breathe")
        await refresh()
        rebuildFindings()
        note(Advisor.isReady ? "Asking the on-device assistant what helps most" : "Ranking what helps most")
        advice = await Advisor.plan(sys: sys, findings: findings, freed: lastFreed)
        lastRun = Date()
        Audit.record("breathe.end", ["bytes": lastFreed, "findings": findings.map(\.id),
                                     "advice": advice?.source == .onDevice ? "the on-device model" : "built-in rules"])

        // Let the inhale finish before the release, however fast the work was.
        let left = 3.0 - Date().timeIntervalSince(began)
        if left > 0 { try? await Task.sleep(for: .seconds(left)) }
        note(lastFreed > 0 ? "Letting go of \(Fmt.bytes(lastFreed))" : "Nothing needed clearing")
        setPhase(.exhale)
        try? await Task.sleep(for: .seconds(3.6))
        activity = ""
        setPhase(.done)
    }

    func setPhase(_ p: Phase) {
        phaseStart = Date()
        withAnimation(.easeInOut(duration: 1.2)) { phase = p }
    }

    func reset() { setPhase(.idle) }

    // MARK: Actions

    func perform(_ finding: Finding) async {
        guard let action = finding.action else { return }
        switch action {
        case .quit(let pid, _):
            stop(pid: pid, force: false)
            try? await Task.sleep(for: .seconds(1.5))
            await refresh()
        case .show(let pid, let name):
            NSRunningApplication(processIdentifier: pid)?.activate()
            Audit.record("action.show", ["name": name])
            return
        case .clean(let ids):
            lastFreed += await clean(ids: Set(ids), reason: "suggestion")
            activity = ""
        case .open(let url):
            NSWorkspace.shared.open(url)
            Audit.record("action.open", ["url": url.absoluteString])
            return
        case .grantAccess:
            await grantHome()
        }
        rebuildFindings()
        if let advice { self.advice = advice.keeping(findings.map(\.id)) }
    }

    /// Asks an app to quit (it can still ask to save), or ends it when `force` is set.
    @discardableResult
    func stop(pid: pid_t, force: Bool) -> Bool {
        // Never Aerilo itself, never launchd or the kernel, and only on a direct request from the user.
        guard !Env.isDemo, pid > 1, pid != getpid() else { return false }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? procs.first { $0.pid == pid }?.name ?? "process"
        let accepted: Bool
        if let app = NSRunningApplication(processIdentifier: pid) {
            accepted = force ? app.forceTerminate() : app.terminate()
        } else if Env.isSandboxed {
            accepted = false
        } else {
            accepted = kill(pid, force ? SIGKILL : SIGTERM) == 0
        }
        Audit.record("action.quit", ["name": name, "pid": Int(pid), "force": force, "accepted": accepted])
        return accepted
    }

    func grantTemp() async {
        let granted = Cleaner.requestTempAccess()
        Audit.record("access.temp", ["granted": granted])
        hasTemp = Cleaner.tempRoot != nil
        if granted { await measureStorage() }
    }

    func grantHome() async {
        let granted = Cleaner.requestHomeAccess()
        Audit.record("access.home", ["granted": granted])
        if granted { await measureStorage() }
    }

    func icon(for pid: pid_t?) -> NSImage? {
        guard let pid, !Env.isDemo else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.icon
    }
}
