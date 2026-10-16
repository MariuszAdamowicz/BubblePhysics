import Foundation
import Metal
import BubblePhysicsModel

struct NativeRigidPolygonInput: Equatable, Sendable {
    var object: NativePublicObject
    var damping: Float
}

// Prywatny ABI Swift/MSL. Pozycja publiczna jest początkiem lokalnej geometrii;
// solver przechowuje środek masy i przelicza początek dopiero przy publikacji.
struct NativeRigidBody: Equatable {
    var identity: SIMD2<UInt64>
    var pose: SIMD4<Float> // COM.xy, angle, previous angle
    var previous: SIMD4<Float> // previous COM.xy, local centroid.xy
    var motion: SIMD4<Float> // velocity.xy, angular velocity, damping
    var physical: SIMD4<Float> // inverse mass, inverse moment, radius, reserved
    var ranges: SIMD4<UInt32> // vertex offset/count, convex triangle offset/count
    var flags: SIMD4<UInt32> // static, wrap, region result, reserved
}

struct NativeRigidGeometry {
    let vertices: [SIMD2<Float>]
    let triangles: [SIMD4<UInt32>]
    let centroid: SIMD2<Float>
    let radius: Float

    init(_ geometry: PolygonGeometry) throws {
        var points = geometry.vertices.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        let origin = points[0]
        points = points.map { $0 - origin }
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
        var area = 0.0, weighted = SIMD2<Double>.zero
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count], weight = cross(a, b)
            area += weight; weighted += (a + b) * weight
        }
        let center = weighted / (3 * area)
        if area < 0 { points.reverse() }
        // Usuwamy tylko współliniowe punkty; nie zmieniamy brzegu ani wnęk.
        var changed = true
        while changed && points.count > 3 {
            changed = false
            for i in points.indices {
                let a = points[(i + points.count - 1) % points.count], b = points[i], c = points[(i + 1) % points.count]
                if cross(b - a, c - b) == 0 { points.remove(at: i); changed = true; break }
            }
        }
        var remaining = Array(points.indices), pieces: [SIMD4<UInt32>] = []
        while remaining.count > 3 {
            var ear: Int?
            for i in remaining.indices {
                let a = remaining[(i + remaining.count - 1) % remaining.count], b = remaining[i], c = remaining[(i + 1) % remaining.count]
                guard cross(points[b] - points[a], points[c] - points[a]) > 0 else { continue }
                let contains = remaining.contains { j in
                    j != a && j != b && j != c && cross(points[b] - points[a], points[j] - points[a]) >= 0
                        && cross(points[c] - points[b], points[j] - points[b]) >= 0
                        && cross(points[a] - points[c], points[j] - points[c]) >= 0
                }
                if !contains { pieces.append(SIMD4(UInt32(a), UInt32(b), UInt32(c), 0)); ear = i; break }
            }
            guard let ear else { throw NativeMetalSolverError.invalidSnapshot }
            remaining.remove(at: ear)
        }
        pieces.append(SIMD4(UInt32(remaining[0]), UInt32(remaining[1]), UInt32(remaining[2]), 0))
        centroid = SIMD2(Float(center.x + origin.x), Float(center.y + origin.y))
        vertices = points.map { SIMD2(Float($0.x - center.x), Float($0.y - center.y)) }
        triangles = pieces
        radius = vertices.map { sqrt($0.x * $0.x + $0.y * $0.y) }.max() ?? 0
        guard centroid.x.isFinite, centroid.y.isFinite, radius.isFinite, radius > 0 else { throw NativeMetalSolverError.invalidSnapshot }
    }
}

/// Bufory opublikowane są niezmienne aż do ukończenia całej klatki.
/// Przy normalnym kroku GPU kopiuje stan; CPU przesyła wyłącznie zmiany wejścia.
@MainActor
final class NativeRigidPolygonState {
    private let device: MTLDevice
    private var buffers: [String: MTLBuffer] = [:]
    private var publishedInputs: [NativeRigidPolygonInput] = []
    private var publishedGeometry: [(ObjectID, PolygonGeometry)] = []
    private var geometryCache: [ObjectID: (PolygonGeometry, NativeRigidGeometry)] = [:]
    private var current: [NativeRigidPolygonInput] = []
    private var records: [NativeRigidBody] = []
    private var changes: [Int] = []
    private var remaps: [(Int, Int)] = []
    private var vertexCount = 0
    private var triangleCount = 0
    private var copyPublishedGeometry = false
    private(set) var bodyUploadCount = 0
    private(set) var geometryUploadCount = 0
    private(set) var count = 0
    private(set) var contactCount = 0
    var bodies: MTLBuffer { buffers["working"]! }
    var vertices: MTLBuffer { buffers["vertices"]! }
    var triangles: MTLBuffer { buffers["triangles"]! }
    var contacts: MTLBuffer { buffers["contacts"]! }
    var control: MTLBuffer { buffers["control"]! }

