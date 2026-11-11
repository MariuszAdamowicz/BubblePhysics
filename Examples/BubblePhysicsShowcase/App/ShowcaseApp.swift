import SwiftUI

@main
struct ShowcaseApp: App {
    var body: some Scene {
        WindowGroup {
            ShowcaseRootView()
        }
    }
}

enum ShowcaseKind: String, CaseIterable, Identifiable {
    case bubbles = "Bańki"
    case bodies = "Bryły"

    var id: String { rawValue }

    @MainActor func makeScene() throws -> any ShowcaseScene {
        switch self {
        case .bubbles: return try BubbleScene()
        case .bodies: return try RigidScene()
        }
    }
}

/// Przełącznik dwóch scen i ręczna pauza. Zmiana sceny tworzy nowy świat, bo świat nie ma zapisu ani resetu.
struct ShowcaseRootView: View {
    @State private var kind = ShowcaseKind.bubbles
    @State private var isPaused = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Scena", selection: $kind) {
                ForEach(ShowcaseKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            MetalHostView(kind: kind, isPaused: isPaused)
                .id(kind)
                .ignoresSafeArea(edges: .bottom)
            Button(isPaused ? "Wznów" : "Pauza") { isPaused.toggle() }
                .padding()
        }
        .onChange(of: kind) { _ in isPaused = false }
    }
}
