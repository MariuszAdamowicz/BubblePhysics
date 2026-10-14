import BubblePhysicsReference
import BubblePhysicsNativeMetal
import SwiftUI

@MainActor
struct ReferenceVisualPrototypeView: View {
    @State private var runner: VisualSimulationDriver
    @State private var frame: VisualSimulationFrame
    @State private var isPaused = false
    @State private var showsPoints = false
    @State private var showsDiagnostics = false
    @State private var showsContactForces = false
    @State private var density = ReferenceVisualDensity.twentyFour
    @State private var backend = ReferenceSimulationBackend.nativeMetal

    private var snapshot: ReferenceVisualSnapshot { frame.snapshot }

    init() {
        let runner = try! VisualSimulationDriver()
        _runner = State(initialValue: runner)
        _frame = State(initialValue: runner.frame)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { timeline in
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Canvas { context, size in render(snapshot, in: &context, size: size) }
                        .background(Color(red: 0.025, green: 0.04, blue: 0.07))
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            if let point = VisualSimulationDriver.worldPoint(
                                x: drag.location.x, y: drag.location.y,
                                width: proxy.size.width, height: proxy.size.height) {
                                runner.movePolygon(to: point)
                            }
                        })
                    controls
                }
                .onChange(of: timeline.date) { date in
                    guard !isPaused else { return }
                    Task { frame = await runner.advance(to: date.timeIntervalSinceReferenceDate) }
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("Silnik", selection: $backend) {
                    Text("CPU reference").tag(ReferenceSimulationBackend.cpu)
                    Text("GPU native").tag(ReferenceSimulationBackend.nativeMetal)
                }
                .pickerStyle(.segmented)
            }
            HStack {
                Picker("Liczba baniek", selection: $density) {
                    Text("6").tag(ReferenceVisualDensity.six)
                    Text("24").tag(ReferenceVisualDensity.twentyFour)
                    Text("300").tag(ReferenceVisualDensity.threeHundred)
                }
                .pickerStyle(.segmented)
                Button(showsDiagnostics ? "Ukryj dane" : "Dane") { showsDiagnostics.toggle() }
                Button(isPaused ? "Wznów" : "Pauza") { isPaused.toggle() }
                Button("Reset") {
                    runner.reset()
                    frame = runner.frame
                }
            }
            Text(frame.fallbackReason.map { "CPU fallback: \($0)" }
                 ?? (frame.actualBackend == .nativeMetal ? "GPU native · XPBD/PBD 4" : "CPU reference"))
                .foregroundStyle(frame.fallbackReason == nil ? Color.primary : Color.orange)
            Text(String(format: "GPU %.2f ms · kontakty %d · containment %d · non-finite %@",
                        frame.gpuMilliseconds, snapshot.contacts.count, frame.containmentCount,
                        frame.hasNonFiniteState ? "tak" : "nie"))
            if showsDiagnostics {
                Toggle("Punkty kontaktowe", isOn: $showsPoints)
                Toggle("Siły kontaktów", isOn: $showsContactForces)
                let report = snapshot.lastReport
                if frame.actualBackend == .cpu {
                    Text(String(format: "%.2f ms · Newton %d · PCG %d · grupy %d%@", report.totalMilliseconds, report.solver.iterations, report.solver.pcgIterationCount, report.eventGroupCount, report.didReachEventGroupLimit ? " LIMIT" : ""))
                }
                Text(String(format: "ścisk %.3f · residual %.2f→%.2f", report.solver.maximumCompression, report.solver.initialResidualNorm, report.solver.finalResidualNorm))
                Text(String(format: "guard %d · kontakty %d · non-finite %@", report.centerGuardCount, report.persistentContactCount, report.hasNonFiniteState ? "tak" : "nie"))
            }
        }
        .font(.caption.monospacedDigit())
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding()
        .onChange(of: density) { value in
            runner.setDensity(value)
            frame = runner.frame
        }
        .onChange(of: backend) { value in
            runner.setBackend(value)
            frame = runner.frame
        }
    }

    private func render(_ snapshot: ReferenceVisualSnapshot, in context: inout GraphicsContext, size: CGSize) {
        let scale = min(size.width / 375, size.height / 700)
        let offset = CGPoint(x: (size.width - 375 * scale) * 0.5, y: (size.height - 700 * scale) * 0.5)
        func point(_ value: ReferenceVector2) -> CGPoint {
            CGPoint(x: offset.x + CGFloat(value.x) * scale, y: offset.y + CGFloat(value.y) * scale)
        }

        var chamber = Path()
        chamber.addRect(CGRect(x: offset.x, y: offset.y, width: 375 * scale, height: 700 * scale))
        context.stroke(chamber, with: .color(.white.opacity(0.75)), lineWidth: 2)

        for bubble in snapshot.bubbles {
            guard let contour = snapshot.contours[bubble.id], contour.count >= 3 else { continue }
            // The physics contour is already densely sampled and smoothed in radius space.
            // A second quadratic interpolation can overshoot a rigid edge between samples.
            let path = closedPath(contour.map(point))
            let hue = Double((bubble.id.rawValue * 37) % 360) / 360
            context.fill(path, with: .color(Color(hue: hue, saturation: 0.68, brightness: 0.88)))
            context.stroke(path, with: .color(.white.opacity(0.38)), lineWidth: 1.5)

            var labelContext = context
            let center = point(bubble.center)
            labelContext.translateBy(x: center.x, y: center.y)
            labelContext.rotate(by: .radians(Double(bubble.rotation)))
            labelContext.draw(
                Text(String(snapshot.valuesByBubbleID[bubble.id] ?? 0))
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

        if showsContactForces {
            let bubblesByID = Dictionary(uniqueKeysWithValues: snapshot.bubbles.map { ($0.id, $0) })
            for contact in snapshot.contacts where contact.pressure > 0 {
                guard let bubble = bubblesByID[contact.bubbleA] else { continue }
                let origin = point(contact.pointQ)
                let length = min(28, max(5, CGFloat(log1p(contact.pressure)) * 2.5)) * scale
                let forceDirection = (bubble.center - contact.pointQ)
                    .normalized(or: -contact.normal)
                let direction = CGPoint(
                    x: CGFloat(forceDirection.x) * length,
                    y: CGFloat(forceDirection.y) * length
                )
                var force = Path()
                force.move(to: origin)
                force.addLine(to: CGPoint(x: origin.x + direction.x, y: origin.y + direction.y))
                context.stroke(force, with: .color(.pink), lineWidth: 2)
                context.fill(
                    Path(ellipseIn: CGRect(x: origin.x - 2, y: origin.y - 2, width: 4, height: 4)),
                    with: .color(.yellow)
                )
            }
        }
    }

    private func closedPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count >= 3 else { return path }
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}
