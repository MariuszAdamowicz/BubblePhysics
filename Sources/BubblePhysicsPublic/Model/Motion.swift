import Foundation

/// Identyfikator sesji sterowania, unikalny w obrębie świata; nigdy indeks solvera.
public struct PlayerDriveID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Polityka chwytu bańki gumką siłową. Bańka z `drivePolicy` = `nil` nie daje się chwycić.
public struct BubbleDrivePolicy: Equatable, Sendable {
    /// Sztywność gumki K_band (siła na jednostkę naciągnięcia).
    public let bandStiffness: Float
    /// Górna granica modułu siły gumki. `nil` oznacza brak limitu.
    public let maximumForce: Float?
    public init(bandStiffness: Float, maximumForce: Float? = nil) throws {
        // Pola zgłaszają `valueOutOfRange` także dla ∞ i NaN, inaczej niż `requirePositive`.
        guard bandStiffness.isFinite, bandStiffness > 0 else { throw ModelValidationError.valueOutOfRange("drive.bandStiffness") }
        if let maximumForce {
            guard maximumForce.isFinite, maximumForce > 0 else { throw ModelValidationError.valueOutOfRange("drive.maximumForce") }
        }
        self.bandStiffness = bandStiffness; self.maximumForce = maximumForce
    }
}

/// Ścieżka w przestrzeni świata. Przy blokadzie zatrzymuje się do nowej komendy.
public struct PathDrive: Equatable, Sendable {
    public let points: [WorldPoint]
    public let speed: Float
    public init(points: [WorldPoint], speed: Float) throws {
        guard !points.isEmpty else { throw ModelValidationError.valueOutOfRange("path.points") }
        for point in points { try requireFinite(point, "path.point") }
        try requirePositive(speed, "path.speed")
        self.points = points; self.speed = speed
    }
}

/// Stały napęd w jednostkach siły i momentu siły. Kontakty zachowują pełną władzę nad ruchem.
public struct MotorDrive: Equatable, Sendable {
    public let force: WorldPoint
    public let torque: Float
    public init(force: WorldPoint = .zero, torque: Float = 0) throws {
        try requireFinite(force, "motor.force"); try requireFinite(torque, "motor.torque")
        self.force = force; self.torque = torque
    }
}

public struct DriveBlockingContact: Equatable, Sendable {
    public let objectID: ObjectID
    public let point: WorldPoint
    public let normal: WorldPoint
    package init(objectID: ObjectID, point: WorldPoint, normal: WorldPoint) {
        self.objectID = objectID; self.point = point; self.normal = normal
    }
}

/// Ciągły wynik aktywnego sterowania, niezależny od EventInterest.
public struct DriveFeedback: Equatable, Sendable {
    public let objectID: ObjectID
    /// nil dla ścieżki; identyfikator pozostaje stały przez begin/update/end gracza.
    public let playerDriveID: PlayerDriveID?
    public let target: WorldPoint
    public let achievedPoint: WorldPoint
    public var deviation: WorldPoint { target - achievedPoint }
    public let blockingContact: DriveBlockingContact?
    public let isStopped: Bool
    package init(objectID: ObjectID, playerDriveID: PlayerDriveID?, target: WorldPoint,
                 achievedPoint: WorldPoint, blockingContact: DriveBlockingContact?, isStopped: Bool) {
        self.objectID = objectID; self.playerDriveID = playerDriveID; self.target = target
        self.achievedPoint = achievedPoint; self.blockingContact = blockingContact; self.isStopped = isStopped
    }
}

/// Sterowanie bryły kinematycznej; gra podaje nowy cel transakcją przed krokiem.
public enum KinematicDrive: Equatable, Sendable {
    case velocity(linear: WorldPoint, angular: Float)
    case path(PathDrive)
    /// Pozycja i obrót osiągane w jednym kroku.
    case target(position: WorldPoint, rotation: Float)
}
