import BubblePhysicsModel

// Lustra Swift rekordów sił silnika 4.0.0 (CD-D-5): host nie liczy już gumki, pól, motoru ani siły globalnej, tylko opisuje je GPU.
// ABI Swift/MSL: wyłącznie lane'y SIMD o wyrównaniu 16 bajtów; układ pilnuje `NativeMetalShaderABITests`, a odpowiedniki
// shaderowe leżą na początku `NativeForceKernels.metal-source`. Identyfikator obiektu to surowa wartość `ObjectID` w `identity.x`.

/// Gumka bańki w roli `.playerDriven`: cel stoi w kroku, więc siła K_band · (cel − x) liczy się w każdym podkroku z bieżącego x.
struct NativeMetalBandDrive: Equatable, Sendable {
    var identity: SIMD2<UInt64> // ID bańki, reserved
    var band: SIMD4<Float> // cel.xy, K_band, maximumForce (0 = bez limitu; polityka wymaga limitu > 0)
}

/// Pole sił z geometrią zasięgu i filtrem obiektów. Wierzchołki wielokąta i identyfikatory filtra leżą w osobnych tablicach
/// `NativeForceInput`, a rekord wskazuje ich zakresy.
struct NativeMetalForceField: Equatable, Sendable {
    static let directionalKind: UInt32 = 0
    static let radialKind: UInt32 = 1
    static let vortexKind: UInt32 = 2

    var identity: SIMD2<UInt64> // ID pola, reserved
    var pose: SIMD4<Float> // położenie.xy, obrót, falloff
    var strength: SIMD4<Float> // siła kierunkowa.xy, siła radialna albo wirowa, promień zasięgu (koło: promień, wielokąt: najdalszy wierzchołek)
    var shape: SIMD4<UInt32> // rodzaj, początek wierzchołków, liczba wierzchołków (0 = koło), reserved
    var filter: SIMD4<UInt32> // początek identyfikatorów, liczba identyfikatorów, filtr obecny (1; pusty filtr nie działa na nikogo), reserved
}

/// Motor bańki w roli `.motorDriven`: stała siła i moment; bezwładność ½ m r² host liczy z bieżącego promienia kolizji.
struct NativeMetalMotor: Equatable, Sendable {
    var identity: SIMD2<UInt64> // ID bańki, reserved
    var drive: SIMD4<Float> // siła.xy, moment, bezwładność
}

/// Poza bryły kinematycznej na początku kroku i jej prędkość; w podkroku w chwili t bryła jest w start + prędkość · t.
struct NativeMetalKinematicPose: Equatable, Sendable {
    var identity: SIMD2<UInt64> // ID bryły, reserved
    var pose: SIMD4<Float> // położenie.xy, obrót, reserved
    var velocity: SIMD4<Float> // prędkość liniowa.xy, prędkość kątowa, reserved
}

/// Sterowanie pętlą podkroków na GPU: czasy, liczniki i obiekt wyznaczający h w ostatnim podkroku.
struct NativeMetalSubstepControl: Equatable, Sendable {
    var time = SIMD4<Float>.zero // czas kroku, czas upłynięty, h, horyzont zapasu
    var counts = SIMD4<UInt32>.zero // podkroki pary buforów, podkroki klatki, znacznik przebudowy, znacznik limitu
    var limiter = SIMD2<UInt64>.zero // obiekt wyznaczający h, człon h
}

/// Dane wejściowe sił jednego kroku, zbudowane z obiektów świata po `MotionControllers.prepare`. Rekordy idą po ID, więc
/// kolejność nie zależy od kolejności obiektów na wejściu. Siły dla brył dynamicznych liczy dalej host (bryły są poza podkrokami).
struct NativeForceInput: Equatable, Sendable {
    var globalForce: WorldPoint = .zero
    var bandDrives: [NativeMetalBandDrive] = []
    var fields: [NativeMetalForceField] = []
    var fieldVertices: [SIMD2<Float>] = []
    var fieldObjectIDs: [UInt64] = []
    var motors: [NativeMetalMotor] = []
    var kinematicPoses: [NativeMetalKinematicPose] = []

    init() {}

    init(objects: [NativePublicObject], globalForce: WorldPoint) {
        self.globalForce = globalForce
        for object in objects.sorted(by: { $0.descriptor.id.rawValue < $1.descriptor.id.rawValue }) {
            let id = object.descriptor.id.rawValue
            switch object.descriptor {
            case .bubble(let bubble):
                switch object.motionRole {
                case .playerDriven:
                    guard let target = object.playerDriveTarget, let policy = bubble.drivePolicy else { break }
                    bandDrives.append(NativeMetalBandDrive(identity: SIMD2(id, 0),
                        band: SIMD4(target.x, target.y, policy.bandStiffness, policy.maximumForce ?? 0)))
                case .motorDriven:
                    guard let motor = object.motorDrive else { break }
                    let inertia = 0.5 * bubble.mass * object.collisionRadius * object.collisionRadius
                    motors.append(NativeMetalMotor(identity: SIMD2(id, 0),
                                                   drive: SIMD4(motor.force.x, motor.force.y, motor.torque, inertia)))
                case .static, .dynamic, .kinematic, .pathDriven: break
                }
            case .rigidBody:
                guard object.motionRole == .kinematic else { break }
                kinematicPoses.append(NativeMetalKinematicPose(identity: SIMD2(id, 0),
                    pose: SIMD4(object.position.x, object.position.y, object.rotation, 0),
                    velocity: SIMD4(object.velocity.x, object.velocity.y, object.angularVelocity, 0)))
            case .forceField(let field):
                appendField(field, id: id)
            case .sensor: break
            }
        }
    }

    private mutating func appendField(_ field: ForceFieldDescriptor, id: UInt64) {
        var strength = SIMD4<Float>.zero
        var kind = NativeMetalForceField.directionalKind
        var falloff: Float = 0
        switch field.field {
        case .directional(let force): strength.x = force.x; strength.y = force.y
        case .radial(let value, let exponent): kind = NativeMetalForceField.radialKind; strength.z = value; falloff = exponent
        case .vortex(let value, let exponent): kind = NativeMetalForceField.vortexKind; strength.z = value; falloff = exponent
        }
        var vertexStart: UInt32 = 0, vertexCount: UInt32 = 0
        switch field.geometry.shape {
        case .circle(let radius): strength.w = radius
        case .polygon(let geometry):
            vertexStart = UInt32(fieldVertices.count); vertexCount = UInt32(geometry.vertices.count)
            fieldVertices.append(contentsOf: geometry.vertices)
            // Ten sam promień zaniku co dotychczas na hoście: najdalszy wierzchołek od środka pola.
            strength.w = geometry.vertices.map { ($0.x * $0.x + $0.y * $0.y).squareRoot() }.max() ?? 1
        }
        var idStart: UInt32 = 0, idCount: UInt32 = 0, hasFilter: UInt32 = 0
        if let ids = field.filter.objectIDs {
            idStart = UInt32(fieldObjectIDs.count); idCount = UInt32(ids.count); hasFilter = 1
            fieldObjectIDs.append(contentsOf: ids.map(\.rawValue).sorted())
        }
        fields.append(NativeMetalForceField(identity: SIMD2(id, 0),
            pose: SIMD4(field.position.x, field.position.y, field.rotation, falloff), strength: strength,
            shape: SIMD4(kind, vertexStart, vertexCount, 0), filter: SIMD4(idStart, idCount, hasFilter, 0)))
    }
}
