import SwiftUI

// MARK: - Permissions, shared by the welcome sheet and Settings

/// Every permission Aerilo can use, with its current state and the one control that changes it.
struct PermissionRows: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Notifier.enabledKey) private var notify = false
    @State private var atLogin = Permissions.launchesAtLogin
    @State private var fullDisk = Permissions.hasFullDiskAccess
    @State private var notifyDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if Env.isSandboxed {
                row("folder", "Home folder", "Needed to measure and clear caches. App Store apps can only touch folders you choose.",
                    state: model.hasHome ? "Allowed" : nil) {
                    Button("Allow…") { Task { await model.grantHome() } }
                }
            } else {
                row("externaldrive.badge.checkmark", "Full Disk Access", "Optional. Lets Aerilo clear other apps' leftovers without macOS asking each time.",
                    state: fullDisk ? "Allowed" : nil) {
                    Button("Open Settings") { Permissions.openFullDiskAccess() }
                }
            }
            row("bell", "Low-space warning", "Optional. A notification when storage or memory runs short. Aerilo never cleans by itself.", state: nil) {
                Toggle("", isOn: Binding(get: { notify }, set: { on in
                    guard on else { notify = false; return }
                    Task {
                        let ok = await Notifier.request()
                        notify = ok
                        notifyDenied = !ok
                    }
                })).labelsHidden().toggleStyle(.switch)
            }
            if notifyDenied {
                Button("Notifications are off for Aerilo. Open Notification Settings") { Permissions.openNotifications() }
                    .buttonStyle(.link).font(.callout)
            }
            row("power", "Open at login", "Optional. Keeps the menu bar icon and the warning available after a restart.", state: nil) {
                Toggle("", isOn: Binding(get: { atLogin }, set: { on in
                    Permissions.setLaunchAtLogin(on)
                    atLogin = Permissions.launchesAtLogin
                })).labelsHidden().toggleStyle(.switch)
            }
        }
        // Coming back from System Settings: read the state again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDisk = Permissions.hasFullDiskAccess
            atLogin = Permissions.launchesAtLogin
        }
    }

    private func row<Control: View>(_ icon: String, _ title: String, _ detail: String, state: String?, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.body, design: .rounded, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let state {
                Label(state, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else {
                control()
            }
        }
    }
}

struct WelcomeView: View {
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Aerilo").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("One button, **Breathe**, clears caches and leftovers that rebuild themselves and tells you what is slowing your Mac down. It never touches your documents and never quits an app by itself. Everything it does is written to a log you can read and share.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Permissions").font(.system(.headline, design: .rounded))
            PermissionRows()
            Text("You can change all of these later in Aerilo › Settings.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                // No keyboard shortcut: this is dismissed with a click, like everything that leads to cleaning.
                Button("Get Started", action: done).buttonStyle(.glassProminent).controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 560)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Notifier.thresholdKey) private var threshold = 15
    @AppStorage(Updater.autoKey) private var autoUpdate = true
    @State private var updater = Updater.shared

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRows()
            }
            Section("Warning") {
                Stepper("Warn when free storage drops below \(threshold) GB", value: $threshold, in: 5...100, step: 5)
            }
            Section("Updates") {
                if Updater.isAvailable {
                    Toggle("Check aerilo.app for a new version once a day", isOn: $autoUpdate)
                    HStack {
                        Text(updater.message.isEmpty ? "Aerilo \(updater.current)" : updater.message).foregroundStyle(.secondary)
                        Spacer()
                        if updater.release != nil { Button("Download") { updater.download() } }
                        Button(updater.checking ? "Checking…" : "Check Now") { Task { await updater.check() } }.disabled(updater.checking)
                    }
                } else {
                    Text("This edition is updated by the App Store.").foregroundStyle(.secondary)
                }
            }
            Section("Activity log") {
                HStack {
                    Text("Everything Aerilo measured, cleared and skipped.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { Audit.reveal() }
                    Button("Export…") { Audit.export() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Log screen

struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [Audit.Entry] = []

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        let broken = entries.filter { !$0.intact }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Log").font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Everything Aerilo measured, cleared, skipped and was asked to do. Share it with support, or keep it as an audit record.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if entries.isEmpty {
                        Label("Nothing recorded yet", systemImage: "doc").foregroundStyle(.secondary)
                    } else if broken == 0 {
                        Label("\(entries.count) entries, unchanged since they were written", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Label("\(broken) entries were changed outside Aerilo", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Show in Finder") { Audit.reveal() }.buttonStyle(.glass)
                    Button("Export…") { Audit.export(); reload() }.buttonStyle(.glassProminent)
                }
                .glassCard()

                if !entries.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        // Newest first; the file keeps everything, the screen shows the latest 300.
                        ForEach(Array(entries.suffix(300).reversed().enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider() }
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: entry.intact ? icon(entry.event) : "exclamationmark.triangle")
                                    .foregroundStyle(entry.intact ? Color.secondary : Color.orange).frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Audit.title(entry)).font(.system(.callout, design: .rounded, weight: .medium))
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let paths = entry.detail["paths"] as? [String], !paths.isEmpty {
                                        Text(paths.joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.tertiary)
                                            .lineLimit(4).truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 12)
                                Text(Self.time.string(from: entry.time)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            .textSelection(.enabled)
                        }
                    }
                    .glassCard()
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .task(id: model.phase) { reload() }
    }

    private func reload() {
        Task {
            let loaded = Env.isDemo ? Demo.log() : await Task.detached(priority: .utility) { Audit.entries() }.value
            entries = loaded
        }
    }

    private func icon(_ event: String) -> String {
        switch event {
        case "clean.item", "clean.done": return "sparkles"
        case "clean.skipped": return "forward"
        case "action.quit": return "xmark.circle"
        case "scan": return "gauge.with.dots.needle.50percent"
        case "breathe.start", "breathe.end": return "wind"
        case "update.check": return "arrow.down.circle"
        case "notify": return "bell"
        default: return "circle"
        }
    }
}
