import BubblePhysics
import BubblePhysicsAssets
import CoreGraphics
import Metal

/// Scena baniek: tekstury i naklejki z liczbą, scalanie dwóch baniek po zetknięciu (liczby się sumują) i chwyt palcem.
@MainActor
final class BubbleScene: ShowcaseScene {
    let configuration: WorldConfiguration
    let clearColor = MTLClearColorMake(0.08, 0.09, 0.12, 1)

    private static let bubblePhysics = PhysicsMaterialID(rawValue: 1)
    private static let wallPhysics = PhysicsMaterialID(rawValue: 2)
    private static let wallLook = RenderMaterialID(rawValue: 10)
    /// Najwyższa liczba na bańce; bańka o tej liczbie przestaje się scalać.
    private static let maximumValue = 8
    private static let mergeGroup = MergeGroupSet(rawValue: 1)
    /// Kolory gradientów: wartość 1, 2–3, 4–7, 8.
    private static let tints: [(top: SIMD3<Float>, bottom: SIMD3<Float>)] = [
        ([0.55, 0.85, 1.0], [0.20, 0.45, 0.95]), ([0.65, 1.0, 0.70], [0.15, 0.65, 0.35]),
        ([1.0, 0.85, 0.50], [0.95, 0.50, 0.15]), ([1.0, 0.65, 0.85], [0.85, 0.20, 0.50])
    ]

    private var font: FontID?
    private var values: [ObjectID: Int] = [:]
    private var nextID: UInt64 = 1_000
    private var handledStep: UInt64 = 0
    private var pendingMerges: [TransactionToken: PendingMerge] = [:]
    private var grabbed: ObjectID?
    private var isTouching = false

    private struct PendingMerge {
        let sources: [ObjectID]
        let result: ObjectID
        let value: Int
    }

