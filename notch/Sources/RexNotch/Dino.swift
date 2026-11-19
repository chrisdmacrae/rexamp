import SwiftUI

/// The Rex dinosaur's head, tinted by state; it hops while its agent works.
struct DinoIcon: View {
    var color: Color
    var working = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !working)) { tl in
            let hop = working ? CGFloat(Int(tl.date.timeIntervalSinceReferenceDate * 4) % 2) : 0
            Canvas { ctx, size in
                // Drawn in a unit square, facing right.
                let s = min(size.width, size.height)
                ctx.translateBy(x: (size.width - s) / 2, y: (size.height - s) / 2 - hop)
                ctx.scaleBy(x: s, y: s)
                var head = Path()
                head.move(to: CGPoint(x: 0.43, y: 0.12))
                head.addCurve(to: CGPoint(x: 0.82, y: 0.18), control1: CGPoint(x: 0.56, y: 0.02), control2: CGPoint(x: 0.72, y: 0.08)) // dome
                head.addCurve(to: CGPoint(x: 0.9, y: 0.62), control1: CGPoint(x: 0.94, y: 0.24), control2: CGPoint(x: 1.06, y: 0.56)) // nose
                head.addQuadCurve(to: CGPoint(x: 0.66, y: 0.7), control: CGPoint(x: 0.78, y: 0.66))
                head.addCurve(to: CGPoint(x: 0.41, y: 0.86), control1: CGPoint(x: 0.7, y: 0.9), control2: CGPoint(x: 0.52, y: 0.96)) // chin
                // The back of the head, scalloped by the crest.
                let center = CGPoint(x: 0.52, y: 0.5)
                func back(_ deg: Double) -> CGPoint {
                    let a = Angle.degrees(deg).radians
                    return CGPoint(x: center.x + 0.27 * cos(a), y: center.y + 0.38 * sin(a))
                }
                let n = 6
                for i in 0..<n {
                    let from = 115 + Double(i) * 135 / Double(n), to = from + 135 / Double(n)
                    let mid = back((from + to) / 2)
                    let out = CGPoint(x: center.x + (mid.x - center.x) * 1.32, y: center.y + (mid.y - center.y) * 1.2)
                    head.addQuadCurve(to: back(to), control: out)
                }
                head.closeSubpath()
                ctx.fill(head, with: .color(color))
                ctx.blendMode = .destinationOut
                ctx.fill(Path(ellipseIn: CGRect(x: 0.47, y: 0.3, width: 0.09, height: 0.17)), with: .color(.black))
                var mouth = Path()
                mouth.move(to: CGPoint(x: 0.5, y: 0.72))
                mouth.addQuadCurve(to: CGPoint(x: 0.86, y: 0.66), control: CGPoint(x: 0.68, y: 0.72))
                ctx.stroke(mouth, with: .color(.black), style: StrokeStyle(lineWidth: 0.06, lineCap: .round))
            }
        }
        .frame(width: 22, height: 18)
    }
}
