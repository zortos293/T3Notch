import AppKit
import SwiftUI

/// Generates AppIcon.icns from code so the icon stays in sync with the app's own
/// notch silhouette instead of being a hand-drawn asset nobody can regenerate.
///
/// Everything is laid out in a 1024-unit design space and scaled per output size,
/// with small sizes dropping detail that would turn to mush below 64px.
struct AppIconArt: View {
    let pixelSize: CGFloat

    /// Design-space unit -> points for this output size.
    private func u(_ value: CGFloat) -> CGFloat { value * pixelSize / 1024 }

    /// Below this, interior detail stops being legible and only the silhouette reads.
    private var showsDetail: Bool { pixelSize >= 64 }

    /// At 16px even a single dot fills the notch, so the silhouette goes it alone.
    private var showsAccentDot: Bool { pixelSize >= 32 }

    // macOS icon grid: 824x824 body centered in a 1024 canvas.
    private let bodyInset: CGFloat = 100
    private var bodyRect: CGRect {
        CGRect(
            x: u(bodyInset),
            y: u(bodyInset),
            width: u(1024 - bodyInset * 2),
            height: u(1024 - bodyInset * 2)
        )
    }

    /// Kept narrower than the squircle's flat top edge — a continuous corner of
    /// radius 185 eats roughly 220 units per side, so anything wider than ~380
    /// spills into the corner curve and stops reading as a notch.
    private var notchRect: CGRect {
        let width: CGFloat = 404
        return CGRect(
            x: u((1024 - width) / 2),
            y: bodyRect.minY,
            width: u(width),
            height: u(showsDetail ? 224 : 226)
        )
    }

    var body: some View {
        ZStack {
            body_
        }
        .frame(width: pixelSize, height: pixelSize)
    }

    // T3 Code's brand primary, oklch(0.588 0.217 264), with a lighter top and a
    // deeper base for depth. A vivid body is what makes the black notch legible
    // down at 16px, where a dark-on-dark treatment turns into a smudge.
    private static let brandTop = Color(red: 0.36, green: 0.58, blue: 1.00)
    private static let brandMid = Color(red: 0.21, green: 0.44, blue: 0.98)
    private static let brandDeep = Color(red: 0.10, green: 0.21, blue: 0.64)
    private static let accent = Color(red: 0.35, green: 0.90, blue: 1.00)

    private var body_: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            // Squircle body, lit from the top like a screen bezel.
            RoundedRectangle(cornerRadius: u(185), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Self.brandTop, Self.brandMid, Self.brandDeep],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: u(185), style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.45), .white.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: max(1, u(4))
                        )
                )
                .frame(width: bodyRect.width, height: bodyRect.height)
                .offset(x: bodyRect.minX, y: bodyRect.minY)
                .shadow(color: .black.opacity(0.35), radius: u(26), y: u(18))

            notch

            if showsDetail {
                taskLines
            }
        }
    }

    /// The app's actual panel shape, hanging from the top edge of the body.
    private var notch: some View {
        let shape = NotchShape(
            topRadius: u(46),
            bottomRadius: u(showsDetail ? 84 : 100)
        )
        return shape
            .fill(Color(red: 0.02, green: 0.02, blue: 0.04))
            .overlay {
                if showsDetail {
                    notchContents
                } else if showsAccentDot {
                    // One accent dot survives at 32px, where bars turn to mush.
                    Circle()
                        .fill(Self.accent)
                        .frame(width: u(86), height: u(86))
                        .offset(y: u(30))
                }
            }
            .frame(width: notchRect.width, height: notchRect.height)
            // Darkens the blue around the edge so it reads as a cutout, not a
            // sticker. Kept off at small sizes, where the blur only adds mud.
            .shadow(
                color: .black.opacity(showsDetail ? 0.4 : 0),
                radius: u(20),
                y: u(6)
            )
            .offset(x: notchRect.minX, y: notchRect.minY)
    }

    /// Progress ring plus a status label, mirroring the collapsed pill.
    private var notchContents: some View {
        HStack(spacing: u(26)) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.24), lineWidth: u(17))
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(
                        Self.accent,
                        style: StrokeStyle(lineWidth: u(17), lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: u(80), height: u(80))

            Capsule()
                .fill(Color.white.opacity(0.92))
                .frame(width: u(146), height: u(30))
        }
        .offset(y: u(26))
    }

    /// Task list peeking out below the notch: what the app is actually for.
    /// The widest row matches the notch width so the two elements line up, and
    /// the block is centred in the space left under the notch.
    private var taskLines: some View {
        VStack(alignment: .leading, spacing: u(62)) {
            line(width: 328, dot: Color(red: 0.42, green: 0.95, blue: 0.55), text: 0.95)
            line(width: 262, dot: Self.accent, text: 0.72)
            line(width: 192, dot: Color.white.opacity(0.5), text: 0.48)
        }
        .offset(x: u(310), y: u(502))
    }

    private func line(width: CGFloat, dot: Color, text: Double) -> some View {
        HStack(spacing: u(30)) {
            Circle()
                .fill(dot)
                .frame(width: u(46), height: u(46))
            Capsule()
                .fill(Color.white.opacity(text))
                .frame(width: u(width), height: u(40))
        }
    }
}

@MainActor
func writePNG(size: CGFloat, to url: URL) throws {
    let renderer = ImageRenderer(content: AppIconArt(pixelSize: size))
    renderer.scale = 1
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
}

@main
struct MakeAppIcon {
    /// (pixel size, iconset file names) — iconutil needs both @1x and @2x entries.
    static let variants: [(CGFloat, [String])] = [
        (16, ["icon_16x16.png"]),
        (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
        (64, ["icon_32x32@2x.png"]),
        (128, ["icon_128x128.png"]),
        (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
        (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
        (1024, ["icon_512x512@2x.png"]),
    ]

    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            print("usage: MakeAppIcon <output.iconset directory>")
            exit(2)
        }
        let iconset = URL(fileURLWithPath: arguments[1])

        MainActor.assumeIsolated {
            do {
                try FileManager.default.createDirectory(
                    at: iconset,
                    withIntermediateDirectories: true
                )
                for (size, names) in variants {
                    for name in names {
                        try writePNG(size: size, to: iconset.appendingPathComponent(name))
                    }
                }
                print("==> Rendered \(variants.count) icon sizes into \(iconset.path)")
            } catch {
                print("error: \(error)")
                exit(1)
            }
        }
    }
}
