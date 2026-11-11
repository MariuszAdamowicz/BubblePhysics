import BubblePhysics
import BubblePhysicsAssets
import Metal

/// Scena przykładu: konfiguracja świata, rejestracja zasobów z transakcją startową, reakcja na zdarzenia klatki i dotyk.
/// Host (`MetalHostView`) nie zna zawartości sceny; scena nie zna Metala poza kolorem tła.
@MainActor
protocol ShowcaseScene: AnyObject {
    var configuration: WorldConfiguration { get }
    var clearColor: MTLClearColor { get }
    /// Rejestruje zasoby w rejestrze świata (synchronicznie, poza klatką) i zwraca transakcję, która buduje scenę.
    func prepare(assets: AssetRegistry) throws -> WorldTransaction
    /// Wołane raz na klatkę hosta z ostatnią opublikowaną klatką świata; zdarzenia zamienia na transakcje.
    func update(frame: WorldFrame, world: BubbleWorld)
    func touchBegan(at point: WorldPoint, world: BubbleWorld) async
    func touchMoved(to point: WorldPoint, world: BubbleWorld)
    func touchEnded(world: BubbleWorld)
}

extension ShowcaseScene {
    /// Kamera pokazuje cały region symulacji; przy innej proporcji widoku odsłania więcej świata z jednej strony.
    func viewport(aspect: Float) throws -> Viewport {
        let region = configuration.simulationRegion
        let size = region.max - region.min
        let visible: WorldPoint = aspect > size.x / size.y ? [size.y * aspect, size.y] : [size.x, size.x / aspect]
        return try Viewport(center: (region.min + region.max) / 2, size: visible)
    }
}

/// Cztery ściany z krawędzi regionu symulacji: region to pojemność obliczeniowa, a nie fizyczna ściana.
func showcaseWalls(region: WorldRectangle, physics: PhysicsMaterialID, render: RenderMaterialID,
                   firstID: UInt64) throws -> [RigidBodyDescriptor] {
    let low = region.min, high = region.max
    let rings: [[WorldPoint]] = [
        [[low.x, low.y], [low.x + 1, low.y], [low.x + 1, high.y], [low.x, high.y]],
        [[high.x - 1, low.y], [high.x, low.y], [high.x, high.y], [high.x - 1, high.y]],
        [[low.x, low.y], [high.x, low.y], [high.x, low.y + 1], [low.x, low.y + 1]],
        [[low.x, high.y - 1], [high.x, high.y - 1], [high.x, high.y], [low.x, high.y]]
    ]
    return try rings.enumerated().map { index, vertices in
        try RigidBodyDescriptor(id: ObjectID(rawValue: firstID + UInt64(index)), vertices: vertices,
                                physicsMaterialID: physics, renderMaterialID: render)
    }
}
