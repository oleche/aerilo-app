import SwiftUI

private struct Page<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Activity

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var byCPU = false
    @State private var confirm: AppGroup?

    var body: some View {
        let sorted = model.groups.sorted { byCPU ? $0.cpu > $1.cpu : $0.footprint > $1.footprint }.prefix(14)
        Page(title: "Activity", subtitle: "Apps and background processes, heaviest first. Helpers are counted with their app.") {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Chip(icon: "memorychip", value: "\(Fmt.mem(model.sys.memUsed)) of \(Fmt.mem(model.sys.memTotal))",
                         label: model.sys.pressure >= 4 ? "memory · critical pressure" : model.sys.pressure >= 2 ? "memory · high pressure" : "memory · normal pressure")
                    Chip(icon: "cpu", value: "\(Int(model.sys.cpuLoad * 100))%", label: "processor load")
                    Chip(icon: "arrow.left.arrow.right", value: Fmt.mem(model.sys.swapUsed), label: "moved to disk")
                }
            }

            if !model.processesReadable {
                Label("macOS hides other apps' memory and processor use from App Store apps. The version from aerilo.app shows every process and can stop the ones that are stuck.", systemImage: "info.circle").foregroundStyle(.secondary).glassCard()
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(model.procs.count) processes").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Sort", selection: $byCPU) {
                            Text("Memory").tag(false)
                            Text("Processor").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    .padding(.bottom, 12)
                    ForEach(Array(sorted)) { group in
                        Divider()
                        row(group)
                    }
                }
                .glassCard()
            }
        }
        .confirmationDialog("Force \(confirm?.name ?? "") to quit?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { group in
            Button("Force Quit", role: .destructive) {
                if let pid = group.mainPID { model.stop(pid: pid, force: true) }
                Task { try? await Task.sleep(for: .seconds(1)); await model.refresh() }
            }
        } message: { _ in
            Text("Unsaved changes in it will be lost.")
        }
    }

    @ViewBuilder
    private func row(_ group: AppGroup) -> some View {
        let members = model.procs.filter { ($0.ownerApp ?? $0.name) == group.name }
        let canStop = (group.isApp || !Env.isSandboxed) && !Rules.protected.contains(group.name)
        HStack(spacing: 12) {
            Group {
                if let icon = model.icon(for: group.isApp ? group.mainPID : nil) {
                    Image(nsImage: icon).resizable()
                } else {
                    if group.isApp {
                        // No icon available: a tile tinted from the name, so rows stay distinguishable.
                        RoundedRectangle(cornerRadius: 7).fill(Color(hue: Double(group.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360, saturation: 0.45, brightness: 0.9).gradient)
                            .overlay(Text(group.name.prefix(1)).font(.system(.callout, design: .rounded, weight: .bold)).foregroundStyle(.white))
                    } else {
                        Image(systemName: "gearshape.fill").resizable().scaledToFit().padding(5).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.name).font(.system(.body, design: .rounded, weight: .medium)).lineLimit(1)
                    if members.contains(where: \.isRunaway) { Badge(text: "Stuck", color: .red) }
                    if members.contains(where: { $0.growth != nil }) { Badge(text: "Memory growing", color: .orange) }
                    if members.contains(where: \.isZombie) { Badge(text: "Unfinished", color: .gray) }
                }
                Text(group.count == 1 ? "1 process" : "\(group.count) processes").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%.0f%%", group.cpu)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.mem(group.footprint)).monospacedDigit()
                Meter(fraction: Double(group.footprint) / Double(max(1, model.sys.memTotal)) * 3,
                      tint: group.footprint > model.sys.memTotal / 8 ? .orange : .accentColor)
            }
            .frame(width: 96)
            Menu {
                Button("Quit") {
                    if let pid = group.mainPID { model.stop(pid: pid, force: false) }
                    Task { try? await Task.sleep(for: .seconds(1.5)); await model.refresh() }
                }
                Button("Force Quit…", role: .destructive) { confirm = group }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(!canStop)
            .help(canStop ? "Quit or force quit" : "macOS needs this one")
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Network

struct NetworkView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page(title: "Network", subtitle: "What is using your connection right now.") {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Chip(icon: "arrow.down", value: Fmt.rate(model.sys.netIn), label: "download")
                    Chip(icon: "arrow.up", value: Fmt.rate(model.sys.netOut), label: "upload")
                }
            }
            if NetworkProbe.isAvailable || Env.isDemo {
                VStack(spacing: 0) {
                    if model.net.isEmpty {
                        Text("Nothing is using the network at the moment.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let peak = model.net.first?.total ?? 1
                    ForEach(Array(model.net.prefix(12).enumerated()), id: \.element.id) { index, p in
                        if index > 0 { Divider() }
                        HStack(spacing: 12) {
                            Text(p.name).font(.system(.body, design: .rounded, weight: .medium)).lineLimit(1)
                            Spacer()
                            Label(Fmt.rate(p.bytesIn), systemImage: "arrow.down").monospacedDigit().foregroundStyle(.secondary).frame(width: 130, alignment: .trailing)
                            Label(Fmt.rate(p.bytesOut), systemImage: "arrow.up").monospacedDigit().foregroundStyle(.secondary).frame(width: 130, alignment: .trailing)
                            Meter(fraction: p.total / peak).frame(width: 80)
                        }
                        .font(.callout)
                        .padding(.vertical, 9)
                    }
                }
                .glassCard()
            } else {
                Label("The App Store version shows total traffic. Per-app traffic needs the version from aerilo.app, because macOS only shares it outside the App Store sandbox.", systemImage: "info.circle")
                    .foregroundStyle(.secondary).glassCard()
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refreshNetwork()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

// MARK: - Storage

struct StorageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let chosen = model.items.filter { model.selected.contains($0.id) && $0.tier != .ask && $0.blocker(model.procs) == nil }
        let total = chosen.reduce(Int64(0)) { $0 + (model.sizes[$1.id] ?? 0) }
        Page(title: "Storage", subtitle: "\(Fmt.bytes(model.sys.diskFree)) free of \(Fmt.bytes(model.sys.diskTotal)). Aerilo measures first and deletes only what you tick.") {
            if Env.isSandboxed, !model.hasHome {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Allow your Home folder").font(.system(.body, design: .rounded, weight: .semibold))
                        Text("App Store apps can only touch folders you choose. Aerilo uses it to measure and clear caches, nothing else.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Allow…") {
                        Task { await model.grantHome() }
                    }
                    .buttonStyle(.glassProminent)
                }
                .glassCard()
            }

            ForEach(Tier.allCases, id: \.self) { tier in
                let rows = model.items.filter { $0.tier == tier && ((model.sizes[$0.id] ?? 0) > 0 || model.measuring) }
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(tier.title).font(.system(.headline, design: .rounded))
                            Spacer()
                            Text(tier.note).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 10)
                        ForEach(rows) { item in
                            Divider()
                            row(item)
                        }
                    }
                    .glassCard()
                }
            }

            if !model.measuring, model.items.allSatisfy({ (model.sizes[$0.id] ?? 0) == 0 }), model.hasHome || !Env.isSandboxed {
                Label("Nothing to clear. This Mac is tidy.", systemImage: "checkmark.circle").foregroundStyle(.secondary).glassCard()
            }

            HStack {
                if model.measuring { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
                Spacer()
                Button {
                    Task { model.lastFreed = await model.clean(ids: Set(chosen.map(\.id))); model.activity = "" }
                } label: {
                    Text(model.cleaning ? "Clearing…" : total == 0 ? "Nothing selected" : "Clear \(Fmt.bytes(total))").padding(.horizontal, 10)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(total == 0 || model.cleaning || model.measuring)
            }
        }
        .task { await model.measureStorage() }
    }

    @ViewBuilder
    private func row(_ item: CleanItem) -> some View {
        let blocked = item.blocker(model.procs)
        HStack(spacing: 12) {
            if case .reveal(let url) = item.kind {
                Image(systemName: "hand.raised").foregroundStyle(.secondary).frame(width: 20)
                label(item, blocked: nil)
                Spacer()
                size(item)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.glass)
            } else {
                Toggle(isOn: Binding(get: { model.selected.contains(item.id) },
                                     set: { if $0 { model.selected.insert(item.id) } else { model.selected.remove(item.id) } })) {
                    label(item, blocked: blocked)
                }
                .toggleStyle(.checkbox)
                .disabled(blocked != nil)
                Spacer()
                size(item)
            }
        }
        .padding(.vertical, 9)
    }

    private func label(_ item: CleanItem, blocked: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name).font(.system(.body, design: .rounded, weight: .medium))
            Text(blocked.map { "Skipped: \($0)." } ?? item.detail).font(.caption).foregroundStyle(blocked == nil ? Color.secondary : Color.orange)
        }
        .padding(.leading, 4)
    }

    private func size(_ item: CleanItem) -> some View {
        Text(model.sizes[item.id].map { Fmt.bytes($0) } ?? "…").monospacedDigit().foregroundStyle(.secondary)
    }
}

