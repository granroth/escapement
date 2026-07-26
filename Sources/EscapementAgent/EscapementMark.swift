import AppKit

/// Escapement's escape wheel, drawn as a menu bar **template** image.
///
/// Menu bar icons are template images by long-standing macOS convention: only
/// the alpha channel matters, and the system renders it black, white, or dimmed
/// to match the menu bar's appearance, the inactive state, and the highlight
/// when the menu is open. A full-colour icon can do none of that and reads as
/// foreign next to every other extra in the bar.
///
/// The shape cannot be lifted from the app icon's alpha, which is a solid
/// toothed disc — the spokes and hub are interior detail, so a silhouette of it
/// would be a featureless blob. So the wheel is redrawn here from the same
/// geometry the icon art uses: twelve teeth on a 30° pitch, each an arc along
/// the wheel body, a curve out to a sharp tip, and a straight flank back down.
///
/// Drawn rather than shipped as a bitmap so it stays crisp at any scale factor
/// and can be re-rendered when the system asks.
enum EscapementMark {

    // Proportions of the tip radius, measured from the icon art. The teeth are
    // reproduced faithfully — they are what makes the mark recognisable.
    private static let bodyRadius: CGFloat = 0.702
    private static let controlRadius: CGFloat = 0.828
    private static let shoulderRadius: CGFloat = 0.940

    // The interior carries far less than the art does, and deliberately so. On
    // a display at a backing scale of 1 this icon is 18 *pixels*, and at that
    // size the art's true rim, spokes and jewel all land near a single pixel
    // and smear into a grey disc.
    //
    // Spokes were tried and dropped. Even four heavy ones read as a bold "+"
    // laid over a rim too thin to survive, which in the real menu bar looked
    // like an asterisk rather than a wheel. A thick toothed rim around an open
    // bore, with the arbor as a solid centre, reads correctly at a glance; the
    // twelve asymmetric escapement teeth are what keep it from being a cog.
    private static let holeRadius: CGFloat = 0.480
    private static let hubRadius: CGFloat = 0.180

    private static let teeth = 12
    /// The art sits slightly rotated; keeping it stops the wheel looking like a
    /// gear decal and matches the app icon.
    private static let rotation: CGFloat = -11

    /// The status item image. 18pt is the conventional icon size inside the
    /// 22pt menu bar.
    static func statusItemImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(
            size: NSSize(width: size, height: size), flipped: false
        ) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(path(in: rect))
            context.setFillColor(NSColor.black.cgColor)
            // Even-odd so the bore and the jewel read as holes. Every shape is
            // built to abut rather than overlap, so nothing else cancels out.
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func path(in rect: CGRect) -> CGPath {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        // Leave a hair of padding so the teeth are not clipped by the button.
        let scale = min(rect.width, rect.height) / 2 * 0.97

        let path = CGMutablePath()
        var transform = CGAffineTransform(translationX: centre.x, y: centre.y)
            .rotated(by: rotation * .pi / 180)
            .scaledBy(x: scale, y: scale)

        addWheel(to: path, transform: &transform)
        path.addEllipse(
            in: CGRect(x: -hubRadius, y: -hubRadius, width: hubRadius * 2, height: hubRadius * 2),
            transform: transform)
        return path
    }

    /// The toothed rim: the outer outline followed by the bore, so even-odd
    /// filling leaves an annulus.
    private static func addWheel(to path: CGMutablePath, transform: inout CGAffineTransform) {
        let pitch = 360.0 / CGFloat(teeth)

        for tooth in 0..<teeth {
            let base = CGFloat(tooth) * pitch - 90
            if tooth == 0 {
                path.move(to: point(bodyRadius, base), transform: transform)
            }
            // Along the wheel body, then out to the tip and back down the flank.
            path.addArc(
                center: .zero, radius: bodyRadius,
                startAngle: radians(base), endAngle: radians(base + 12.6),
                clockwise: false, transform: transform)
            path.addQuadCurve(
                to: point(1.0, base + 21.6),
                control: point(controlRadius, base + 18),
                transform: transform)
            path.addLine(to: point(shoulderRadius, base + 26.4), transform: transform)
            path.addLine(to: point(bodyRadius, base + pitch), transform: transform)
        }
        path.closeSubpath()

        path.addEllipse(
            in: CGRect(
                x: -holeRadius, y: -holeRadius, width: holeRadius * 2, height: holeRadius * 2),
            transform: transform)
    }

    private static func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }

    private static func point(_ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
        CGPoint(x: radius * cos(radians(degrees)), y: radius * sin(radians(degrees)))
    }
}
