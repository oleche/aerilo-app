import AppIntents
import Foundation
import FoundationModels

/// What the assistant recommends: the findings in the order to act on them, each with a reason.
struct Advice {
    enum Source { case onDevice, rules }
    struct Step: Identifiable {
        let id: String
        let reason: String
    }
    var headline: String
    var steps: [Step]
    var source: Source

    func keeping(_ ids: [String]) -> Advice {
        var copy = self
        copy.steps = steps.filter { ids.contains($0.id) }
        return copy
    }
}

@Generable
struct ModelPlan {
    @Guide(description: "One calm sentence of at most 14 words on how this Mac is doing.")
    var headline: String
    @Guide(description: "The findings worth acting on, most helpful first. Use only ids from the list.")
    var steps: [ModelStep]
}

@Generable
struct ModelStep {
    @Guide(description: "The id of one finding, copied exactly.")
    var id: String
    @Guide(description: "One short sentence in your own plain words on why acting on it helps. Do not repeat the finding text.")
    var reason: String
}

/// Aerilo's reasoning runs on Apple's on-device model only (`SystemLanguageModel`). Nothing about
/// the Mac leaves it. The model chooses and explains; it can only pick from findings the rules
/// already produced, so it can never invent an action.
enum Advisor {
    enum Status {
        case ready
        case unavailable(String)
    }