// MARK: - Assistant

struct AssistantView: View {
    @Environment(AppModel.self) private var model
    @State private var question = ""
    @State private var answer: String?
    @State private var thinking = false

    var body: some View {
        let ready = Advisor.isReady || Env.isDemo
        Page(title: "Assistant", subtitle: "Aerilo reads the measurements and decides what helps most. It thinks on this Mac; nothing is sent anywhere.") {
            HStack(spacing: 10) {
                Image(systemName: ready ? "apple.intelligence" : "list.bullet.clipboard").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ready ? "Reasoning with Apple Intelligence, on device" : "Using built-in rules")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                    if case .unavailable(let why) = Advisor.status, !Env.isDemo {
                        Text(why).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    Task { await model.breathe(source: "the assistant"); model.screen = .assistant }
                } label: { Label("Check again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.glass)
                    .disabled(model.phase == .inhale || model.phase == .exhale)
            }
            .glassCard()

            if let advice = model.advice {
                Text(advice.headline).font(.system(.title2, design: .rounded, weight: .medium)).padding(.top, 4)
                if advice.steps.isEmpty {
                    Label("Nothing needs your attention.", systemImage: "checkmark.circle").foregroundStyle(.secondary).glassCard()
                } else {
                    AdviceCard(advice: advice)
                }
            } else {
                Text("Run Breathe once and the assistant will explain what it found.").foregroundStyle(.secondary).glassCard()
            }

            if ready {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("Ask about this Mac, like “Why is it slow today?”", text: $question)
                            .textFieldStyle(.plain)
                            .onSubmit(ask)
                        if thinking { ProgressView().controlSize(.small) }
                        Button("Ask", action: ask).buttonStyle(.glass).disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || thinking)
                    }
                    if let answer {
                        Divider()
                        Text(answer).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .glassCard()
            }
        }
        .onAppear { if Env.isDemo { answer = Demo.answer; question = Demo.question } }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !thinking, !Env.isDemo else { return }
        thinking = true
        Task {
            if model.findings.isEmpty { model.rebuildFindings() }
            answer = await Advisor.answer(q, sys: model.sys, findings: model.findings, freed: model.lastFreed)
                ?? "The on-device model couldn't answer that just now. Try again in a moment."
            thinking = false
        }
    }
}
