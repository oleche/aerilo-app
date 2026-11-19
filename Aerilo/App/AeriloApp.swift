import AppKit
import SwiftUI

enum Links {
    static let site = URL(string: "https://aerilo.app")!
    static let help = URL(string: "https://aerilo.app/support.html")!
    static let privacy = URL(string: "https://aerilo.app/privacy.html")!
    static let source = URL(string: "https://github.com/oleche/aerilo-app")!
    static let mail = URL(string: "mailto:info@geekcow.com?subject=Aerilo")!
}

@main
enum Main {
    @MainActor static var captureWindow: NSWindow?

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        if CommandLine.arguments.contains("--breathe-test") {
            exit(BreatheTest.run() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            exit(0)
        }
        if CommandLine.arguments.contains("--capture") {
            // Screenshot run: started from a script, in the background, where SwiftUI would not open
            // the main window. Build a standard window directly, exactly 1440 x 900, with demo data.
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                let shot = Env.arg("--shot")
                let root: AnyView = shot == "welcome" ? AnyView(WelcomeView {}.environment(AppModel.shared))
                    : shot == "settings" ? AnyView(SettingsView().environment(AppModel.shared))
                    : shot == "widget" ? AnyView(WidgetPreview())
                    : shot == "inside" ? AnyView(ZStack { Aurora(); InsightView(group: AppModel.shared.groups.first ?? AppGroup(name: "Browser")).environment(AppModel.shared) })
                    : AnyView(RootView().environment(AppModel.shared))
                let host = NSHostingController(rootView: root)
                host.sceneBridgingOptions = [.toolbars, .title]
                let window = NSWindow(contentViewController: host)
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                window.titlebarAppearsTransparent = true
                window.title = "Aerilo"
                window.toolbarStyle = .unified
                window.appearance = NSAppearance(named: Env.arg("--appearance") == "dark" ? .darkAqua : .aqua)
                if shot != "welcome" && shot != "settings" && shot != "widget" { window.setContentSize(NSSize(width: 1440, height: 900)) }
                window.center()
                window.orderFrontRegardless()
                if !CommandLine.arguments.contains("--no-activate") {
                    // Key and active, so controls are drawn in their normal, not dimmed, state.
                    app.activate(ignoringOtherApps: true)
                    window.makeKey()
                }
                captureWindow = window
                DispatchQueue.main.asyncAfter(deadline: .now() + (Double(Env.arg("--delay") ?? "") ?? 2.5)) {
                    print("WINDOW \(window.windowNumber)")
                }
                app.run()
            }
            return
        }
        AeriloApp.main()
    }
}

