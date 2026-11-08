import BubblePhysicsModel

/// Usunięcie po ukończonym kroku obejmuje także harmonogram parametrów obiektu.
package enum RegionPolicy {
    static func remove(_ ids: Set<ObjectID>, from state: inout RuntimeState) {
        for id in ids { state.objects.removeValue(forKey: id) }
        // Usunięcie po kroku nie jest transakcją, więc więzy znikają bez potwierdzenia; partner porusza się swobodnie.
        state.joints = state.joints.filter { _, joint in
            !ids.contains(joint.bodyA) && !(joint.bodyB.map(ids.contains) ?? false)
        }
        state.transitions = state.transitions.filter { target, _ in
            switch target {
            case .bubbleRadius(let id), .objectPresentation(let id, _): return !ids.contains(id)
            default: return true
            }
        }
        state.transitionProgress = state.transitionProgress.filter { state.transitions[$0.key] != nil }
    }
}
