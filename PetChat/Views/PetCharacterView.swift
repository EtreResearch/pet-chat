import SwiftUI

struct PetCharacterView: View {
    var isThinking = false
    var completionID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var celebrating = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let blink = !reduceMotion && !isThinking && time.truncatingRemainder(dividingBy: 5.3) < 0.14
            let breath = reduceMotion ? 1 : 1 + sin(time * 2) * 0.012
            Canvas { context, _ in
                let blue = Color(red: 0.38, green: 0.46, blue: 0.61)
                let dark = Color(red: 0.19, green: 0.24, blue: 0.34)
                func ellipse(_ rect: CGRect, _ color: Color) { context.fill(Path(ellipseIn: rect), with: .color(color)) }
                var tail = Path()
                tail.move(to: CGPoint(x: 43, y: 57))
                tail.addCurve(to: CGPoint(x: 57, y: 38), control1: CGPoint(x: 65, y: 64), control2: CGPoint(x: 61, y: 45))
                context.stroke(tail, with: .color(blue), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                ellipse(CGRect(x: 16, y: 29, width: 34, height: 34), blue)
                var ears = Path()
                ears.move(to: CGPoint(x: 13, y: 23)); ears.addLine(to: CGPoint(x: 13, y: 2))
                ears.addLine(to: CGPoint(x: 27, y: 14)); ears.addLine(to: CGPoint(x: 39, y: 14))
                ears.addLine(to: CGPoint(x: 51, y: 2)); ears.addLine(to: CGPoint(x: 51, y: 24)); ears.closeSubpath()
                context.fill(ears, with: .color(blue))
                ellipse(CGRect(x: 11, y: 11, width: 42, height: 31), blue)
                ellipse(CGRect(x: 24, y: 39, width: 18, height: 21), Color.white.opacity(0.13))
                ellipse(CGRect(x: 16, y: 57, width: 17, height: 7), blue)
                ellipse(CGRect(x: 34, y: 57, width: 17, height: 7), blue)
                let eyesClosed = blink || celebrating
                for x in [23.0, 41.0] {
                    if eyesClosed {
                        var eye = Path(); eye.move(to: CGPoint(x: x - 3, y: 25))
                        eye.addQuadCurve(to: CGPoint(x: x + 3, y: 25), control: CGPoint(x: x, y: celebrating ? 21 : 27))
                        context.stroke(eye, with: .color(dark), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    } else {
                        ellipse(CGRect(x: x - 2, y: isThinking ? 20 : 22, width: 4, height: 6), dark)
                        ellipse(CGRect(x: x - 1, y: isThinking ? 21 : 23, width: 1.2, height: 1.5), .white)
                    }
                }
                ellipse(CGRect(x: 30, y: 29, width: 4, height: 3), dark)
                if isThinking {
                    for index in 0..<3 {
                        let opacity = reduceMotion ? 0.8 : 0.35 + (sin(time * 3 - Double(index)) + 1) * 0.3
                        ellipse(CGRect(x: 25 + Double(index) * 6, y: 45, width: 3, height: 3), .white.opacity(opacity))
                    }
                }
            }
            .scaleEffect(x: 1, y: breath, anchor: .bottom)
            .offset(y: celebrating && !reduceMotion ? -2 : 0)
        }
        .frame(width: 64, height: 64)
        .accessibilityLabel(isThinking ? "Pet, thinking" : "Pet")
        .task(id: completionID) {
            guard completionID != nil else { return }
            celebrating = true
            try? await Task.sleep(for: .milliseconds(800))
            celebrating = false
        }
    }
}
