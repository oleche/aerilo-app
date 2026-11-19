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
                    : AnyView(RootView().environment(AppModel.shared))
                let host = NSHostingController(rootView: root)
                host.sceneBridgingOptions = [.toolbars, .title]
                let window = NSWindow(contentViewController: host)
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                window.titlebarAppearsTransparent = true
                window.title = "Aerilo"
                window.toolbarStyle = .unified
                window.appearance = NSAppearance(named: Env.arg("--appearance") == "dark" ? .darkAqua : .aqua)
                if shot != "welcome" && shot != "settings" { window.setContentSize(NSSize(width: 1440, height: 900)) }
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
                Text("\(model.sys.health)").font(.system(.title2, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
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
        print("home access: \(Cleaner.home != nil)")
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
        }
    }
}