    init(device: MTLDevice) { self.device = device }

    private func buffer(_ name: String, count: Int, stride: Int) throws -> MTLBuffer {
        let (length, overflow) = max(1, count).multipliedReportingOverflow(by: stride)
        guard !overflow, length <= device.maxBufferLength else { throw NativeMetalSolverError.capacityOverflow }
        if let value = buffers[name], value.length >= length { return value }
        guard let value = device.makeBuffer(length: length, options: .storageModeShared) else { throw NativeMetalSolverError.allocationFailed }
        value.label = "native.rigid.\(name)"
        if let previous = buffers[name] { memcpy(value.contents(), previous.contents(), previous.length) }
        buffers[name] = value
        return value
    }

    func prepare(_ inputs: [NativeRigidPolygonInput], bubbleCount: Int) throws {
        current = inputs; count = inputs.count
        let total = UInt64(count) * UInt64(bubbleCount) + UInt64(count) * UInt64(count)
        guard total <= UInt64(UInt32.max) else { throw NativeMetalSolverError.capacityOverflow }
        contactCount = Int(total)
        _ = try buffer("published", count: count, stride: MemoryLayout<NativeRigidBody>.stride)
        _ = try buffer("working", count: count, stride: MemoryLayout<NativeRigidBody>.stride)
        let updates = try buffer("updates", count: count, stride: MemoryLayout<NativeRigidBody>.stride)
        _ = try buffer("contacts", count: contactCount, stride: 64)
        let control = try buffer("control", count: 1, stride: 16)
        control.contents().storeBytes(of: SIMD4(UInt32(count), UInt32(bubbleCount), UInt32(contactCount), 0), as: SIMD4<UInt32>.self)
        records = []; changes = []; remaps = []
        var vertices: [SIMD2<Float>] = [], triangles: [SIMD4<UInt32>] = []
        let old = Dictionary(uniqueKeysWithValues: publishedInputs.enumerated().map { ($0.element.object.descriptor.id, ($0.offset, $0.element)) })
        var newGeometry: [(ObjectID, PolygonGeometry)] = []
        for (index, input) in inputs.enumerated() {
            let o = input.object
            guard case .polygon(let p) = o.descriptor else { throw NativeMetalSolverError.invalidSnapshot }
            let geometry: NativeRigidGeometry
            if let cached = geometryCache[p.id], cached.0 == p.geometry { geometry = cached.1 }
            else { geometry = try NativeRigidGeometry(p.geometry); geometryCache[p.id] = (p.geometry, geometry) }
            newGeometry.append((p.id, p.geometry))
            let c = cos(o.rotation), s = sin(o.rotation), center = geometry.centroid
            let offset = SIMD2(center.x * c - center.y * s, center.x * s + center.y * c)
            let isStatic = o.motionRole == .static
            let record = NativeRigidBody(identity: SIMD2(p.id.rawValue, 0),
                pose: SIMD4(o.position.x + offset.x, o.position.y + offset.y, o.rotation, o.rotation),
                previous: SIMD4(o.previousPosition.x + offset.x, o.previousPosition.y + offset.y, center.x, center.y),
                motion: SIMD4(isStatic ? 0 : o.velocity.x, isStatic ? 0 : o.velocity.y, isStatic ? 0 : o.angularVelocity, input.damping),
                physical: SIMD4(isStatic ? 0 : 1 / p.mass, isStatic ? 0 : 1 / p.momentOfInertia, geometry.radius, 0),
                ranges: SIMD4(UInt32(vertices.count), UInt32(geometry.vertices.count), UInt32(triangles.count), UInt32(geometry.triangles.count)),
                flags: SIMD4(isStatic ? 1 : 0, p.regionExitPolicy == .wrap ? 1 : 0, 0, 0))
            guard record.physical.x.isFinite, record.physical.y.isFinite else { throw NativeMetalSolverError.invalidSnapshot }
            records.append(record)
            vertices += geometry.vertices
            triangles += geometry.triangles
            if let (previousIndex, previousInput) = old[p.id], previousInput == input,
               newGeometry.prefix(index + 1).map({ $0.0 }) == publishedGeometry.prefix(index + 1).map({ $0.0 }) {
                remaps.append((previousIndex, index))
            } else { changes.append(index) }
        }
        let geometryChanged = newGeometry.count != publishedGeometry.count || zip(newGeometry, publishedGeometry).contains { new, old in new.0 != old.0 || new.1 != old.1 }
        // Zestaw i kolejność geometrii mogą zmienić offsety; wtedy rekordy także są staged.
        if geometryChanged { changes = Array(inputs.indices); remaps = [] }
        vertexCount = vertices.count; triangleCount = triangles.count
        _ = try buffer("publishedVertices", count: vertexCount, stride: MemoryLayout<SIMD2<Float>>.stride)
        _ = try buffer("publishedTriangles", count: triangleCount, stride: MemoryLayout<SIMD4<UInt32>>.stride)
        let vertexBuffer = try buffer("vertices", count: vertexCount, stride: MemoryLayout<SIMD2<Float>>.stride)
        let triangleBuffer = try buffer("triangles", count: triangleCount, stride: MemoryLayout<SIMD4<UInt32>>.stride)
        copyPublishedGeometry = !geometryChanged
        if geometryChanged {
            for (i, v) in vertices.enumerated() { vertexBuffer.contents().advanced(by: i * 8).storeBytes(of: v, as: SIMD2<Float>.self) }
            for (i, t) in triangles.enumerated() { triangleBuffer.contents().advanced(by: i * 16).storeBytes(of: t, as: SIMD4<UInt32>.self) }
        }
        for i in changes { updates.contents().advanced(by: i * MemoryLayout<NativeRigidBody>.stride).storeBytes(of: records[i], as: NativeRigidBody.self) }
        bodyUploadCount = changes.count; geometryUploadCount = geometryChanged ? inputs.count : 0
    }