    init() throws {
        configuration = try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [0, 0], max: [360, 640]),
            fixedTimeStep: 1.0 / 60, globalForce: [0, -40])
    }

    private static func tier(of value: Int) -> Int {
        switch value {
        case ..<2: return 0
        case 2..<4: return 1
        case 4..<Self.maximumValue: return 2
        default: return 3
        }
    }

    /// Gradient 64×64 z alfą 1, więc alfa przemnożona nie zmienia kolorów.
    private static func gradient(top: SIMD3<Float>, bottom: SIMD3<Float>) throws -> CGImage {
        let side = 64
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for row in 0..<side {
            let mix = Float(row) / Float(side - 1)
            let color = top + (bottom - top) * mix
            for column in 0..<side {
                let offset = (row * side + column) * 4
                pixels[offset] = UInt8(color.x * 255); pixels[offset + 1] = UInt8(color.y * 255)
                pixels[offset + 2] = UInt8(color.z * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw AssetError.unsupportedImage }
        return image
    }

    // guide-region: register-assets
    /// Zasoby rejestruje się synchronicznie, poza klatką; transakcje wskazują je przez identyfikatory z rejestru.
    func prepare(assets: AssetRegistry) throws -> WorldTransaction {
        let textures = try Self.tints.map { try assets.register(Self.gradient(top: $0.top, bottom: $0.bottom)) }
        let font = try assets.register(font: "Helvetica-Bold", characters: "0123456789")
        self.font = font
        var transaction = WorldTransaction()
            .updatePhysicsMaterial(Self.bubblePhysics, material: try PhysicsMaterial(kind: .bubble, deformability: 0.6))
            .updatePhysicsMaterial(Self.wallPhysics, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(Self.wallLook, material: try RenderMaterial(color: RGBA(0.25, 0.27, 0.33, 1)))
        for (index, texture) in textures.enumerated() {
            transaction = transaction.updateRenderMaterial(RenderMaterialID(rawValue: UInt64(index + 1)),
                material: try RenderMaterial(texture: texture, outline: RenderOutline(color: .white, width: 1.5)))
        }
        return try addObjects(to: transaction)
    }
    // guide-region-end

    private func addObjects(to start: WorldTransaction) throws -> WorldTransaction {
        var transaction = start
        for wall in try showcaseWalls(region: configuration.simulationRegion, physics: Self.wallPhysics,
                                      render: Self.wallLook, firstID: 1) {
            transaction = transaction.add(.rigidBody(wall))
        }
        for index in 0..<42 {
            let column = index % 6, row = index / 6
            let id = ObjectID(rawValue: nextID)
            nextID += 1
            values[id] = 1
            transaction = transaction.add(.bubble(try BubbleDescriptor(
                id: id, position: [30 + Float(column) * 60 + .random(in: -4...4), 300 + Float(row) * 45],
                targetRadius: .random(in: 16...20), mass: 4,
                physicsMaterialID: Self.bubblePhysics, renderMaterialID: RenderMaterialID(rawValue: 1),
                mergeGroups: Self.mergeGroup, eventInterest: .mergeContact, decal: try decal(for: 1))))
        }
        return transaction
    }

    // guide-region: decal
    /// Naklejka tekstowa z liczbą; znaki muszą należeć do zestawu zarejestrowanego z czcionką.
    private func decal(for value: Int) throws -> Decal? {
        guard let font else { return nil }
        return try Decal.text(String(value), source: .font(font), color: .white, scale: 1)
    }
    // guide-region-end

    // guide-region: merge-events
    /// Zdarzenia opt-in (`eventInterest`) przychodzą w klatce świata. Scena zamienia `mergeContact` na transakcję
    /// scalenia i śledzi jej los po tokenie: potwierdzenie albo `transactionRejected`.
    func update(frame: WorldFrame, world: BubbleWorld) {
        // Brak nowego kroku zwraca tę samą klatkę; `stepIndex` chroni przed podwójną obsługą zdarzeń.
        guard frame.stepIndex != handledStep else { return }
        handledStep = frame.stepIndex
        for receipt in frame.transactionReceipts {
            guard let merge = pendingMerges.removeValue(forKey: receipt.token) else { continue }
            for source in merge.sources { values[source] = nil }
            values[merge.result] = merge.value
        }
        let busy = Set(pendingMerges.values.flatMap(\.sources))
        var claimed = busy
        for event in frame.events {
            switch event {
            case .transactionRejected(let token, _):
                pendingMerges[token] = nil
            case .mergeContact(let first, let second, _):
                guard !claimed.contains(first), !claimed.contains(second),
                      let a = values[first], let b = values[second] else { continue }
                claimed.formUnion([first, second])
                merge(first, second, value: a + b, world: world)
            default:
                break
            }
        }
    }

    private func merge(_ first: ObjectID, _ second: ObjectID, value: Int, world: BubbleWorld) {
        let id = ObjectID(rawValue: nextID)
        nextID += 1
        let isFinal = value >= Self.maximumValue
        do {
            let result = BubbleResult(
                id: id, physicsMaterialID: Self.bubblePhysics,
                renderMaterialID: RenderMaterialID(rawValue: UInt64(Self.tier(of: value) + 1)),
                mergeGroups: isFinal ? [] : Self.mergeGroup, eventInterest: isFinal ? [] : .mergeContact,
                decal: try decal(for: value))
            let token = world.submit(WorldTransaction().mergeBubbles([first, second], result: result))
            pendingMerges[token] = PendingMerge(sources: [first, second], result: id, value: value)
        } catch {
            print("Showcase: nie udało się zbudować scalenia: \(error)")
        }
    }
    // guide-region-end

    // guide-region: hit-test
    /// Dokładny hit-test liczy GPU na konturach następnego kroku, więc odpowiedź przychodzi po kroku. Palec mógł się
    /// w tym czasie unieść: wtedy chwyt się nie zaczyna.
    func touchBegan(at point: WorldPoint, world: BubbleWorld) async {
        isTouching = true
        guard let id = await world.hitTest(point), isTouching, values[id] != nil else { return }
        grabbed = id
        world.submit(WorldTransaction().beginPlayerDrive(id, target: point))
    }
    // guide-region-end

    func touchMoved(to point: WorldPoint, world: BubbleWorld) {
        guard let grabbed else { return }
        world.submit(WorldTransaction().updatePlayerDrive(grabbed, target: point))
    }

    func touchEnded(world: BubbleWorld) {
        isTouching = false
        guard let grabbed else { return }
        self.grabbed = nil
        world.submit(WorldTransaction().endPlayerDrive(grabbed))
    }
}
