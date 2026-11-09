import Foundation
import BubblePhysicsAssets
import BubblePhysicsModel
import BubblePhysicsRuntime
import BubblePhysicsNativeMetal

/// Lista rysowania opublikowanego stanu: tło i warstwy rosnąco, w warstwie bańki, potem bryły, każda grupa rosnąco po
/// `ObjectID`. Czujniki i pola sił nie mają materiału renderu, więc ich tu nie ma.
package struct BubbleWorldRenderState {
    package let handoff: NativeMetalRenderHandoff?
    /// Tekstura tła rozciągnięta na region symulacji; `nil`, gdy tła nie ma.
    package let background: TextureID?
    package let region: WorldRectangle
    package let layers: [BubbleWorldRenderLayer]
    /// Waga stanu t w obrazie między t−1 i t (1 = sam stan t).
    package let interpolation: Float
    /// Obiekty rysowane bez interpolacji w tej klatce (pojawiły się albo zawinęły w ostatnim kroku).
    package let snapped: Set<ObjectID>
}

package struct BubbleWorldRenderLayer {
    package let layer: Int32
    package let bubbles: [BubbleWorldRenderBubble]
    package let shapes: [BubbleWorldRenderShape]
}

package struct BubbleWorldRenderBubble {
    package let id: ObjectID
    package let materialID: RenderMaterialID
    package let material: RenderMaterial
    /// Naklejka rysowana po wszystkich bańkach warstwy; kotwicę i promień odniesienia (efektywny) renderer bierze z uchwytu.
    package let decal: Decal?
}

package struct BubbleWorldRenderShape {
    package let id: ObjectID
    package let materialID: RenderMaterialID
    package let material: RenderMaterial
    /// Pierścień we współrzędnych lokalnych obiektu. Triangulacja zależy tylko od niego, bo przekształcenie sztywne zachowuje
    /// orientację i zawieranie. Pozę (z interpolacją t−1 → t) nakłada shader z rekordu bryły w uchwycie.
    package let localVertices: [WorldPoint]
    /// Naklejka rysowana po wszystkich bryłach warstwy; jej kotwica to początek układu lokalnego bryły (`position`), obraca się z bryłą.
    package let decal: Decal?
    /// Promień okręgu opisanego na kształcie wokół kotwicy (promień odniesienia naklejki).
    package let referenceRadius: Float
}

extension BubbleWorld {
    /// Lista rysowania z `source`: warstwy rosnąco, w nich bańki i bryły rosnąco po `ObjectID`. Obiekt bez materiału renderu
    /// (czujnik, pole sił) nie jest rysowany.
    func makeRenderState(_ handoff: NativeMetalRenderHandoff?, from source: RuntimeState, interpolation: Float,
                                 snapped: Set<ObjectID>) -> BubbleWorldRenderState {
        var bubbles: [Int32: [BubbleWorldRenderBubble]] = [:], shapes: [Int32: [BubbleWorldRenderShape]] = [:]
        for (id, object) in source.objects.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let materialID = object.renderMaterialID, let material = source.renderMaterials[materialID] else { continue }
            switch object.descriptor {
            case .bubble:
                bubbles[object.layer, default: []].append(
                    BubbleWorldRenderBubble(id: id, materialID: materialID, material: material, decal: object.decal))
            case .rigidBody(let body):
                shapes[object.layer, default: []].append(BubbleWorldRenderShape(id: id, materialID: materialID,
                    material: material, localVertices: Self.rigidRing(body.shape), decal: object.decal,
                    referenceRadius: object.decal == nil ? 0 : Self.circumscribedRadius(body.shape)))
            case .sensor, .forceField: continue
            }
        }
        let layers = Set(bubbles.keys).union(shapes.keys).sorted().map {
            BubbleWorldRenderLayer(layer: $0, bubbles: bubbles[$0] ?? [], shapes: shapes[$0] ?? [])
        }
        return BubbleWorldRenderState(handoff: handoff, background: source.background,
                                      region: source.configuration.simulationRegion, layers: layers,
                                      interpolation: interpolation, snapped: snapped)
    }

    /// Promień okręgu opisanego na kształcie wokół początku układu lokalnego (kotwicy naklejki).
    private static func circumscribedRadius(_ shape: RigidShape) -> Float {
        switch shape {
        case .polygon(let geometry): return geometry.vertices.map { ($0 * $0).sum().squareRoot() }.max() ?? 0
        case .circle(let radius): return radius
        case .capsule(let halfLength, let radius): return halfLength + radius
        }
    }

    /// Obrys bryły do rysowania jako pierścień; koło i kapsuła to wielokąty o 48 wierzchołkach na pełny obrót.
    private static func rigidRing(_ shape: RigidShape) -> [WorldPoint] {
        switch shape {
        case .polygon(let geometry): return geometry.vertices
        case .circle(let radius):
            return (0..<48).map { index in
                let angle = Float(index) * 2 * Float.pi / 48
                return WorldPoint(radius * cos(angle), radius * sin(angle))
            }
        case .capsule(let halfLength, let radius):
            // Prawe półkole od −90° do 90°, potem lewe od 90° do 270°, środki na końcach osi.
            let arc = 24
            let right = (0...arc).map { index -> WorldPoint in
                let angle = -Float.pi / 2 + Float(index) * Float.pi / Float(arc)
                return WorldPoint(halfLength + radius * cos(angle), radius * sin(angle))
            }
            let left = (0...arc).map { index -> WorldPoint in
                let angle = Float.pi / 2 + Float(index) * Float.pi / Float(arc)
                return WorldPoint(-halfLength + radius * cos(angle), radius * sin(angle))
            }
            return right + left
        }
    }
}
