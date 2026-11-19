import Darwin
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Aerilo for iPhone, iPad, Apple TV and Vision Pro: the same one button, pointed at the photo
/// library. These systems don't let an app see or manage other apps, so this edition tidies photos
/// and shows the device's own health, and claims nothing more.
@main
struct AeriloMobileApp: App {
    @State private var model = PhotoModel.shared

    var body: some Scene {
        WindowGroup {
            MobileRoot().environment(model)
                // Lets scripts start a scan without a tap (scripts/test-ios.sh).
                .task { if CommandLine.arguments.contains("--autobreathe") { await model.breathe() } }
        }
    }
}

struct MobileRoot: View {
    @Environment(PhotoModel.self) private var model
    @State private var tab = Env.arg("--shot") == "device" ? 1 : Env.arg("--shot") == "log" ? 2 : 0
    @State private var path: [PhotoKind] = PhotoKind(rawValue: Env.arg("--shot") ?? "").map { [$0] } ?? []

    var body: some View {
        TabView(selection: $tab) {
            Tab("Breathe", systemImage: "wind", value: 0) {
                NavigationStack(path: $path) {
                    MobileHome { path.append($0) }
                        .navigationDestination(for: PhotoKind.self) { kind in
                            ZStack {
                                Aurora(lift: 1)
                                VStack(spacing: 0) {
                                    if let caption = Env.arg("--caption") { CaptionLine(text: caption).padding(.bottom, 10) }
                                    PhotoReview(kind: kind)
                                }
                            }
                            .navigationTitle(kind.title)
                            #if os(iOS)
                            .toolbarVisibility(.hidden, for: .tabBar) // the Delete bar takes its place
                            #endif
                        }
                }
            }
            Tab("Device", systemImage: "heart.text.square", value: 1) {
                DeviceView()
            }
            Tab("Log", systemImage: "list.bullet.rectangle", value: 2) {
                MobileLog()
            }
        }
    }
}

/// App Store search shows the first screenshots very small, so those carry one line of large
/// text in place of the usual heading (`--caption`). It sits on the app's own sky; nothing is framed.
struct CaptionLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 44, weight: .bold, design: .rounded))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
    }
}

struct MobileHome: View {
    @Environment(PhotoModel.self) private var model
    let open: (PhotoKind) -> Void

    private var label: String {
        switch model.phase {
        case .idle: return "Breathe"
        case .inhale: return "Breathing in"
        case .exhale: return "Letting go"
        case .done: return model.lastFreed > 0 ? Fmt.bytes(model.lastFreed) : model.groups.isEmpty ? "Clear" : Fmt.bytes(model.selectedBytes)
        }
    }

    private var sublabel: String {
        switch model.phase {
        case .idle: return "one tap to tidy your photos"
        case .inhale: return "looking through your library"
        case .exhale: return "gathering what could go"
        case .done: return model.lastFreed > 0 ? "freed · tap to look again" : model.groups.isEmpty ? "tap to look again" : "could be freed · tap to look again"
        }
    }

    /// A television is read from across the room: everything on the home screen is drawn larger there.
    private var scale: CGFloat {
        #if os(tvOS)
        return 1.45
        #elseif os(visionOS)
        return 1.3
        #else
        return 1
        #endif
    }

