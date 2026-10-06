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
                            NavigationLink("Wizualizacja CPU") {
                                ReferenceVisualPrototypeView()
                                    .navigationTitle("CPU reference")
                                    .navigationBarTitleDisplayMode(.inline)
                            }
                        }
                    }
            }
        }
    }
}
