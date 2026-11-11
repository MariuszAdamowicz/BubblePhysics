import Foundation
import Metal
import BubblePhysicsModel

// Prywatny ABI Swift/MSL rekordu więzu. Koniec więzu to indeks obiektu w wspólnej przestrzeni solvera:
// najpierw bańki (0..<n), potem bryły (n..<n+P); `NativeJointRecord.worldEnd` oznacza punkt świata.
struct NativeJointRecord: Equatable {
    static let worldEnd = UInt32.max
    var identity: SIMD2<UInt64> // JointID, reserved
    var ends: SIMD4<UInt32> // koniec 0, koniec 1, rodzaj (0 dystans, 1 zawias, 2 spaw), flagi (1 zakres, 2 silnik)
    var anchors: SIMD4<Float> // kotwica końca 0 i końca 1: układ lokalny bryły albo punkt świata
    var parameters: SIMD4<Float> // długość, podatność, tłumienie, kąt odniesienia
    var limits: SIMD4<Float> // dolna i górna granica kąta, docelowa prędkość silnika, maksymalny moment
    var state: SIMD4<Float> // skumulowane λ w kroku: dystans, silnik, reserved ×2
}

/// Więzy kroku w buforach GPU. Rekordy leżą posortowane po `JointID`; każdy obiekt (bańka albo bryła) ma własną listę
/// swoich więzów i posortowaną listę partnerów, z którymi nie koliduje (`collideConnected == false`). Dzięki listom
/// kernele sumują korekty w stałej kolejności, bez atomików, a kandydaci pomijają połączone pary jednym przeszukaniem
/// krótkiej listy. Więzy są budowane na CPU co krok (jest ich mało), a gdy ich nie ma, kernele dostają stałe puste bufory.
@MainActor
final class NativeJointState {
    private let device: MTLDevice
    private var buffers: [String: MTLBuffer] = [:]
    private(set) var count = 0
    /// Rekordy więzów posortowane po `JointID`.
    var records: MTLBuffer { buffers["records"]! }
    var corrections: MTLBuffer { buffers["corrections"]! }
    /// Wpis listy obiektu: (indeks więzu, strona 0 albo 1).
    var references: MTLBuffer { buffers["references"]! }
    /// Na obiekt (bańki, potem bryły): początek i długość listy więzów, początek i długość listy partnerów bez kolizji.
    var ranges: MTLBuffer { buffers[count > 0 ? "ranges" : "zeroRanges"]! }
    var exclusions: MTLBuffer { buffers["exclusions"]! }
    /// Liczniki dla kerneli: więzy, bańki, bryły, iteracje.
    var control: MTLBuffer { buffers["control"]! }

    init(device: MTLDevice) { self.device = device }

    private func buffer(_ name: String, count: Int, stride: Int, zeroed: Bool = false) throws -> MTLBuffer {
        let (length, overflow) = max(1, count).multipliedReportingOverflow(by: stride)
        guard !overflow, length <= device.maxBufferLength else { throw NativeMetalSolverError.capacityOverflow }
        if let value = buffers[name], value.length >= length { return value }
        guard let value = device.makeBuffer(length: length, options: .storageModeShared) else { throw NativeMetalSolverError.allocationFailed }
        value.label = "native.joint.\(name)"
        if zeroed { memset(value.contents(), 0, value.length) }
        buffers[name] = value
        return value
    }

    /// Krok bez więzów: ten sam stan co `prepare([], …)`, bez list identyfikatorów i słownika encji.
    func prepareWithoutJoints(bubbleCount: Int, bodyCount: Int, iterations: Int) throws {
        let control = try prepareBuffers(entityCount: bubbleCount + bodyCount)
        count = 0
        control.contents().storeBytes(of: SIMD4(UInt32(0), UInt32(bubbleCount), UInt32(bodyCount),
                                                UInt32(clamping: iterations)), as: SIMD4<UInt32>.self)
    }

    /// Bufory z kernelami zawsze istnieją: bez więzów to jednoelementowe zera i puste listy.
    private func prepareBuffers(entityCount: Int) throws -> MTLBuffer {
        _ = try buffer("zeroRanges", count: entityCount, stride: MemoryLayout<SIMD4<UInt32>>.stride, zeroed: true)
        _ = try buffer("exclusions", count: 1, stride: MemoryLayout<UInt64>.stride)
        return try buffer("control", count: 1, stride: 16)
    }

