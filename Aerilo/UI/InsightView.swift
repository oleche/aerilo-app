import SwiftUI

/// "Look inside" an app: its helper processes grouped by what they do, and, in the download
/// edition, a way to end a single tab or tool without quitting the whole app.
struct InsightView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: AppGroup
    @State private var insight: AppInsight?
    @State private var advice: String?
    @State private var ending: AppInsight.Part?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Inside \(group.name)").font(.system(size: 24, weight: .semibold, design: .rounded))
                    if let insight {
                        Text("\(Fmt.mem(insight.total)) across \(insight.sections.reduce(0) { $0 + $1.parts.count }) processes")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glass)
            }
            .padding(.bottom, 14)

            if let insight {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: advice == nil ? "text.magnifyingglass" : "apple.intelligence").foregroundStyle(.secondary)
                    Text(advice ?? insight.summary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(radius: 18, padding: 14)
                .padding(.bottom, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(insight.sections) { section in
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Label(section.kind.rawValue, systemImage: section.kind.icon).font(.system(.headline, design: .rounded))
                                    Spacer()
                                    Text(Fmt.mem(section.footprint)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                Text(section.kind.note).font(.caption).foregroundStyle(.secondary).padding(.top, 2).padding(.bottom, 8)
                                // The heaviest few; the rest are added up so the list stays readable.
                                ForEach(section.parts.prefix(8)) { part in
                                    Divider()
                                    HStack(spacing: 10) {
                                        Text(part.title).lineLimit(1)
                                        Spacer()
                                        Text(String(format: "%.0f%%", part.cpu)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                                        Text(Fmt.mem(part.footprint)).monospacedDigit().frame(width: 84, alignment: .trailing)
                                        if part.canEnd, !Env.isSandboxed {
                                            Button(section.kind == .tabs ? "Free" : "End") { ending = part }
                                                .buttonStyle(.glass).controlSize(.small)
                                                .help(section.kind == .tabs ? "Ends this tab's process. The tab stays; reload it when you need it." : "Ends this helper. The app starts it again when it needs it.")
                                        }
                                    }
                                    .font(.callout)
                                    .padding(.vertical, 6)
                                }
                                if section.parts.count > 8 {
                                    Divider()
                                    Text("and \(section.parts.count - 8) smaller ones, \(Fmt.mem(section.parts.dropFirst(8).reduce(0) { $0 + $1.footprint })) together")
                                        .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                                }
                            }
                            .glassCard(radius: 20, padding: 14)
                        }
                        if Env.isSandboxed {
                            Text("Aerilo can show what is inside \(group.name). To free a tab, close it in \(group.name).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .scrollIndicators(.never)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(22)
        .frame(width: 620, height: 640)
        .task(id: model.procs.count) { await load() }
        .confirmationDialog(ending.map { "End \($0.title.lowercased()) in \(group.name)?" } ?? "", isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }), presenting: ending) { part in
            Button("Free \(Fmt.mem(part.footprint))") {
                model.end(pid: part.pid, born: part.born, title: part.title, app: group.name)
                Task { try? await Task.sleep(for: .seconds(1.2)); await model.refresh(); await load() }
            }
        } message: { _ in
            Text("Anything typed into that tab and not saved is lost. The rest of \(group.name) keeps running.")
        }
    }

    private func load() async {
        if Env.isDemo {
            insight = Demo.insight(for: group.name)
        } else {
            let procs = model.procs, name = group.name, main = group.mainPID
            insight = await Task.detached(priority: .userInitiated) { Insights.build(app: name, mainPID: main, procs: procs) }.value
        }
        if advice == nil, let insight { advice = Env.isDemo ? Demo.insightAdvice : await Advisor.explain(insight) }
    }
}
