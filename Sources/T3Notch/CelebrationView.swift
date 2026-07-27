import SwiftUI

/// Milestone banner: a tinted card that springs in, breathes once, and leaves.
/// Merges also get a short confetti burst, which is the whole point of noticing
/// them from across the room.
struct CelebrationBanner: View {
    let celebration: Celebration

    @State private var entered = false
    @State private var sheen = false

    private var milestone: Milestone { celebration.milestone }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: milestone.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(milestone.tint)
                .scaleEffect(entered ? 1 : 0.4)
                .rotationEffect(.degrees(entered ? 0 : -25))

            VStack(alignment: .leading, spacing: 1) {
                Text(milestone.headline)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                if let detail = milestone.detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(milestone.tint.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(milestone.tint.opacity(0.4), lineWidth: 1)
                )
                // A single highlight sweeps across on arrival.
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.16), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .scaleEffect(x: 0.4, y: 1, anchor: .center)
                        .offset(x: sheen ? 220 : -220)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                )
        )
        .shadow(color: milestone.tint.opacity(entered ? 0.28 : 0), radius: 12)
        .scaleEffect(entered ? 1 : 0.94)
        .opacity(entered ? 1 : 0)
        .task(id: celebration.id) {
            entered = false
            sheen = false
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { entered = true }
            withAnimation(.easeInOut(duration: 0.9).delay(0.1)) { sheen = true }
        }
    }
}

/// Cheap confetti: a fixed set of chips given randomised targets, animated once.
/// No physics and no timer — the whole burst is one implicit animation. Meant to
/// cover the whole panel, so chips fall past the content rather than piling up
/// inside a banner.
struct ConfettiOverlay: View {
    let tint: Color

    private struct Chip: Identifiable {
        let id: Int
        let x: CGFloat
        let angle: Double
        let delay: Double
        let drift: CGFloat
        let spin: Double
        let color: Color
        let size: CGSize
    }

    @State private var chips: [Chip] = []
    @State private var launched = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(chips) { chip in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(chip.color)
                        .frame(width: chip.size.width, height: chip.size.height)
                        .rotationEffect(.degrees(launched ? chip.spin : chip.angle))
                        .offset(
                            x: chip.x * proxy.size.width + (launched ? chip.drift : 0),
                            y: launched ? proxy.size.height * 0.95 : -6
                        )
                        .opacity(launched ? 0 : 1)
                        .animation(
                            .easeIn(duration: 1.5).delay(chip.delay),
                            value: launched
                        )
                }
            }
            .task {
                chips = Self.makeChips(tint: tint)
                launched = false
                // One frame at the start position, then let them fall.
                try? await Task.sleep(for: .milliseconds(16))
                launched = true
            }
        }
    }

    private static func makeChips(tint: Color) -> [Chip] {
        let palette: [Color] = [tint, .white.opacity(0.85), tint.opacity(0.6), .cyan]
        return (0..<18).map { index in
            Chip(
                id: index,
                x: CGFloat.random(in: 0.04...0.96),
                angle: .random(in: -40...40),
                delay: .random(in: 0...0.35),
                drift: .random(in: -26...26),
                spin: .random(in: 180...520),
                color: palette[index % palette.count],
                size: CGSize(
                    width: .random(in: 2.5...4.5),
                    height: .random(in: 4...8)
                )
            )
        }
    }
}