    var body: some View {
        let done = model.phase == .done
        let working = model.phase == .inhale || model.phase == .exhale
        ZStack {
            Aurora(lift: model.phase == .exhale || done ? 1 : 0)
            GeometryReader { screen in
            ScrollView {
                VStack(spacing: 0) {
                    if let caption = Env.arg("--caption") {
                        CaptionLine(text: caption).padding(.top, 8)
                    } else {
                    VStack(spacing: 6) {
                        Text(model.assetCount > 0 ? "\(model.assetCount.formatted()) PHOTOS AND VIDEOS" : "YOUR PHOTO LIBRARY")
                            .font(.system(size: 12 * scale, weight: .semibold, design: .rounded)).kerning(2)
                            .foregroundStyle(.secondary)
                        Text(done ? model.headline : "Let your library breathe")
                            .font(.system(size: (done ? 24 : 28) * scale, weight: .medium, design: .rounded))
                            .multilineTextAlignment(.center)
                            .contentTransition(.opacity)
                    }
                    .padding(.horizontal, 28).padding(.top, 12)
                    }

                    BreatheOrb(phase: model.phase, phaseStart: model.phaseStart, diameter: (done ? 140 : 220) * scale, label: label, sublabel: sublabel) {
                        Task { await model.breathe() }
                    }
                    .padding(.vertical, (done ? 24 : 48) * scale)

                    if working {
                        VStack(spacing: 5) {
                            ForEach(Array(model.steps.suffix(4).enumerated()), id: \.offset) { index, step in
                                let latest = index == min(model.steps.count, 4) - 1
                                Text(step)
                                    .font(.system(latest ? .body : .callout, design: .rounded, weight: latest ? .medium : .regular))
                                    .foregroundStyle(latest ? .primary : .tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(height: 100 * scale, alignment: .bottom)
                        .animation(.easeOut(duration: 0.25), value: model.steps.count)
                    } else if done {
                        VStack(spacing: 14) {
                            if model.access == .denied {
                                denied
                            } else if !model.groups.isEmpty {
                                PhotoSummary(open: open)
                                Text("Nothing is deleted until you review it and tap Delete.")
                                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            if model.access == .limited {
                                Text("Aerilo can only see the photos you chose. Allow all photos in Settings for a full look.")
                                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(maxWidth: 620 * scale)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        Text("Aerilo looks for duplicates, similar shots, old screenshots and large videos. Nothing is deleted until you choose.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .padding(.horizontal, 36).frame(maxWidth: 520)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 32)
                // On tall screens the orb sits in the middle while idle or working, and moves up for results.
                .frame(minHeight: done ? nil : screen.size.height, alignment: .center)
                .animation(.spring(duration: 0.9), value: done)
            }
            .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var denied: some View {
        VStack(spacing: 10) {
            Text("Aerilo needs to see your photos to find what could go. It never uploads them: everything is compared on this device.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .prominentButton()
            #endif
        }
        .glassCard()
    }
}

// MARK: - Device

struct DeviceView: View {
    @State private var free: Int64 = 0
    @State private var total: Int64 = 0
    @State private var thermal = ProcessInfo.processInfo.thermalState
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var battery: Float = -1
    @State private var memory: Double?
    @State private var processor: Double?

    private var thermalWord: String {
        switch thermal {
        case .nominal: return "Cool"
        case .fair: return "Warm"
        case .serious: return "Hot, slowing itself down"
        case .critical: return "Very hot"
        @unknown default: return "Unknown"
        }
    }

    var body: some View {
        ZStack {
            Aurora()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Device").font(.system(size: 30, weight: .semibold, design: .rounded))
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Storage", systemImage: "internaldrive").font(.system(.headline, design: .rounded))
                        Text("\(Fmt.bytes(free)) free of \(Fmt.bytes(total))").font(.system(.title3, design: .rounded)).monospacedDigit()
                        Meter(fraction: total > 0 ? 1 - Double(free) / Double(total) : 0, tint: total > 0 && Double(free) / Double(total) < 0.1 ? .orange : .accentColor)
                        Text("Photos and videos are usually the largest part. Breathe finds the ones you can let go.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard()

                    VStack(alignment: .leading, spacing: 12) {
                        load("memorychip", "Memory in use", memory)
                        load("cpu", "Processor load", processor)
                        Text("These are totals for the whole device. No app is allowed to see which apps are running or what each one uses.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard()

                    VStack(spacing: 0) {
                        row("thermometer.medium", "Temperature", thermalWord)
                        Divider().padding(.vertical, 10)
                        row("bolt", "Low Power Mode", lowPower ? "On" : "Off")
                        if battery >= 0 {
                            Divider().padding(.vertical, 10)
                            row("battery.75percent", "Battery", "\(Int(battery * 100))%")
                        }
                        Divider().padding(.vertical, 10)
                        row("clock.arrow.circlepath", "Running since restart", Fmt.uptime(ProcessInfo.processInfo.systemUptime))
                    }
                    .glassCard()

                    Text("This device manages memory and apps by itself, and no app is allowed to see or stop another one. That is why Aerilo here looks after storage, and the Mac edition looks after everything else.")
                        .font(.footnote).foregroundStyle(.secondary)
                    #if !os(tvOS)
                    HStack(spacing: 18) {
                        Link("Privacy", destination: URL(string: "https://aerilo.app/privacy.html")!)
                        Link("Support", destination: URL(string: "https://aerilo.app/support.html")!)
                        Link("Source", destination: URL(string: "https://github.com/oleche/aerilo-app")!)
                    }
                    .font(.footnote)
                    #endif
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            refresh()
            guard !Env.isDemo else { return }
            while !Task.isCancelled {
                memory = DeviceLoad.memoryFraction()
                processor = await DeviceLoad.processorFraction()   // takes one second
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func load(_ icon: String, _ name: String, _ fraction: Double?) -> some View {
        VStack(spacing: 5) {
            HStack {
                Label(name, systemImage: icon)
                Spacer()
                Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "…").monospacedDigit().foregroundStyle(.secondary)
            }
            Meter(fraction: fraction ?? 0, tint: (fraction ?? 0) > 0.85 ? .orange : .accentColor)
        }
    }

    private func row(_ icon: String, _ name: String, _ value: String) -> some View {
        HStack {
            Label(name, systemImage: icon)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        if Env.isDemo {
            free = 21_400_000_000; total = 256_000_000_000; battery = 0.82
            memory = 0.64; processor = 0.18
            return
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        #if os(tvOS)
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]) {
            free = Int64(values.volumeAvailableCapacity ?? 0)
            total = Int64(values.volumeTotalCapacity ?? 0)
        }
        #else
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            free = values.volumeAvailableCapacityForImportantUsage ?? 0
            total = Int64(values.volumeTotalCapacity ?? 0)
        }
        #endif
        thermal = ProcessInfo.processInfo.thermalState
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        battery = UIDevice.current.batteryLevel
        #endif
    }
}

// MARK: - Log

struct MobileLog: View {
    @Environment(PhotoModel.self) private var model
    @State private var entries: [Audit.Entry] = []

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        let broken = entries.filter { !$0.intact }.count
        ZStack {
            Aurora()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Log").font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("Everything Aerilo looked at and everything you asked it to delete. Share it with support, or keep it as a record.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        if entries.isEmpty {
                            Label("Nothing recorded yet", systemImage: "doc").foregroundStyle(.secondary)
                        } else if broken == 0 {
                            Label("\(entries.count) entries, unchanged", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        } else {
                            Label("\(broken) entries were changed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Spacer()
                        #if !os(tvOS)
                        ShareLink(item: Env.isDemo ? "Aerilo activity report" : Audit.report()) { Label("Share", systemImage: "square.and.arrow.up") }
                            .prominentButton()
                        #endif
                    }
                    .glassCard()

                    if !entries.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(entries.suffix(200).reversed().enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { Divider().padding(.vertical, 8) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Audit.title(entry)).font(.system(.callout, design: .rounded, weight: .medium))
                                    Text(Self.time.string(from: entry.time)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard()
                    }
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: model.phase) { await reload() }
        .task(id: model.lastDeleted) { await reload() }
    }

    private func reload() async {
        if Env.isDemo {
            let now = Date()
            let rows: [(String, [String: Any])] = [
                ("app.start", ["version": "1.0.0 (1)", "edition": Audit.edition, "os": "Version 27.1"]),
                ("photos.access", ["status": "allowed"]),
                ("photos.scan", ["assets": 12_480, "found": 67, "bytes": 331_000_000]),
                ("photos.delete", ["count": 48, "bytes": 104_000_000, "kinds": "Old screenshots"]),
                ("photos.delete", ["count": 6, "bytes": 24_000_000, "kinds": "Exact duplicates"]),
            ]
            entries = rows.enumerated().map { i, row in
                Audit.Entry(id: i, time: now.addingTimeInterval(Double(i - rows.count) * 40), event: row.0, detail: row.1, hash: "", intact: true)
            }
            return
        }
        entries = await Task.detached(priority: .utility) { Audit.entries() }.value
    }
}