    static var status: Status {
        switch SystemLanguageModel.default.availability {
        case .available: return .ready
        case .unavailable(.deviceNotEligible): return .unavailable("This Mac doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable("Turn on Apple Intelligence in System Settings to get reasoned advice.")
        case .unavailable(.modelNotReady): return .unavailable("Apple Intelligence is still downloading its model.")
        case .unavailable: return .unavailable("Apple Intelligence isn't available right now.")
        }
    }

    static var isReady: Bool { if case .ready = status { return true } else { return false } }

    private static let instructions = """
    You are Aerilo, a calm assistant that keeps one Mac running well. You are given measurements and a \
    list of findings that Aerilo already verified. Decide which findings matter most for speed right now \
    and in which order to handle them. Prefer the least disruptive fix that solves the problem. Never \
    suggest anything that is not in the findings. Use short, plain, reassuring words. No technical jargon.
    """

    private static func context(sys: SystemSnapshot, findings: [Finding], freed: Int64) -> String {
        var lines = [
            "Memory used: \(Int(sys.memFraction * 100))% of \(Fmt.mem(sys.memTotal)). Memory pressure: \(sys.pressure >= 4 ? "critical" : sys.pressure >= 2 ? "high" : "normal"). Moved to disk: \(Fmt.mem(sys.swapUsed)).",
            "Processor load: \(Int(sys.cpuLoad * 100))%. Free storage: \(Fmt.bytes(sys.diskFree)) of \(Fmt.bytes(sys.diskTotal)). Time since restart: \(Fmt.uptime(sys.uptime)).",
            "Already cleared just now: \(Fmt.bytes(freed)).",
            "Findings:",
        ]
        if findings.isEmpty { lines.append("(none)") }
        for f in findings.prefix(10) {
            lines.append("- id \(f.id) | severity \(f.severity) of 3 | \(f.title). \(f.detail)" + (f.actionLabel.map { " Possible fix: \($0)." } ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    static func plan(sys: SystemSnapshot, findings: [Finding], freed: Int64) async -> Advice {
        let fallback = rules(sys: sys, findings: findings)
        guard isReady, !findings.isEmpty else { return fallback }
        let prompt = context(sys: sys, findings: findings, freed: freed)
        let generated: ModelPlan? = await Timeout.run(seconds: 20) {
            try? await LanguageModelSession(instructions: instructions).respond(to: prompt, generating: ModelPlan.self).content
        }
        guard let generated else { return fallback }

        // Keep only ids that exist, once each, then append anything the model left out.
        let known = Set(findings.map(\.id))
        var seen = Set<String>()
        var steps = generated.steps.compactMap { step -> Advice.Step? in
            let id = step.id.trimmingCharacters(in: .whitespaces)
            guard known.contains(id), seen.insert(id).inserted else { return nil }
            return Advice.Step(id: id, reason: step.reason)
        }
        steps += fallback.steps.filter { !seen.contains($0.id) }
        let headline = generated.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        return Advice(headline: headline.isEmpty ? fallback.headline : headline, steps: steps, source: .onDevice)
    }

    /// The same advice without a language model: findings by severity, with their own explanation.
    static func rules(sys: SystemSnapshot, findings: [Finding]) -> Advice {
        let urgent = findings.filter { $0.severity >= 2 }.count
        let headline: String
        if findings.isEmpty { headline = "Everything is running smoothly." }
        else if urgent == 0 { headline = "Your Mac is fine. A few small things could be tidier." }
        else if urgent == 1 { headline = "One thing is slowing your Mac down." }
        else { headline = "\(urgent) things are slowing your Mac down." }
        return Advice(headline: headline, steps: findings.map { Advice.Step(id: $0.id, reason: $0.detail) }, source: .rules)
    }

    /// One or two sentences on where an app's memory is and what to do about it. The model sees
    /// category names and sizes only.
    static func explain(_ insight: AppInsight) async -> String? {
        guard isReady, insight.total > 0 else { return nil }
        var lines = ["\(insight.app) uses \(Fmt.mem(insight.total)) in total, split like this:"]
        for section in insight.sections {
            let top = section.parts.first.map { " The largest single one holds \(Fmt.mem($0.footprint))." } ?? ""
            lines.append("- \(section.kind.rawValue): \(section.parts.count) processes, \(Fmt.mem(section.footprint)).\(top)")
        }
        let facts = lines.joined(separator: "\n")
        let rules = "You are Aerilo, a calm assistant for one Mac. Given how an app's memory is split, say in at most two short plain sentences where most of it is and the gentlest thing the person could do. Use only the numbers given. No jargon."
        let text: String? = await Timeout.run(seconds: 12) {
            try? await LanguageModelSession(instructions: rules).respond(to: facts).content
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Free-form question about this Mac, answered on device from the current measurements.
    static func answer(_ question: String, sys: SystemSnapshot, findings: [Finding], freed: Int64) async -> String? {
        guard isReady else { return nil }
        let grounding = instructions + "\nAnswer the question in at most four sentences, using only these facts:\n" + context(sys: sys, findings: findings, freed: freed)
        return await Timeout.run(seconds: 30) {
            try? await LanguageModelSession(instructions: grounding).respond(to: question).content
        }
    }
}

// MARK: - Siri, Spotlight and Shortcuts

struct BreatheIntent: AppIntent {
    static let title: LocalizedStringResource = "Let My Mac Breathe"
    static let description = IntentDescription("Clears safe caches and checks what is slowing this Mac down.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        await model.breathe(source: "Siri or Shortcuts")
        let cleared = model.lastFreed > 0 ? "Cleared \(Fmt.bytes(model.lastFreed)). " : ""
        return .result(dialog: "\(cleared)\(model.advice?.headline ?? "Done.")")
    }
}

struct HealthIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Mac Health"
    static let description = IntentDescription("Reports memory, storage and processor load for this Mac.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        await model.refresh()
        let s = model.sys
        return .result(dialog: "\(s.healthWord), \(s.health) out of 100. Memory is \(Int(s.memFraction * 100))% used and \(Fmt.bytes(s.diskFree)) of storage is free.")
    }
}

struct AeriloShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BreatheIntent(), phrases: ["Let my Mac breathe with \(.applicationName)", "Breathe with \(.applicationName)"],
                    shortTitle: "Breathe", systemImageName: "wind")
        AppShortcut(intent: HealthIntent(), phrases: ["Check my Mac with \(.applicationName)", "How is my Mac in \(.applicationName)"],
                    shortTitle: "Check Health", systemImageName: "heart")
    }
}
