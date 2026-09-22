import SwiftUI

/// The voice agent's face: a glowing sphere that drifts at rest, swells with live audio,
/// and changes color with the conversation state.
struct VoiceOrb: View {
    let phase: VoiceAgent.Phase
    /// Read every frame; not observed, so it never triggers view updates on its own.
    let level: () -> Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var smoother = LevelSmoother()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: phase == .ended)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let energy = smoother.next(Double(level()))
            let palette = Palette(phase)
            // Thinking swirls faster; everything else drifts slowly.
            let speed = phase == .thinking ? 1.6 : 0.45
            let motion = reduceMotion ? 0 : t * speed

            ZStack {
                // Soft halo that breathes with the audio.
                Circle()
                    .fill(RadialGradient(colors: [palette.glow.opacity(0.55), .clear],
                                         center: .center, startRadius: 40, endRadius: 190))
                    .scaleEffect(1 + energy * (reduceMotion ? 0.1 : 0.35))
                    .blur(radius: 24)

                // The sphere: a mesh gradient whose inner points wander, clipped to a circle.
                MeshGradient(
                    width: 3, height: 3,
                    points: meshPoints(motion),
                    colors: palette.mesh
                )
                .clipShape(Circle())
                .overlay {
                    // Glassy highlight so it reads as a sphere, not a disc.
                    Circle()
                        .fill(RadialGradient(colors: [.white.opacity(0.45), .clear],
                                             center: UnitPoint(x: 0.32, y: 0.26), startRadius: 0, endRadius: 110))
                        .blendMode(.plusLighter)
                }
                .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
                .rotationEffect(.radians(reduceMotion ? 0 : motion * 0.35))
                .scaleEffect(1 + energy * (reduceMotion ? 0.04 : 0.16))
                .shadow(color: palette.glow.opacity(0.6), radius: 30 + energy * 30)
            }
            .animation(.easeInOut(duration: 0.45), value: phase)
        }
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityText))
    }

    /// Corner and edge points stay put; the inner ones drift on slow, out-of-phase orbits.
    private func meshPoints(_ t: Double) -> [SIMD2<Float>] {
        func wobble(_ base: Float, _ amount: Double, _ rate: Double, _ offset: Double) -> Float {
            base + Float(sin(t * rate + offset) * amount)
        }
        return [
            [0, 0], [wobble(0.5, 0.12, 0.9, 0), 0], [1, 0],
            [0, wobble(0.5, 0.12, 1.1, 1)],
            [wobble(0.5, 0.18, 1.3, 2), wobble(0.5, 0.18, 0.7, 3)],
            [1, wobble(0.5, 0.12, 0.8, 4)],
            [0, 1], [wobble(0.5, 0.12, 1.2, 5), 1], [1, 1],
        ]
    }

    private var accessibilityText: String {
        switch phase {
        case .starting: "Getting ready"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .ended: "Call ended"
        }
    }

    private struct Palette {
        let mesh: [Color]
        let glow: Color

        init(_ phase: VoiceAgent.Phase) {
            switch phase {
            case .listening:
                mesh = [.init(hex: 0x0B1B4D), .init(hex: 0x1E4FD8), .init(hex: 0x0B1B4D),
                        .init(hex: 0x2A7BFF), .init(hex: 0x7FD4FF), .init(hex: 0x3B5BFF),
                        .init(hex: 0x14225E), .init(hex: 0x3A8CFF), .init(hex: 0x101A45)]
                glow = .init(hex: 0x3A8CFF)
            case .thinking:
                mesh = [.init(hex: 0x1A0B3D), .init(hex: 0x6B2BD9), .init(hex: 0x1A0B3D),
                        .init(hex: 0xA03BFF), .init(hex: 0xF0A8FF), .init(hex: 0x5A3BFF),
                        .init(hex: 0x24104F), .init(hex: 0xC54BFF), .init(hex: 0x160A36)]
                glow = .init(hex: 0xA03BFF)
            case .speaking:
                mesh = [.init(hex: 0x05303F), .init(hex: 0x12A4C8), .init(hex: 0x05303F),
                        .init(hex: 0x1FD1C8), .init(hex: 0xE6FFFB), .init(hex: 0x2A9DFF),
                        .init(hex: 0x063A4A), .init(hex: 0x28C2E8), .init(hex: 0x042A38)]
                glow = .init(hex: 0x28D8E8)
            case .starting, .ended:
                mesh = [.init(hex: 0x1C1F26), .init(hex: 0x3A3F4B), .init(hex: 0x1C1F26),
                        .init(hex: 0x454B59), .init(hex: 0x8A91A3), .init(hex: 0x3A3F4B),
                        .init(hex: 0x1C1F26), .init(hex: 0x454B59), .init(hex: 0x1A1C22)]
                glow = .init(hex: 0x6B7385)
            }
        }
    }
}

/// Eases raw loudness so the orb swells smoothly instead of jittering with every buffer.
final class LevelSmoother {
    private var value = 0.0

    func next(_ target: Double) -> Double {
        // Rise fast (speech onsets feel immediate), fall slower (no flicker between syllables).
        let rate = target > value ? 0.35 : 0.08
        value += (target - value) * rate
        return value
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
