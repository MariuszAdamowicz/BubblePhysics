import BubblePhysicsReference
import BubblePhysicsReferenceMetal
import BubblePhysicsNativeMetal
import SwiftUI
import UIKit

struct ReferenceBenchmarkView: View {
    @StateObject private var model: ReferenceBenchmarkPresentation

    init() {
        _model = StateObject(wrappedValue: ReferenceBenchmarkPresentation(
            runner: { configuration, progress in
                if configuration.backend == .nativeMetal {
                    return try await NativeMetalBenchmarkRunner.measure(configuration: configuration, progress: progress)
                }
                return try await ReferenceMetalBenchmarkRunner.measure(configuration: configuration, progress: progress)
            },
            setRunActivity: { active in
                UIApplication.shared.isIdleTimerDisabled = active
            }
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Benchmark zbieżności CPU/GPU").font(.title2.bold())

                Picker("Backend", selection: $model.backend) {
                    Text("CPU reference").tag(ReferenceSimulationBackend.cpu)
                    Text("GPU reference").tag(ReferenceSimulationBackend.metal)
                    Text("GPU native").tag(ReferenceSimulationBackend.nativeMetal)
                }
                .pickerStyle(.segmented)
                .disabled(model.isRunning)

                if model.backend == .metal {
                    Toggle("Szczegółowy profil GPU", isOn: $model.gpuDiagnosticsEnabled)
                        .disabled(model.isRunning)
                    Text("Diagnostyka dodaje narzut hosta. Nie porównuj jej czasów z pomiarem akceptacyjnym bez diagnostyki.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Smoke: 24 bańki, jeden limit 4. Macierze uruchom po smoke bez fallbacku i hang. Raport podaje ukończone czasy etapów GPU, liczniki solve/CCD i pierwszy fatalny błąd. Każdy fallback wyklucza kwalifikację GPU.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Podczas benchmarku ekran nie wygasza się automatycznie. Pozostaw aplikację na pierwszym planie; przejście do tła nadal unieważnia pomiar GPU.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.backend == .nativeMetal {
                    Text("GPU native: stała liczba iteracji XPBD/PBD. Raport obejmuje pełną klatkę, cache kontaktów, CCD i liczbę command bufferów. Każdy fallback wyklucza pomiar GPU.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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
                    Picker(model.backend == .nativeMetal ? "Iteracje XPBD/PBD" : "Limit Newtona", selection: $model.selectedLimit) {
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
            .padding(.top, 18)
            .padding(.bottom, 30)
        }
        .background(Color(.systemBackground))
        .onDisappear { model.stop() }
    }
}