    func encodeInputs(_ encoder: MTLBlitCommandEncoder) {
        let stride = MemoryLayout<NativeRigidBody>.stride
        if copyPublishedGeometry {
            if vertexCount > 0 {
                encoder.copy(from: buffers["publishedVertices"]!, sourceOffset: 0, to: vertices,
                             destinationOffset: 0, size: vertexCount * MemoryLayout<SIMD2<Float>>.stride)
            }
            if triangleCount > 0 {
                encoder.copy(from: buffers["publishedTriangles"]!, sourceOffset: 0, to: triangles,
                             destinationOffset: 0, size: triangleCount * MemoryLayout<SIMD4<UInt32>>.stride)
            }
        }
        for (source, target) in remaps { encoder.copy(from: buffers["published"]!, sourceOffset: source * stride, to: bodies, destinationOffset: target * stride, size: stride) }
        for i in changes { encoder.copy(from: buffers["updates"]!, sourceOffset: i * stride, to: bodies, destinationOffset: i * stride, size: stride) }
    }

    func completed() throws -> (objects: [ObjectID: NativePublicObject], removed: Set<ObjectID>) {
        let values = bodies.contents().bindMemory(to: NativeRigidBody.self, capacity: count)
        var result: [ObjectID: NativePublicObject] = [:], removed: Set<ObjectID> = []
        for i in current.indices {
            let body = values[i]
            guard body.identity.x == current[i].object.descriptor.id.rawValue,
                  (0..<4).allSatisfy({ body.pose[$0].isFinite && body.motion[$0].isFinite }) else { throw NativeMetalSolverError.invalidSnapshot }
            var object = current[i].object
            let center = SIMD2(body.previous.z, body.previous.w)
            func offset(_ a: Float) -> SIMD2<Float> { SIMD2(center.x * cos(a) - center.y * sin(a), center.x * sin(a) + center.y * cos(a)) }
            object.position = SIMD2(body.pose.x, body.pose.y) - offset(body.pose.z)
            object.previousPosition = SIMD2(body.previous.x, body.previous.y) - offset(body.pose.w)
            object.rotation = body.pose.z; object.velocity = SIMD2(body.motion.x, body.motion.y); object.angularVelocity = body.motion.z
            result[object.descriptor.id] = object
            if body.flags.z == 1 { removed.insert(object.descriptor.id) }
        }
        return (result, removed)
    }

    func publish(_ objects: [ObjectID: NativePublicObject]) {
        publishedInputs = current.map { var input = $0; input.object = objects[input.object.descriptor.id]!; return input }
        publishedGeometry = current.compactMap { if case .polygon(let p) = $0.object.descriptor { return (p.id, p.geometry) }; return nil }
        let old = buffers["published"]!; buffers["published"] = bodies; buffers["working"] = old
        let oldVertices = buffers["publishedVertices"]!; buffers["publishedVertices"] = vertices; buffers["vertices"] = oldVertices
        let oldTriangles = buffers["publishedTriangles"]!; buffers["publishedTriangles"] = triangles; buffers["triangles"] = oldTriangles
        geometryCache = geometryCache.filter { objects[$0.key] != nil }
    }
}
