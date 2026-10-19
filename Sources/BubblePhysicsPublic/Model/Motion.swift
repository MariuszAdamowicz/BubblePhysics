import Foundation

/// Identyfikator sesji sterowania, unikalny w obrębie świata; nigdy indeks solvera.
public struct PlayerDriveID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Polityka zmiany kształtu i odpowiedzi prowadzenia bańki. Czasy mierzone w symulacji.
public struct BubbleDrivePolicy: Equatable, Sendable {
    public let rigidifies: Bool
    public let rigidificationDuration: Double
    public let relaxationDuration: Double
    /// Górna granica prędkości prowadzenia w jednostkach świata na sekundę.
    public let maximumSpeed: Float
    /// Prędkość na jednostkę odległości od celu. `nil` zachowuje historyczny stały napęd.
    public let distanceResponse: Float?
    public static let standard = try! BubbleDrivePolicy()
    public init(rigidifies: Bool = true, rigidificationDuration: Double = 0.15,
                relaxationDuration: Double = 0.25, maximumSpeed: Float = 12,
                distanceResponse: Float? = nil) throws {
        for duration in [rigidificationDuration, relaxationDuration] {
            guard duration.isFinite, duration >= 0 else { throw ModelValidationError.valueOutOfRange("drive.duration") }
        }
        try requirePositive(maximumSpeed, "drive.maximumSpeed")
        if let distanceResponse { try requirePositive(distanceResponse, "drive.distanceResponse") }
        self.rigidifies = rigidifies; self.rigidificationDuration = rigidificationDuration
        self.relaxationDuration = relaxationDuration
        self.maximumSpeed = maximumSpeed; self.distanceResponse = distanceResponse
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