    func prepare(_ joints: [Joint], bubbleIDs: [ObjectID], bodyIDs: [ObjectID], iterations: Int) throws {
        let entityCount = bubbleIDs.count + bodyIDs.count
        let control = try prepareBuffers(entityCount: entityCount)
        var entity: [ObjectID: UInt32] = [:]
        entity.reserveCapacity(entityCount)
        for (index, id) in bubbleIDs.enumerated() { entity[id] = UInt32(index) }
        for (index, id) in bodyIDs.enumerated() { entity[id] = UInt32(bubbleIDs.count + index) }

        var rows: [NativeJointRecord] = []
        var lists = [[SIMD2<UInt32>]](repeating: [], count: entityCount)
        var partners = [[UInt64]](repeating: [], count: entityCount)
        // Jedyne sortowanie więzów po JointID: kolejność wierszy musi być deterministyczna niezależnie od wywołującego.
        for joint in joints.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            guard let first = entity[joint.bodyA] else { continue }
            var ends = (first, joint.bodyB.flatMap { entity[$0] } ?? NativeJointRecord.worldEnd)
            if joint.bodyB != nil && ends.1 == NativeJointRecord.worldEnd { continue }
            var anchors = (joint.anchorA, joint.anchorB)
            // Więz ze światem: świat jest końcem 0, ciało końcem 1. Względny kąt i prędkość kątowa (zakres, silnik)
            // to wtedy kąt i prędkość kątowa ciała względem świata.
            if joint.bodyB == nil { ends = (NativeJointRecord.worldEnd, first); anchors = (joint.anchorB, joint.anchorA) }
            var kind: UInt32 = 0, flags: UInt32 = 0
            var parameters = SIMD4<Float>.zero, limits = SIMD4<Float>.zero
            switch joint.kind {
            case .distance(let length, let softness, let damping):
                parameters = SIMD4(length, softness, damping, 0)
            case .hinge(let hingeLimits, let motor):
                kind = 1; parameters.w = joint.referenceAngle
                if let hingeLimits { flags |= 1; limits.x = hingeLimits.lower; limits.y = hingeLimits.upper }
                if let motor { flags |= 2; limits.z = motor.targetAngularVelocity; limits.w = motor.maximumTorque }
            case .weld:
                kind = 2; parameters.w = joint.referenceAngle
            }
            let index = UInt32(rows.count)
            rows.append(NativeJointRecord(identity: SIMD2(joint.id.rawValue, 0), ends: SIMD4(ends.0, ends.1, kind, flags),
                anchors: SIMD4(anchors.0.x, anchors.0.y, anchors.1.x, anchors.1.y), parameters: parameters,
                limits: limits, state: .zero))
            if ends.0 != NativeJointRecord.worldEnd { lists[Int(ends.0)].append(SIMD2(index, 0)) }
            lists[Int(ends.1)].append(SIMD2(index, 1))
            if !joint.collideConnected, let second = joint.bodyB {
                partners[Int(first)].append(second.rawValue)
                partners[Int(ends.1)].append(joint.bodyA.rawValue)
            }
        }
        count = rows.count
        control.contents().storeBytes(of: SIMD4(UInt32(count), UInt32(bubbleIDs.count), UInt32(bodyIDs.count),
                                                UInt32(clamping: iterations)), as: SIMD4<UInt32>.self)
        guard count > 0 else { return }
        _ = try buffer("records", count: count, stride: MemoryLayout<NativeJointRecord>.stride)
        _ = try buffer("corrections", count: count, stride: MemoryLayout<NativeRigidCorrection>.stride)
        let referenceTotal = lists.reduce(0) { $0 + $1.count }
        _ = try buffer("references", count: referenceTotal, stride: MemoryLayout<SIMD2<UInt32>>.stride)
        _ = try buffer("ranges", count: entityCount, stride: MemoryLayout<SIMD4<UInt32>>.stride)
        let exclusionTotal = partners.reduce(0) { $0 + Set($1).count }
        _ = try buffer("exclusions", count: exclusionTotal, stride: MemoryLayout<UInt64>.stride)
        let recordPointer = records.contents().bindMemory(to: NativeJointRecord.self, capacity: count)
        for (index, row) in rows.enumerated() { recordPointer[index] = row }
        let referencePointer = references.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: max(1, referenceTotal))
        let exclusionPointer = exclusions.contents().bindMemory(to: UInt64.self, capacity: max(1, exclusionTotal))
        let rangePointer = ranges.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: max(1, entityCount))
        var referenceCursor = 0, exclusionCursor = 0
        for index in 0..<entityCount {
            let sorted = Set(partners[index]).sorted()
            rangePointer[index] = SIMD4(UInt32(referenceCursor), UInt32(lists[index].count),
                                        UInt32(exclusionCursor), UInt32(sorted.count))
            for reference in lists[index] { referencePointer[referenceCursor] = reference; referenceCursor += 1 }
            for partner in sorted { exclusionPointer[exclusionCursor] = partner; exclusionCursor += 1 }
        }
    }
}
