import BubblePhysicsReference
import SwiftUI

struct ReferenceVisualPrototypeView: View {
    @Binding var selectedMode: PrototypeMode
    @State private var runner: ReferenceVisualRunner
    @State private var snapshot: ReferenceVisualSnapshot
    @State private var isPaused = false
    @State private var showsPoints = false

    init(selectedMode: Binding<PrototypeMode>) {
        _selectedMode = selectedMode
        var runner = try! ReferenceVisualRunner()
        let snapshot = runner.advance(to: 0)
        _runner = State(initialValue: runner)
        _snapshot = State(initialValue: snapshot)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { timeline in
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    Canvas { context, size in render(snapshot, in: &context, size: size) }
                        .background(Color(red: 0.025, green: 0.04, blue: 0.07))
                    controls
                }
                .onChange(of: timeline.date) { date in
                    guard !isPaused else { return }
                    snapshot = runner.advance(to: date.timeIntervalSinceReferenceDate)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 7) {
            Picker("Scena", selection: $selectedMode) {
                Text("CPU Wiz").tag(PrototypeMode.referenceVisual)
                Text("CPU").tag(PrototypeMode.reference)
                Text("Radial").tag(PrototypeMode.radial)
                Text("40").tag(PrototypeMode.inspection)
                Text("300").tag(PrototypeMode.stress)
            }
            .pickerStyle(.segmented)
            HStack {
                Text("CPU Wiz").font(.headline)
                Spacer()
                Button(isPaused ? "Wznów" : "Pauza") { isPaused.toggle() }
                Button("Reset") {
                    runner.reset()
                    snapshot = runner.advance(to: Date.timeIntervalSinceReferenceDate)
                }
            }
            Toggle("Punkty kontaktowe", isOn: $showsPoints)
            let report = snapshot.lastReport
            Text(String(format: "%.2f ms · kontakty %d/%d · iteracje %d", report.totalMilliseconds, report.generatedContactCount, report.persistentContactCount, report.solver.iterations))
            Text(String(format: "penetracja %.4f · TOI %d · limity %d · non-finite %@", report.solver.maximumPenetration, report.toiTestCount, report.ccdBudgetExhaustionCount, report.hasNonFiniteState ? "tak" : "nie"))
        }
        .font(.caption.monospacedDigit())
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding()
    }

    private func render(_ snapshot: ReferenceVisualSnapshot, in context: inout GraphicsContext, size: CGSize) {
        let scale = min(size.width / 375, size.height / 700)
        let offset = CGPoint(x: (size.width - 375 * scale) * 0.5, y: (size.height - 700 * scale) * 0.5)
        func point(_ value: ReferenceVector2) -> CGPoint {
            CGPoint(x: offset.x + CGFloat(value.x) * scale, y: offset.y + CGFloat(value.y) * scale)
        }

        for bubble in snapshot.bubbles {
            guard let contour = snapshot.contours[bubble.id], contour.count >= 3 else { continue }
            let path = smoothClosedPath(contour.map(point))
            let hue = Double((bubble.id.rawValue * 37) % 360) / 360
            context.fill(path, with: .color(Color(hue: hue, saturation: 0.68, brightness: 0.88)))
            context.stroke(path, with: .color(.white.opacity(0.38)), lineWidth: 1.5)

            var labelContext = context
            let center = point(bubble.center)
            labelContext.translateBy(x: center.x, y: center.y)
            labelContext.rotate(by: .radians(Double(bubble.rotation)))
            labelContext.draw(
                Text(String(1 << min(20, bubble.id.rawValue % 12 + 1)))
                    .font(.system(size: max(8, CGFloat(bubble.targetRadius) * scale * 0.34), weight: .semibold)),
                at: .zero,
                anchor: .center
            )

            if showsPoints {
                for contourPoint in contour {
                    let center = point(contourPoint)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)), with: .color(.white))
                }
            }
        }

        if snapshot.triangleVertices.count == 3 {
            var triangle = Path()
            triangle.move(to: point(snapshot.triangleVertices[0]))
            triangle.addLine(to: point(snapshot.triangleVertices[1]))
            triangle.addLine(to: point(snapshot.triangleVertices[2]))
            triangle.closeSubpath()
            context.fill(triangle, with: .color(.orange.opacity(0.9)))
            context.stroke(triangle, with: .color(.white.opacity(0.8)), lineWidth: 2)
        }
    }

    private func smoothClosedPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count >= 3 else { return path }
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
        }
        path.move(to: midpoint(points[points.count - 1], points[0]))
        for index in points.indices {
            path.addQuadCurve(to: midpoint(points[index], points[(index + 1) % points.count]), control: points[index])
        }
        path.closeSubpath()
        return path
    }
}
