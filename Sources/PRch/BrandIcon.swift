import AppKit
import SwiftUI

/// The PRch P monogram, drawn as a template so macOS handles menu bar contrast.
struct BrandMark: View {
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: BrandIcon.template)
            .renderingMode(.template)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum BrandIcon {
    @MainActor static let template: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(path(in: rect))
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "PRch"
        return image
    }()

    /// Matches Resources/Brand/Mark.svg on its 24 × 24 design grid.
    static func path(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5, y: 21))
        path.addLine(to: CGPoint(x: 5, y: 9))
        path.addCurve(to: CGPoint(x: 11, y: 3),
                      control1: CGPoint(x: 5, y: 5.6862915),
                      control2: CGPoint(x: 7.6862915, y: 3))
        path.addLine(to: CGPoint(x: 13, y: 3))
        path.addCurve(to: CGPoint(x: 20, y: 10),
                      control1: CGPoint(x: 16.8659932, y: 3),
                      control2: CGPoint(x: 20, y: 6.1340068))
        path.addCurve(to: CGPoint(x: 13, y: 17),
                      control1: CGPoint(x: 20, y: 13.8659932),
                      control2: CGPoint(x: 16.8659932, y: 17))
        path.addLine(to: CGPoint(x: 11, y: 17))
        path.addLine(to: CGPoint(x: 11, y: 13))
        path.addLine(to: CGPoint(x: 13, y: 13))
        path.addCurve(to: CGPoint(x: 16, y: 10),
                      control1: CGPoint(x: 14.6568542, y: 13),
                      control2: CGPoint(x: 16, y: 11.6568542))
        path.addCurve(to: CGPoint(x: 13, y: 7),
                      control1: CGPoint(x: 16, y: 8.3431458),
                      control2: CGPoint(x: 14.6568542, y: 7))
        path.addLine(to: CGPoint(x: 11, y: 7))
        path.addCurve(to: CGPoint(x: 9, y: 9),
                      control1: CGPoint(x: 9.8954305, y: 7),
                      control2: CGPoint(x: 9, y: 7.8954305))
        path.addLine(to: CGPoint(x: 9, y: 21))
        path.closeSubpath()
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / 24, y: rect.height / 24)
        return path.copy(using: &transform)!
    }
}
