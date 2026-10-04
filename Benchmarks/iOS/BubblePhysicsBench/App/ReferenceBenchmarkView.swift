import BubblePhysicsReference
import SwiftUI
import UIKit

struct ReferenceBenchmarkView: View {
    @StateObject private var model = ReferenceBenchmarkPresentation()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Benchmark zbieżności CPU").font(.title2.bold())

                Picker("Scena", selection: $model.scene) {
                    Text("24 bańki").tag(ReferenceConvergenceScene.interactive24)
                    Text("300 baniek").tag(ReferenceConvergenceScene.stress300)
                }
                .pickerStyle(.segmented)
                .disabled(model.isRunning)

                Picker("Tryb", selection: $model.mode) {
                    Text("Jeden limit").tag(ReferenceBenchmarkMode.single)
                    Text("Macierz 4/8/12/16").tag(ReferenceBenchmarkMode.matrix)
                }
                .pickerStyle(.segmented)
                .disabled(model.isRunning)

                if model.mode == .single {
                    Picker("Limit Newtona", selection: $model.selectedLimit) {
                        ForEach([4, 8, 12, 16], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRunning)
                }

                ProgressView(value: model.progress)

                HStack(spacing: 12) {
                    Button("Start") {
                        model.start(
                            deviceName: UIDevice.current.name,
                            systemVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isRunning)

                    Button("Stop") { model.stop() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(!model.isRunning)
                }

                if let text = model.reportText {
                    HStack {
                        Text("Raport").font(.headline)
                        Spacer()
                        Button("Kopiuj") { UIPasteboard.general.string = text }
                            .buttonStyle(.bordered)
                    }
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 90)
            .padding(.bottom, 30)
        }
        .background(Color(.systemBackground))
        .onDisappear { model.stop() }
    }
}