struct AeriloApp: App {
    @State private var model = AppModel.shared
    @State private var updater = Updater.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Aerilo", id: "main") {
            RootView().environment(model)
        }
        .defaultSize(width: 940, height: 700)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .appInfo) {
                if Updater.isAvailable {
                    Button("Check for Updates…") {
                        Task {
                            await updater.check()
                            show(.home)
                            let alert = NSAlert()
                            alert.messageText = updater.message
                            if let release = updater.release {
                                alert.informativeText = release.notes
                                alert.addButton(withTitle: "Download")
                                alert.addButton(withTitle: "Later")
                                if alert.runModal() == .alertFirstButtonReturn { updater.download() }
                            } else {
                                alert.runModal()
                            }
                        }
                    }
                }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("Export Activity Log…") { Audit.export() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Show Log in Finder") { Audit.reveal() }
            }
            CommandMenu("Mac") {
                // Chosen from a menu on purpose, so it has no keyboard shortcut.
                Button("Breathe") {
                    show(.home)
                    Task { await model.breathe(source: "the menu") }
                }
                .disabled(model.phase == .inhale || model.phase == .exhale)
                Divider()
                ForEach(Array(AppModel.Screen.allCases.enumerated()), id: \.element) { index, screen in
                    Button(screen == .home ? "Overview" : screen.rawValue) { show(screen) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Divider()
                Button("Measure Storage Again") { show(.storage); Task { await model.measureStorage() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Aerilo Help") { NSWorkspace.shared.open(Links.help) }
                Button("Privacy Policy") { NSWorkspace.shared.open(Links.privacy) }
                Button("Source Code on GitHub") { NSWorkspace.shared.open(Links.source) }
                Divider()
                Button("Email Support…") { NSWorkspace.shared.open(Links.mail) }
            }
        }

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra {
            MenuPanel().environment(model)
        } label: {
            Label("\(model.sys.health)", systemImage: "wind").labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private func show(_ screen: AppModel.Screen) {
        model.screen = screen
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// Both widget sizes side by side, for a look at them without adding them to the desktop.
struct WidgetPreview: View {
    var body: some View {
        HStack(spacing: 24) {
            StatusWidgetView(reading: .sample, preview: .systemSmall)
                .padding(16).frame(width: 170, height: 170).background(WidgetSky()).clipShape(.rect(cornerRadius: 24))
            StatusWidgetView(reading: .sample, preview: .systemMedium)
                .padding(16).frame(width: 364, height: 170).background(WidgetSky()).clipShape(.rect(cornerRadius: 24))
        }
        .padding(40)
        .background(Color(white: 0.92))
    }
}

/// The menu bar panel: the same one button, without opening the window.
struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("welcomed") private var welcomed = false

    var body: some View {
        let busy = model.phase == .inhale || model.phase == .exhale
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.sys.healthWord).font(.system(.title2, design: .rounded, weight: .semibold))
                Spacer()
                Text("\(model.sys.health) of 100").font(.system(.title3, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            }
            if let reason = model.sys.healthReasons.first {
                Text("Mostly because \(reason).").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                stat("Memory", "\(Int(model.sys.memFraction * 100))%", model.sys.memFraction)
                stat("Processor", "\(Int(model.sys.cpuLoad * 100))%", model.sys.cpuLoad)
                stat("Storage free", Fmt.bytes(model.sys.diskFree), 1 - model.sys.diskFreeFraction)
            }
            if busy {
                Text(model.activity).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            } else if model.phase == .done, model.lastRun != nil {
                Text(model.advice?.headline ?? "Done.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                // The first run goes through the welcome sheet in the window.
                if welcomed { Task { await model.breathe(source: "the menu bar") } } else { open() }
            } label: {
                Label(busy ? "Breathing…" : "Breathe", systemImage: "wind").frame(maxWidth: .infinity).padding(.vertical, 3)
            }
            .buttonStyle(.glassProminent).controlSize(.large).disabled(busy)
            HStack {
                Button("Open Aerilo", action: open)
                Spacer()
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 280)
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate()
    }

    private func stat(_ name: String, _ value: String, _ fraction: Double) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(name).font(.callout)
                Spacer()
                Text(value).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            Meter(fraction: fraction, tint: fraction > 0.85 ? .orange : .accentColor)
        }
    }
}

/// `Aerilo --selftest` prints what this build can actually do on this Mac. It deletes nothing.
enum SelfTest {
    static func run() {
        print("sandboxed: \(Env.isSandboxed)")
        let sysProbe = SystemProbe(), procProbe = ProcessProbe()
        _ = sysProbe.read(); _ = procProbe.sample()
        Thread.sleep(forTimeInterval: 1)
        let s = sysProbe.read()
        let procs = procProbe.sample()
        print("memory: \(Fmt.mem(s.memUsed)) of \(Fmt.mem(s.memTotal)), pressure \(s.pressure), swap \(Fmt.mem(s.swapUsed))")
        print("cpu: \(Int(s.cpuLoad * 100))%  disk free: \(Fmt.bytes(s.diskFree)) of \(Fmt.bytes(s.diskTotal))  uptime: \(Fmt.uptime(s.uptime))  health: \(s.health)")
        print("network total: down \(Fmt.rate(s.netIn)) up \(Fmt.rate(s.netOut))")
        print("processes listed: \(procs.count), with readable usage: \(procProbe.readable), zombies: \(procs.filter(\.isZombie).count)")
        let top = procs.sorted { $0.footprint > $1.footprint }.prefix(3).map { "\(Fmt.mem($0.footprint)) cpu \(Int($0.cpu))%" }
        print("top three by memory (names withheld): \(top.joined(separator: " | "))")
        let net = NetworkProbe.sample()
        print("per-process network rows: \(net.count)")
        print("home access: \(Cleaner.home != nil)  temp access: \(Cleaner.tempRoot != nil)  temp root depth: \(Cleaner.tempRootPath.split(separator: "/").count), safe to clean inside: \(Cleaner.isSafeTarget(URL(fileURLWithPath: Cleaner.tempRootPath + "/X/com.google.Chrome.code_sign_clone")))")
        for item in Cleaner.items() {
            print("  [\(item.tier)] \(item.id): \(Fmt.bytes(Cleaner.measure(item)))\(item.blocker(procs).map { " (blocked: \($0))" } ?? "")")
        }
        // The delete path, on a scratch folder: contents go, the folder stays, and a symlink is
        // removed without touching what it points at.
        let fm = FileManager.default
        let scratch = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("aerilo-selftest-\(getpid())")
        let cache = scratch.appendingPathComponent("cache"), outside = scratch.appendingPathComponent("outside")
        try? fm.createDirectory(at: cache.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try? Data(count: 200_000).write(to: cache.appendingPathComponent("sub/a.bin"))
        try? Data(count: 10).write(to: outside.appendingPathComponent("keep.txt"))
        try? fm.createSymbolicLink(at: cache.appendingPathComponent("link"), withDestinationURL: outside)
        let probe = CleanItem(id: "t", name: "t", detail: "", tier: .safe, kind: .contents([cache]))
        let before = Cleaner.measure(probe)
        Cleaner.clean(probe)
        let left = (try? fm.contentsOfDirectory(atPath: cache.path).count) ?? -1
        print("clean test: measured \(before) bytes, items left \(left), folder kept \(fm.fileExists(atPath: cache.path)), symlink target kept \(fm.fileExists(atPath: outside.appendingPathComponent("keep.txt").path))")
        try? fm.removeItem(at: scratch)
        let refused = ["/", "/Users", Env.realHome.path, Env.realHome.path + "/Documents", Env.realHome.path + "/Library",
                       Env.realHome.path + "/Library/Caches/../../Documents/x", "/private/var/folders", "/System/Library/Caches/x"]
        print("guard refuses unsafe paths: \(refused.allSatisfy { !Cleaner.isSafeTarget(URL(fileURLWithPath: $0)) })")
        let real = Cleaner.items().flatMap { item -> [URL] in
            switch item.kind { case .contents(let u), .folders(let u): return u; default: return [] }
        }
        print("guard accepts every catalogue path: \(real.allSatisfy(Cleaner.isSafeTarget))  (\(real.count) paths)")
        for u in real where !Cleaner.isSafeTarget(u) { print("  refused: …/\(u.pathComponents.suffix(3).joined(separator: "/"))") }
        print("unused simulator runtimes: \(Cleaner.unusedRuntimes().count)  macOS update waiting: \(Cleaner.hasPreparedUpdate())")
        print("full disk access: \(Permissions.hasFullDiskAccess)  opens at login: \(Permissions.launchesAtLogin)")
        print("version compare: \(Updater.isNewer("1.10.0", than: "1.9.2") && !Updater.isNewer("1.0.0", than: "1.0.0") && !Updater.isNewer("1.0", than: "1.0.1"))")
        Audit.record("selftest", ["note": "first"])
        Audit.record("selftest", ["note": "second"])
        _ = Audit.entries() // waits until both entries are on disk
        // A copy with one value edited must be reported as changed.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("aerilo-audit-\(getpid()).jsonl")
        if let text = try? String(contentsOf: Audit.fileURL, encoding: .utf8) {
            try? text.replacingOccurrences(of: "\"note\":\"first\"", with: "\"note\":\"edited\"").write(to: copy, atomically: true, encoding: .utf8)
        }
        print("log detects an edited entry: \(Audit.entries(at: copy).contains { !$0.intact })")
        try? FileManager.default.removeItem(at: copy)
        let log = Audit.entries()
        print("log: \(log.count) entries, \(log.filter { !$0.intact }.count) broken, at …/\(Audit.fileURL.pathComponents.suffix(3).joined(separator: "/"))")
        if let folder = Env.arg("--photo-compare") {
            func load(_ name: String) -> PhotoScanner.Look? {
                NSImage(contentsOfFile: "\(folder)/\(name)")?.cgImage(forProposedRect: nil, context: nil, hints: nil).map { PhotoScanner.look(at: $0) }
            }
            let burst = (0..<3).compactMap { load("burst-\($0).jpg") }
            let singles = (0..<3).compactMap { load("single-\($0).jpg") }
            func hashOnly(_ l: PhotoScanner.Look) -> PhotoScanner.Look { PhotoScanner.Look(print: nil, hash: l.hash) }
            if burst.count == 3, singles.count == 3 {
                let pairs = [(burst[0], burst[1]), (burst[1], burst[2])]
                let strangers = [(burst[2], singles[0]), (singles[0], singles[1]), (singles[1], singles[2])]
                print("feature prints available here: \(burst[0].print != nil)")
                print("burst shots judged alike: with prints \(pairs.allSatisfy { PhotoScanner.alike($0.0, $0.1) }), hash only \(pairs.allSatisfy { PhotoScanner.alike(hashOnly($0.0), hashOnly($0.1)) })")
                print("unrelated pictures kept apart: with prints \(strangers.allSatisfy { !PhotoScanner.alike($0.0, $0.1) }), hash only \(strangers.allSatisfy { !PhotoScanner.alike(hashOnly($0.0), hashOnly($0.1)) })")
                func gap(_ a: PhotoScanner.Look, _ b: PhotoScanner.Look) -> String {
                    var d: Float = -1
                    if let pa = a.print, let pb = b.print { try? pa.computeDistance(&d, to: pb) }
                    return String(format: "%.2f", d)
                }
                print("feature print distances: burst \(pairs.map { gap($0.0, $0.1) }), unrelated \(strangers.map { gap($0.0, $0.1) })")
                print("hash bit differences: burst \(pairs.map { ($0.0.hash! ^ $0.1.hash!).nonzeroBitCount }), unrelated \(strangers.map { ($0.0.hash! ^ $0.1.hash!).nonzeroBitCount })")
            } else {
                print("photo compare: test pictures not found in \(folder)")
            }
        }
        // Reading what a helper process is from its own label.
        let cases: [(String, String, AppInsight.Kind, String)] = [
            ("Google Chrome Helper (Renderer)", "/A/Chrome Helper --type=renderer --lang=en", .tabs, "Tab or window"),
            ("Google Chrome Helper (Renderer)", "/A/Chrome Helper --type=renderer --extension-process", .extensions, "Extension"),
            ("Google Chrome Helper (GPU)", "/A/Helper --type=gpu-process", .graphics, "Graphics"),
            ("Google Chrome Helper", "/A/Helper --type=utility --utility-sub-type=network.mojom.NetworkService", .services, "Network"),
            ("Code Helper (Plugin)", "/A/Code Helper --type=utility --utility-sub-type=node.mojom.NodeService", .extensions, "Extension host"),
            ("node", "/usr/bin/node /Users/x/.vscode/extensions/ms-python.vscode-pylance-2026.1.1/dist/server.js", .tools, "ms-python.vscode-pylance"),
            ("rust-analyzer", "/Users/x/.cursor/extensions/rust-lang.rust-analyzer-0.3.2/server/rust-analyzer", .tools, "rust-lang.rust-analyzer"),
        ]
        let read = cases.allSatisfy { c in
            let r = Insights.classify(name: c.0, arguments: c.1, isMain: false, insideApp: true)
            return r.kind == c.2 && r.title == c.3
        }
        // A child of a child, outside the bundle, still belongs to the app.
        var a = ProcInfo(pid: 10, name: "Code"); a.ownerApp = "Code"
        var b = ProcInfo(pid: 11, name: "Code Helper (Plugin)"); b.ownerApp = "Code"; b.parent = 10
        var c = ProcInfo(pid: 12, name: "node"); c.parent = 11; c.footprint = 5
        var d = ProcInfo(pid: 13, name: "unrelated"); d.parent = 1
        let tree = Insights.build(app: "Code", mainPID: 10, procs: [a, b, c, d]) { pid in pid == 12 ? "node /Users/x/.vscode/extensions/dbaeumer.vscode-eslint-3.0.1/server.js" : pid == 11 ? "--type=utility --utility-sub-type=node.mojom.NodeService" : "" }
        let grouped = tree.sections.flatMap(\.parts).count == 3 && tree.sections.contains { $0.kind == .tools && $0.parts.first?.title == "dbaeumer.vscode-eslint" }
        print("look inside: reads helper labels \(read), follows the tools an app starts \(grouped)")
        if CommandLine.arguments.contains("--inside") {
            // The two largest multi-process apps running now, by kind of helper. Names are not printed.
            var byApp: [String: (count: Int, bytes: UInt64, main: pid_t?)] = [:]
            for p in procs {
                let key = p.ownerApp ?? p.name
                var e = byApp[key] ?? (0, 0, nil)
                e.count += 1; e.bytes += p.footprint
                if p.ownerApp != nil, p.name == key { e.main = p.pid }
                byApp[key] = e
            }
            for (index, entry) in byApp.filter({ $0.value.count >= 4 }).sorted(by: { $0.value.bytes > $1.value.bytes }).prefix(3).enumerated() {
                let insight = Insights.build(app: entry.key, mainPID: entry.value.main, procs: procs)
                let parts = insight.sections.map { "\($0.kind.rawValue) x\($0.parts.count) \(Fmt.mem($0.footprint))" }.joined(separator: " | ")
                print("inside app \(index + 1) (\(Fmt.mem(insight.total))): \(parts)")
            }
        }
        let timing = DispatchSemaphore(value: 0)
        Task.detached {
            let began = Date()
            let stuck: Int? = await Timeout.run(seconds: 1) {
                // Work that ignores cancellation, like a model call that never answers.
                await Task.detached { Thread.sleep(forTimeInterval: 3) }.value
                return 1
            }
            let quick: Int? = await Timeout.run(seconds: 5) { 7 }
            print("timeout gives up on stuck work: \(stuck == nil && Date().timeIntervalSince(began) < 2)  passes a result through: \(quick == 7)")
            timing.signal()
        }
        timing.wait()
        switch Advisor.status {
        case .ready: print("on-device model: ready")
        case .unavailable(let why): print("on-device model: unavailable (\(why))")
        }
        if CommandLine.arguments.contains("--ai") {
            let findings = [
                Finding(id: "mem-Browser", icon: "", title: "Browser holds 7.6 GB", detail: "31% of this Mac's memory across 31 processes. Memory is tight right now.", severity: 2, actionLabel: "Quit Browser"),
                Finding(id: "uptime", icon: "", title: "Running for 12 days without a restart", detail: "A restart clears leaked memory.", severity: 1),
                Finding(id: "caches", icon: "", title: "47 GB of rebuildable caches", detail: "CocoaPods cache, Gradle caches.", severity: 1, actionLabel: "Clear"),
            ]
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let advice = await Advisor.plan(sys: s, findings: findings, freed: 3 << 30)
                print("advice source: \(advice.source)  headline: \(advice.headline)")
                for step in advice.steps { print("  - \(step.id): \(step.reason)") }
                done.signal()
            }
            done.wait()
            let photos = DispatchSemaphore(value: 0)
            Task.detached {
                let facts = PhotoAdvisor.facts([("Exact duplicates", 11, 46_000_000, 6), ("Similar shots", 22, 120_000_000, 16),
                                                ("Old screenshots", 48, 472_000_000, 48), ("Largest videos", 12, 17_800_000_000, 0)], total: 12_480)
                print("photo advice: \(await PhotoAdvisor.sentence(facts: facts) ?? "(model unavailable, plain summary is used)")")
                photos.signal()
            }
            photos.wait()
        }
    }
}

/// `Aerilo --breathe-test` runs the real Breathe sequence, start to finish, on a stand-in home
/// folder it builds and removes itself. Nothing outside that folder is read for cleaning or changed.
enum BreatheTest {
    static func run() -> Bool {
        guard Env.isHomeOverridden else {
            // Relaunch pointed at a fresh stand-in home, so `Env.realHome` is fixed before anything reads it.
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("aerilo-breathe-\(getpid())")
            build(home)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--breathe-test", "--home", home.path]
            try? child.run()
            child.waitUntilExit()
            try? FileManager.default.removeItem(at: home)
            return child.terminationStatus == 0
        }
        let home = Env.realHome
        var finished = false
        Task { @MainActor in
            await AppModel.shared.breathe(source: "the breathe test")
            finished = true
        }
        let deadline = Date().addingTimeInterval(90)
        while !finished, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }

        let fm = FileManager.default
        func left(_ path: String) -> Int { (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(path).path).count) ?? -1 }
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: home.appendingPathComponent(path).path) }
        let (freed, phase, steps, findings, advice) = MainActor.assumeIsolated {
            (AppModel.shared.lastFreed, AppModel.shared.phase, AppModel.shared.steps, AppModel.shared.findings.map(\.id), AppModel.shared.advice)
        }
        let log = Audit.entries()
        var ok = true
        func check(_ name: String, _ pass: Bool) {
            print("\(pass ? "pass" : "FAIL")  \(name)")
            if !pass { ok = false }
        }
        check("the sequence finished", finished && phase == .done)
        check("safe caches were emptied, folders kept", ["Library/Developer/Xcode/DerivedData", ".npm/_cacache", "Library/Caches/Homebrew", "Library/Caches/pip", "Library/Caches/com.example.app.ShipIt"].allSatisfy { left($0) == 0 })
        check("rebuildable caches were left for the user to choose", left("Library/Caches/CocoaPods") == 1 && left(".gradle/caches") == 1)
        check("documents and other folders were not touched", exists("Documents/keep.txt") && exists("Library/Caches/com.example.other/data.bin") && exists("Library/Application Support/App/data.bin"))
        check("reported the amount removed (\(Fmt.bytes(freed)))", freed > 10_000_000 && freed < 14_000_000)
        check("said what it was doing (\(steps.count) steps)", steps.contains { $0.hasPrefix("Clearing Xcode build data") } && steps.contains { $0.hasPrefix("Letting go") })
        _ = findings
        check("produced advice (\(advice?.source == .onDevice ? "on-device model" : "rules"))", advice != nil)
        check("logged every item cleared", log.filter { $0.event == "clean.item" }.count == 5 && log.contains { $0.event == "breathe.end" })
        check("the log is intact", !log.isEmpty && log.allSatisfy(\.intact))
        return ok
    }

    private static func build(_ home: URL) {
        let fm = FileManager.default
        func file(_ path: String, megabytes: Double) {
            let url = home.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(count: Int(megabytes * 1_000_000)).write(to: url)
        }
        file("Library/Developer/Xcode/DerivedData/Project-abc/Build/out.bin", megabytes: 5)
        file(".npm/_cacache/content/a.bin", megabytes: 3)
        file("Library/Caches/Homebrew/downloads/b.bin", megabytes: 2)
        file("Library/Caches/pip/c.bin", megabytes: 1)
        file("Library/Caches/com.example.app.ShipIt/update/d.bin", megabytes: 1)
        file("Library/Caches/CocoaPods/Pods/e.bin", megabytes: 4)        // rebuildable: must stay
        file(".gradle/caches/modules/f.bin", megabytes: 4)               // rebuildable: must stay
        file("Library/Caches/com.example.other/data.bin", megabytes: 1)  // not in the catalogue: must stay
        file("Library/Application Support/App/data.bin", megabytes: 1)   // app data: must stay
        file("Documents/keep.txt", megabytes: 0.001)                      // the user's: must stay
    }
}
