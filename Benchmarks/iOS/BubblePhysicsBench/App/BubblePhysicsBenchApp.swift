import SwiftUI

@main
struct BubblePhysicsBenchApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ReferenceBenchmarkView()
                    .navigationTitle("CPU/GPU reference")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Menu("Wizualizacje") {
                                NavigationLink("Publiczny renderer Metal") { PublicMetalPreviewView() }
                                NavigationLink("Publiczny stress-300") { PublicWorldStressView() }
                                NavigationLink("Diagnostyka CPU/GPU") {
                                    ReferenceVisualPrototypeView()
                                        .navigationTitle("Bańki CPU/GPU")
                                        .navigationBarTitleDisplayMode(.inline)
                                }
                            }
                        }
                    }
            }
        }
    }
}
