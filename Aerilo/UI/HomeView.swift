import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("welcomed") private var welcomed = false

    var body: some View {
        @Bindable var model = model
        ZStack {
            Aurora(lift: model.phase == .exhale || model.phase == .done ? 1 : 0)
            Group {
                switch model.screen {
                case .home: HomeView()
                case .activity: ActivityView()
                case .network: NetworkView()
                case .storage: StorageView()
                case .assistant: AssistantView()
                case .log: LogView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.35), value: model.screen)
        .frame(minWidth: 860, minHeight: 620)
        // A standard window: title bar, close, minimise and full-screen buttons, and a native toolbar.
        .navigationTitle("Aerilo")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $model.screen) {
                    ForEach(AppModel.Screen.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(isPresented: Binding(get: { !welcomed && !Env.isDemo }, set: { if !$0 { welcomed = true } })) {
            WelcomeView { welcomed = true }
        }
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var model

    private var orbLabel: String {
        switch model.phase {
        case .idle: return "Breathe"
        case .inhale: return "Breathing in"
        case .exhale: return "Letting go"
        case .done: return model.lastFreed > 0 ? Fmt.bytes(model.lastFreed) : "Clear"
        }
    }

    private var orbSublabel: String {
        switch model.phase {
        case .idle: return "one tap to clear the air"
        case .inhale: return "finding what weighs on your Mac"
        case .exhale: return "releasing what it doesn't need"
        case .done: return model.lastFreed > 0 ? "cleared · tap to breathe again" : "nothing to clear · tap to breathe again"
        }
    }

    var body: some View {
        let done = model.phase == .done
        let working = model.phase == .inhale || model.phase == .exhale
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Text(model.sys.healthWord.uppercased())
                    .font(.system(.caption, design: .rounded, weight: .semibold)).kerning(2.5)
                    .foregroundStyle(.secondary)
                Text(done ? (model.advice?.headline ?? "Your Mac can breathe again.") : "Your Mac is at \(model.sys.health)")
                    .font(.system(size: done ? 26 : 30, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 40)

            BreatheOrb(phase: model.phase, phaseStart: model.phaseStart, diameter: done ? 150 : 230,
                       label: orbLabel, sublabel: orbSublabel) {
                Task { await model.breathe() }
            }
            .padding(.vertical, done ? 26 : 44)

            if working {
                // No mystery: say what is happening, and keep the last steps in view.
                VStack(spacing: 5) {
                    ForEach(Array(model.steps.suffix(4).enumerated()), id: \.offset) { index, step in
                        let latest = index == min(model.steps.count, 4) - 1
                        Text(step)
                            .font(.system(latest ? .body : .callout, design: .rounded, weight: latest ? .medium : .regular))
                            .foregroundStyle(latest ? .primary : .tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(height: 96, alignment: .bottom)
                .animation(.easeOut(duration: 0.25), value: model.steps.count)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.activity)
            } else if done {
                VStack(spacing: 12) {
                    if let advice = model.advice, !advice.steps.isEmpty {
                        AdviceCard(advice: advice, limit: 3).frame(maxWidth: 620)
                    }
                    Button("See everything Aerilo just did") { model.screen = .log }
                        .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                GlassEffectContainer(spacing: 14) {
                    HStack(spacing: 14) {
                        Chip(icon: "memorychip", value: "\(Int(model.sys.memFraction * 100))%", label: "memory in use")
                        Chip(icon: "cpu", value: "\(Int(model.sys.cpuLoad * 100))%", label: "processor")
                        Chip(icon: "internaldrive", value: Fmt.bytes(model.sys.diskFree), label: "storage free")
                    }
                }
                .frame(height: 96, alignment: .top)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 28)
        .animation(.spring(duration: 0.9), value: done)
    }
}

/// The assistant's ordered suggestions, each with its one fix.
struct AdviceCard: View {
    @Environment(AppModel.self) private var model
    let advice: Advice
    var limit: Int = .max

    var body: some View {
        let steps = advice.steps.compactMap { step in model.findings.first { $0.id == step.id }.map { ($0, step.reason) } }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.prefix(limit).enumerated()), id: \.element.0.id) { index, pair in
                if index > 0 { Divider().padding(.vertical, 10) }
                FindingRow(finding: pair.0, reason: pair.1)
            }
            if steps.count > limit {
                Divider().padding(.vertical, 10)
                Button("See all \(steps.count) suggestions") { model.screen = .assistant }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            }
        }
        .glassCard()
    }
}

struct FindingRow: View {
    @Environment(AppModel.self) private var model
    let finding: Finding
    let reason: String
    @State private var busy = false

    private var tint: Color { finding.severity >= 3 ? .red : finding.severity == 2 ? .orange : .secondary }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: finding.icon).font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).font(.system(.body, design: .rounded, weight: .semibold))
                Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let label = finding.actionLabel {
                Button {
                    busy = true
                    Task { await model.perform(finding); busy = false }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text(label) }
                }
                .buttonStyle(.glass)
                .disabled(busy)
            }
        }
    }
}
