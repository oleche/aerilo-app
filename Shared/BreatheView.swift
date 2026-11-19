import SwiftUI

/// The one button, and the breath around it.
///
/// At rest: the orb is still, and breathes a little when the pointer arrives. Inhale (while Aerilo works): it draws in and
/// motes gather toward it. Exhale (work done): it opens, rings spread out and the motes drift up and
/// away like a breeze. With Reduce Motion on, only the orb's size changes, once per phase.
struct BreatheOrb: View {
    let phase: BreathPhase
    let phaseStart: Date
    var diameter: CGFloat = 230
    let label: String
    let sublabel: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    @State private var pulse = false

    var body: some View {
        if (phase == .inhale || phase == .exhale) && !reduceMotion {
            // Per-frame drawing only while the Mac is breathing in or out.
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                let now = timeline.date
                orb(scale: breathScale(now.timeIntervalSince(phaseStart), clock: now.timeIntervalSinceReferenceDate),
                    air: (now.timeIntervalSince(phaseStart), now.timeIntervalSinceReferenceDate))
            }
        } else {
            // At rest the orb is still, and Aerilo uses almost no processor (a constantly moving
            // glass surface measured about 18% of a core). It breathes a little when the pointer arrives.
            orb(scale: reduceMotion ? staticScale : (pulse ? 1.035 : 1), air: nil)
                #if !os(tvOS)
                .onHover { inside in
                    guard !reduceMotion, !CommandLine.arguments.contains("--no-hover") else { return }
                    if inside {
                        // Three slow movements, then it rests slightly open: a pointer left on the orb costs nothing.
                        withAnimation(.easeInOut(duration: 2.6).repeatCount(3, autoreverses: true)) { pulse = true }
                    } else {
                        withAnimation(.easeOut(duration: 0.8)) { pulse = false }
                    }
                }
                #endif
                .onAppear { pulse = false }
        }
    }

    private func orb(scale: CGFloat, air: (elapsed: Double, clock: Double)?) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(label)
                    .font(.system(size: diameter * 0.16, weight: .light, design: .rounded))
                Text(sublabel)
                    .font(.system(size: max(11, diameter * 0.058), weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(diameter * 0.12)
            .frame(width: diameter, height: diameter)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .aeriloGlass(in: .circle, interactive: true)
        .scaleEffect(scale)
        // Not `.disabled`, which would grey the label while the Mac is breathing.
        .allowsHitTesting(phase == .idle || phase == .done)
        // No keyboard shortcut on purpose: a stray Return while the window has focus must never start a clean-up.
        .accessibilityLabel("\(label). \(sublabel)")
        // Glow and air sit behind the orb and may spill past its frame without moving the layout.
        .background {
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(scheme == .dark ? 0.35 : 0.9), .white.opacity(0)],
                                     center: .center, startRadius: diameter * 0.2, endRadius: diameter * 0.75))
                .frame(width: diameter * 1.5, height: diameter * 1.5)
                .scaleEffect(scale * 1.04)
                .blur(radius: 18)
                .allowsHitTesting(false)
        }
        .background {
            if let air {
                Canvas { context, size in
                    drawAir(&context, size: size, elapsed: air.elapsed, clock: air.clock)
                }
                .frame(width: diameter * 6, height: diameter * 4.6)
                .allowsHitTesting(false)
            }
        }
    }

    private var staticScale: CGFloat {
        switch phase {
        case .inhale: return 0.9
        case .exhale: return 1.06
        default: return 1
        }
    }

    private func ease(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }

    private func breathScale(_ e: Double, clock: Double) -> CGFloat {
        switch phase {
        case .idle, .done:
            return 1
        case .inhale:
            // Draw in over three seconds, then hold with a faint tremor while the work finishes.
            return 1 - 0.16 * ease(e / 3.0) + 0.006 * sin(clock * 3)
        case .exhale:
            // Open past rest, then settle.
            let open = ease(e / 1.6)
            let settle = ease((e - 1.6) / 2.0)
            return 0.84 + 0.30 * open - 0.14 * settle
        }
    }

    /// Deterministic per-particle random numbers, so motes keep their path between frames.
    private func rand(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: i &* 73_856_093 ^ salt &* 19_349_663) &+ 0x9E37_79B9_7F4A_7C15
        x ^= x >> 30; x &*= 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27; x &*= 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x % 10_000) / 10_000
    }

    private func drawAir(_ context: inout GraphicsContext, size: CGSize, elapsed e: Double, clock: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = diameter / 2
        let tone: Color = .white
        context.addFilter(.blur(radius: 1.2))

        func dot(_ p: CGPoint, _ radius: Double, _ alpha: Double) {
            guard alpha > 0.01 else { return }
            let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(tone.opacity(alpha)))
        }

        switch phase {
        case .idle, .done:
            break

        case .inhale:
            // Ripples drawing in toward the orb for as long as the work takes.
            for k in 0..<3 {
                let t = ((e + Double(k) * 0.8).truncatingRemainder(dividingBy: 2.4)) / 2.4
                let radius = r * (2.7 - 1.65 * ease(t))
                let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.stroke(ring, with: .color(tone.opacity(sin(t * .pi) * 0.5 * ease(e / 0.8))), lineWidth: 1.5 + t * 2)
            }
            // Motes spiral in from all around and vanish into the orb.
            for i in 0..<50 {
                let period = 1.6 + rand(i, 1) * 1.4
                let t = ((e + rand(i, 2) * period).truncatingRemainder(dividingBy: period)) / period
                let angle = rand(i, 3) * 2 * .pi + t * 0.9
                let dist = r * (2.9 - 2.0 * ease(t))
                let p = CGPoint(x: center.x + cos(angle) * dist, y: center.y + sin(angle) * dist)
                dot(p, 1.2 + rand(i, 4) * 2.2, sin(t * .pi) * 0.75 * ease(e / 0.8))
            }

        case .exhale:
            // Rings spreading out.
            for k in 0..<3 {
                let t = (e - Double(k) * 0.45) / 2.4
                guard t > 0, t < 1 else { continue }
                let radius = r * (1.0 + 1.9 * ease(t))
                let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.stroke(ring, with: .color(tone.opacity((1 - t) * 0.55)), lineWidth: 1.5 + (1 - t) * 3)
            }
            // The release: motes leave the orb, slow down, and float up and sideways like a breeze.
            for i in 0..<130 {
                let delay = rand(i, 1) * 0.9
                let life = 2.2 + rand(i, 2) * 1.2
                let t = (e - delay) / life
                guard t > 0, t < 1 else { continue }
                let angle = rand(i, 3) * 2 * .pi
                let out = r * (1.0 + (0.5 + rand(i, 4) * 1.9) * (1 - pow(1 - t, 3)))
                let lift = t * t * r * (0.9 + rand(i, 5))
                let sway = sin(t * 5 + rand(i, 6) * 6) * 14 * t
                let p = CGPoint(x: center.x + cos(angle) * out + sway + t * 40, y: center.y + sin(angle) * out - lift)
                dot(p, 1.4 + rand(i, 7) * 3.2, sin(t * .pi) * 0.9)
            }
        }
    }
}
