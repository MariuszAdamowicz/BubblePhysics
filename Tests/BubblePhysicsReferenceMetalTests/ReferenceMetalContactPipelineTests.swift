import XCTest
import Metal
@testable import BubblePhysicsReference
@testable import BubblePhysicsReferenceMetal

final class ReferenceMetalContactPipelineTests: XCTestCase {
    func testSortedContactsMatchCPUForBubblesWallsAndMovingPolygon() async throws {
        var world = makeWorld()
        world.addBubble(try bubble(-17, 0, 0.5))
        world.addBubble(try bubble(8_000_000_000, 1.5, 0.5))
        world.addBubble(try bubble(9, 10, 10))
        world.addSegment(.staticSegment(id: .init(rawValue: -4), a: .init(x: -4, y: 0), b: .init(x: 4, y: 0), collisionMode: .oneSided(allowedSide: 1)))
        world.addSegment(.kinematicSegment(id: .init(rawValue: 8_000_000_001), previousA: .init(x: 10, y: 9), previousB: .init(x: 12, y: 9), currentA: .init(x: 9, y: 9.5), currentB: .init(x: 11, y: 9.5), ownerID: 5))
        world.addSegment(.kinematicSegment(id: .init(rawValue: 8_000_000_002), previousA: .init(x: 12, y: 9), previousB: .init(x: 11, y: 12), currentA: .init(x: 11, y: 9.5), currentB: .init(x: 10, y: 12.5), ownerID: 5))
        world.addSegment(.kinematicSegment(id: .init(rawValue: 8_000_000_003), previousA: .init(x: 11, y: 12), previousB: .init(x: 10, y: 9), currentA: .init(x: 10, y: 12.5), currentB: .init(x: 9, y: 9.5), ownerID: 5))
        let result = try await solver().prepareFrameForTesting(snapshot: .init(world: world), step: 0)
        let expected = oracleContacts(world)
        XCTAssertEqual(result.contacts.map(\.id), expected.map(\.id))
        XCTAssertEqual(result.contacts.map(\.bubbleA), expected.map(\.bubbleA))
        XCTAssertEqual(result.contacts.map(\.bubbleB), expected.map(\.bubbleB))
        for (actual, cpu) in zip(result.contacts, expected) {
            XCTAssertEqual(actual.normal.x, cpu.normal.x, accuracy: 1e-5)
            XCTAssertEqual(actual.normal.y, cpu.normal.y, accuracy: 1e-5)
            XCTAssertEqual(actual.pointQ.x, cpu.pointQ.x, accuracy: 1e-5)
            XCTAssertEqual(actual.pointQ.y, cpu.pointQ.y, accuracy: 1e-5)
            XCTAssertEqual(actual.penetration, cpu.penetration, accuracy: 1e-5)
            XCTAssertEqual(actual.allowedSide, cpu.allowedSide)
        }
    }

    func testSegmentContactFormsSingletonAndSharedSegmentDoesNotJoinBubbles() async throws {
        var world = makeWorld()
        world.addBubble(try bubble(7, -3, 0.5))
        world.addBubble(try bubble(8, 3, 0.5))
        world.addBubble(try bubble(9, 100, 100))
        world.addSegment(.staticSegment(id: .init(rawValue: 4), a: .init(x: -5, y: 0), b: .init(x: 5, y: 0)))
        let result = try await solver().prepareFrameForTesting(snapshot: .init(world: world), step: 0)
        XCTAssertEqual(result.components.map(\.bubbleIDs), [[.init(rawValue: 7)], [.init(rawValue: 8)]])
        XCTAssertEqual(result.components.map { $0.contactIDs.count }, [1, 1])
        XCTAssertEqual(result.componentLabels, [0, 1, nil])
    }

    func testCCDProtectsAllowedSegmentSideAndReportsCPUImpact() async throws {
        var world = makeWorld()
        world.addBubble(try bubble(1, 0, 3, velocity: .init(x: 0, y: -8)))
        world.addSegment(.staticSegment(id: .init(rawValue: 4), a: .init(x: -5, y: 0), b: .init(x: 5, y: 0), collisionMode: .oneSided(allowedSide: 1)))
        let result = try await solver().prepareFrameForTesting(snapshot: .init(world: world), step: 0)
        XCTAssertEqual(result.predictedCenters[0].y, -5, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(result.centers[0].y, 0)
        XCTAssertEqual(result.sideCorrectionCount, 1)
        XCTAssertEqual(result.eventGroups.count, 1)
        XCTAssertEqual(result.eventGroups[0].time, 0.25, accuracy: 1e-6)
        XCTAssertEqual(result.eventGroups[0].events[0].contactID.rawValue, (1 << 63) | (1 << 32) | 4)
    }

    func testContactKeyCollisionsUseCPUOverwriteOrderAndFullEndpointIDs() async throws {
        var world = makeWorld()
        world.addBubble(try bubble(-1, 0, 0))
        world.addBubble(try bubble(4_294_967_295, 0.5, 0))
        world.addBubble(try bubble(8_589_934_591, 1, 0))
        let result = try await solver().prepareFrameForTesting(snapshot: .init(world: world), step: 0)
        XCTAssertEqual(result.contacts.count, 1)
        XCTAssertEqual(result.contacts[0].id.rawValue, UInt64.max)
        XCTAssertEqual(result.contacts[0].bubbleA.rawValue, 4_294_967_295)
        XCTAssertEqual(result.contacts[0].bubbleB?.rawValue, 8_589_934_591)
        XCTAssertEqual(result.contacts.map(\.id), oracleContacts(world).map(\.id))
    }

    func testOverflowRetriesSameFrameWithoutLosingPairsContactsOrComponents() async throws {
        var world = makeWorld()
        for i in 0..<18 { world.addBubble(try bubble(i, Float(i) * 0.01, 0)) }
        let result = try await solver().prepareFrameForTesting(snapshot: .init(world: world), step: 3)
        XCTAssertTrue(result.didOverflow)
        XCTAssertGreaterThan(result.attemptCount, 1)
        XCTAssertEqual(result.candidatePairs.count, 153)
        XCTAssertEqual(result.contacts.count, 153)
        XCTAssertEqual(result.components.count, 1)
        XCTAssertEqual(result.components[0].bubbleIDs.count, 18)
        XCTAssertEqual(result.components[0].contactIDs.count, 153)
        XCTAssertEqual(result.contacts.map(\.id), oracleContacts(world).map(\.id))
    }

    func testGrowingGeometryBuffersAreReusedAcrossFramesAndActiveCountsShrink() async throws {
        let gpu = try solver()
        var world = makeWorld()
        for i in 0..<18 { world.addBubble(try bubble(i, Float(i) * 0.01, 0)) }
        let first = try await gpu.prepareFrameForTesting(snapshot: .init(world: world), step: 1)
        XCTAssertTrue(first.didOverflow)
        let second = try await gpu.prepareFrameForTesting(snapshot: .init(world: world), step: 2)
        XCTAssertFalse(second.didOverflow)
        XCTAssertEqual(second.attemptCount, 1)
        XCTAssertEqual(second.contacts, first.contacts)
        var small = makeWorld(); small.addBubble(try bubble(200, 20, 30))
        let third = try await gpu.prepareFrameForTesting(snapshot: .init(world: small), step: 3)
        XCTAssertEqual(third.predictedCenters, [.init(x: 20, y: 30)])
        XCTAssertTrue(third.contacts.isEmpty); XCTAssertTrue(third.allEvents.isEmpty)
        XCTAssertTrue(third.candidatePairs.isEmpty); XCTAssertTrue(third.components.isEmpty)
        XCTAssertEqual(third.componentLabels, [nil])
    }

    func testBubbleAndSegmentKeyCollisionMatchesCPULastWriter() async throws {
        var world = makeWorld()
        world.addBubble(try bubble(-1, 0, 0))
        world.addBubble(try bubble(4_294_967_295, 0.5, 0))
        world.addSegment(.staticSegment(id: .init(rawValue: -1), a: .zero, b: .zero))
        let result = try await solver().prepareFrameForTesting(snapshot: .init(world: world), step: 0)
        XCTAssertEqual(result.contacts.count, 1)
        XCTAssertEqual(result.contacts[0].id.rawValue, UInt64.max)
        XCTAssertEqual(result.contacts[0].kind, .bubbleSegment)
        XCTAssertEqual(result.contacts[0].bubbleA.rawValue, 4_294_967_295)
        XCTAssertEqual(result.contacts[0].segment?.rawValue, -1)
        XCTAssertEqual(result.contacts, oracleContacts(world))
        XCTAssertEqual(result.components.map { $0.bubbleIDs.map(\.rawValue) }, [[4_294_967_295]])
    }

    private func solver() throws -> ReferenceMetalSolver {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return try XCTUnwrap(ReferenceMetalSolver(device: device))
    }

    func testEquilibriumRefreshPreservesAgeAndAllowedSideButResetsCompression() async throws {
        var world = makeWorld()
        world.addBubble(try bubble(1, 0, 0))
        world.addBubble(try bubble(2, 2.001, 0))
        var old = ReferenceDiscreteContactGenerator.bubbleBubbleCandidate(world.bubbles[0], world.bubbles[1])
        old.age = 5; old.allowedSide = -1; old.accumulatedCompression = 123
        old.compressionA = 4; old.compressionB = 7; old.pressure = 19; old.effectiveStiffness = 6
        old.contourHalfLength = 2
        let gpu = try solver()
        let result = try await gpu.prepareFrameForTesting(snapshot: .init(world: world, contacts: [old]), step: 1)
        XCTAssertEqual(result.contacts.count, 1)
        let kept = try XCTUnwrap(result.contacts.first)
        XCTAssertEqual(kept.age, 6)
        XCTAssertEqual(kept.allowedSide, -1)
        XCTAssertEqual(kept.accumulatedCompression, 0)
        XCTAssertEqual(kept.compressionA, 0)
        XCTAssertEqual(kept.compressionB, 0)
        XCTAssertEqual(kept.pressure, 0)
        XCTAssertEqual(kept.effectiveStiffness, 0)
        XCTAssertNil(kept.contourHalfLength)
        var separating = world.bubbles[1]; separating.velocity = .init(x: 0.0001, y: 0)
        world.updateBubble(separating)
        let removed = try await gpu.prepareFrameForTesting(snapshot: .init(world: world, contacts: [old]), step: 2)
        XCTAssertTrue(removed.contacts.isEmpty)
        XCTAssertTrue(removed.components.isEmpty)
        separating.center = .init(x: 1.5, y: 0); separating.velocity = .zero; world.updateBubble(separating)
        let overwritten = try await gpu.prepareFrameForTesting(snapshot: .init(world: world, contacts: [old]), step: 3)
        XCTAssertEqual(overwritten.contacts.first?.age, 0)
        XCTAssertNil(overwritten.contacts.first?.allowedSide)
    }

    func testOldSegmentUsesRelativeVelocityAndActiveIDsAreSkippedByCCD() async throws {
        var world = makeWorld()
        world.addBubble(try bubble(7, 0, 1.001))
        var segment = ReferenceSegment.staticSegment(id: .init(rawValue: 4), a: .init(x: -5, y: 0), b: .init(x: 5, y: 0))
        segment.linearVelocity = .init(x: 0, y: 1)
        world.addSegment(segment)
        var old = ReferenceDiscreteContactGenerator.bubbleSegmentCandidate(world.bubbles[0], segment)
        old.age = 3
        let result = try await solver().prepareFrameForTesting(snapshot: .init(world: world, contacts: [old]), step: 0)
        XCTAssertEqual(result.contacts.first?.age, 4)
        XCTAssertTrue(result.allEvents.isEmpty)
        var missing = old; missing.segment = .init(rawValue: 999)
        let removed = try await solver().prepareFrameForTesting(snapshot: .init(world: world, contacts: [missing]), step: 0)
        XCTAssertTrue(removed.contacts.isEmpty)
    }

    func testTranslatedAndRotatingSegmentTOIMatchesCPUIncludingBudgetExhaustion() async throws {
        let gpu = try solver()
        for budget in [1, 8, 32] {
            for rotating in [false, true] {
                var world = ReferenceWorld(configuration: .init(timeStep: 1, linearDamping: 0, toiIterationBudget: budget), broadPhase: BruteForceBroadPhase())
                world.addBubble(try bubble(7, 0, 3, velocity: .init(x: 0.2, y: -5)))
                let segment = ReferenceSegment.kinematicSegment(id: .init(rawValue: 8), previousA: .init(x: -4, y: 0), previousB: .init(x: 4, y: 0), currentA: .init(x: -4, y: 0.5), currentB: .init(x: 4, y: rotating ? -0.5 : 0.5), timeStep: 1, ownerID: 5)
                world.addSegment(segment)
                var path = world.bubbles[0]; path.center = path.center + path.velocity
                let cpu = ReferenceCCD.bubbleSegment(path, segment, configuration: world.configuration)
                let result = try await gpu.prepareFrameForTesting(snapshot: .init(world: world), step: 0)
                XCTAssertEqual(result.ccdBudgetExhaustionCount, cpu.didExhaustBudget ? 1 : 0)
                switch cpu.timeOfImpact {
                case .none: XCTAssertTrue(result.allEvents.isEmpty)
                case .initialOverlap: XCTAssertEqual(result.allEvents.first?.time, 0)
                case let .impact(fraction, normal, point):
                    let event = try XCTUnwrap(result.allEvents.first)
                    let impact = try XCTUnwrap(result.impactContacts.first)
                    XCTAssertEqual(event.time, fraction, accuracy: 1e-5)
                    XCTAssertEqual(impact.normal.x, normal.x, accuracy: 1e-5)
                    XCTAssertEqual(impact.normal.y, normal.y, accuracy: 1e-5)
                    XCTAssertEqual(impact.pointQ.x, point.x, accuracy: 1e-5)
                    XCTAssertEqual(impact.pointQ.y, point.y, accuracy: 1e-5)
                }
                let finalEdge = segment.currentB - segment.currentA
                // Guard correction also changes x for a sloping final edge.
                XCTAssertGreaterThanOrEqual(finalEdge.cross(result.centers[0] - segment.currentA), 0)
            }
        }
    }

    func testBubbleCCDAndEventGroupsMatchCPUAndLimitIsExplicitWithoutEventLoss() async throws {
        var world = ReferenceWorld(configuration: .init(timeStep: 1, linearDamping: 0, simultaneousEventTolerance: 0.001, maximumEventGroups: 1), broadPhase: BruteForceBroadPhase())
        world.addBubble(try bubble(1, 0, 0, velocity: .init(x: 10, y: 0)))
        world.addBubble(try bubble(2, 5, 0))
        world.addBubble(try bubble(3, 8, 0))
        world.addBubble(try bubble(4, 0, 10, velocity: .init(x: 10, y: 0)))
        world.addBubble(try bubble(5, 5.005, 10))
        let result = try await solver().prepareFrameForTesting(snapshot: .init(world: world), step: 0)
        let expected = [ReferenceContactEvent(time: 0.3, contactID: .init(rawValue: (1 << 32) | 2)),
                        .init(time: 0.6, contactID: .init(rawValue: (1 << 32) | 3)),
                        .init(time: 0.3005, contactID: .init(rawValue: (4 << 32) | 5))]
        let cpu = ReferenceContactEventQueue.groups(events: expected, frameDuration: 1, simultaneousTolerance: 0.001, limit: 1)
        XCTAssertEqual(result.eventGroups.count, cpu.groups.count)
        XCTAssertEqual(result.eventGroups[0].events.map(\.contactID), cpu.groups[0].events.map(\.contactID))
        XCTAssertEqual(result.eventGroups[0].time, 0.3, accuracy: 1e-6)
        XCTAssertTrue(result.didReachEventGroupLimit)
        XCTAssertEqual(result.allEvents.count, 3)
        XCTAssertEqual(result.impactContacts.count, 3)
        XCTAssertEqual(result.contacts.count, 0) // Refresh never silently activates CCD events.
    }

    func testContactRelationshipJoinsChainButNotSeparateIsland() async throws {
        var world = makeWorld()
        for (id, x) in [(1, Float(0)), (2, 1.5), (3, 3), (4, 100)] { world.addBubble(try bubble(id, x, 0.5)) }
        world.addSegment(.staticSegment(id: .init(rawValue: 5), a: .init(x: 99, y: 0), b: .init(x: 101, y: 0)))
        let result = try await solver().prepareFrameForTesting(snapshot: .init(world: world), step: 0)
        XCTAssertEqual(result.components.map { $0.bubbleIDs.map(\.rawValue) }, [[1, 2, 3], [4]])
        XCTAssertEqual(result.components.map { $0.contactIDs.count }, [2, 1])
        XCTAssertEqual(result.componentLabels, [0, 0, 0, 1])
        let summary = ReferenceResidualComponents.summary(residual: Array(repeating: .zero, count: 4), contacts: result.contacts,
            indices: Dictionary(uniqueKeysWithValues: world.bubbles.enumerated().map { ($0.element.id, $0.offset) }), tolerance: 1)
        XCTAssertEqual(result.components.count, summary.componentCount)
    }

    func testDegenerateSegmentCoincidentBubblesAndEmptyFrameStayFinite() async throws {
        let gpu = try solver()
        var world = makeWorld()
        world.addBubble(try bubble(0, 0, 0)); world.addBubble(try bubble(1, 0, 0))
        world.addSegment(.staticSegment(id: .init(rawValue: 0), a: .zero, b: .zero))
        let result = try await gpu.prepareFrameForTesting(snapshot: .init(world: world), step: 0)
        XCTAssertEqual(result.contacts.map(\.id), oracleContacts(world).map(\.id))
        XCTAssertTrue(result.contacts.allSatisfy { $0.normal.isFinite && $0.pointQ.isFinite })
        XCTAssertEqual(result.contacts.first?.normal, .init(x: 1, y: 0))
        let empty = try await gpu.prepareFrameForTesting(snapshot: .init(world: makeWorld()), step: 1)
        XCTAssertTrue(empty.contacts.isEmpty); XCTAssertTrue(empty.components.isEmpty)
        XCTAssertTrue(empty.centers.isEmpty); XCTAssertTrue(empty.allEvents.isEmpty)
        XCTAssertFalse(empty.didOverflow)
    }

    func testGeometryABIAndAllPipelinesAreLoaded() throws {
        XCTAssertEqual(MemoryLayout<ReferenceMetalGeometryParameters>.stride, 80)
        XCTAssertEqual(MemoryLayout<ReferenceMetalGeometryControl>.stride, 64)
        XCTAssertEqual(MemoryLayout<ReferenceMetalGeometryEvent>.stride, 144)
        XCTAssertEqual(MemoryLayout<ReferenceMetalGeometryEvent>.offset(of: \.timing), 112)
        XCTAssertEqual(MemoryLayout<ReferenceMetalGeometryEvent>.offset(of: \.grouping), 128)
        for name in ["referencePredict", "referenceEmitCandidatePairs", "referenceRefreshContacts", "referenceFindTOI", "referenceLabelComponents"] {
            XCTAssertTrue(try solver().loadedFunctionNames.contains(name))
        }
    }

    func testTinyDistanceUsesCPUSquaredLengthFallbackThreshold() async throws {
        var world = makeWorld()
        world.addBubble(try bubble(0, 0, 0))
        world.addBubble(try bubble(1, 0, 0.0001))
        world.addSegment(.staticSegment(id: .init(rawValue: 2), a: .init(x: 0.0001, y: 0), b: .init(x: 0.0001, y: 0)))
        let result = try await solver().prepareFrameForTesting(snapshot: .init(world: world), step: 0)
        let expected = oracleContacts(world)
        XCTAssertEqual(result.contacts.map(\.normal), expected.map(\.normal))
        XCTAssertEqual(result.contacts.map(\.pointQ), expected.map(\.pointQ))
    }

    func testNonFinitePredictionThrowsAndDoesNotContaminateNextPreparation() async throws {
        let gpu = try solver()
        var world = makeWorld()
        var bad = try bubble(1, 0, 0); bad.velocity.x = .infinity; world.addBubble(bad)
        do { _ = try await gpu.prepareFrameForTesting(snapshot: .init(world: world), step: 0); XCTFail("non-finite frame was published") }
        catch ReferenceMetalGeometryError.nonFiniteState { }
        world.updateBubble(try bubble(1, 0, 3))
        let good = try await gpu.prepareFrameForTesting(snapshot: .init(world: world), step: 1)
        XCTAssertEqual(good.centers, [.init(x: 0, y: 3)])
        XCTAssertTrue(good.contacts.isEmpty)
    }

    func testNonFiniteSegmentGeometryCannotDisappearAsAnEmptyContactSet() async throws {
        let gpu = try solver()
        var world = makeWorld(); world.addBubble(try bubble(1, 0, 3))
        var segment = ReferenceSegment.staticSegment(id: .init(rawValue: 4), a: .init(x: -5, y: 0), b: .init(x: 5, y: 0))
        segment.currentA.x = .nan; world.addSegment(segment)
        do { _ = try await gpu.prepareFrameForTesting(snapshot: .init(world: world), step: 0); XCTFail("invalid geometry disappeared from the frame") }
        catch ReferenceMetalGeometryError.nonFiniteState { }
    }

    func testFiniteInputsWithOverflowingImpactGeometryAreRejected() async throws {
        var world = makeWorld()
        world.addBubble(try .init(id: .init(rawValue: 1), center: .init(x: -2e38, y: 0), mass: 1, targetRadius: 2e38))
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 2e38, y: 0), mass: 1, targetRadius: 2e38))
        do { _ = try await solver().prepareFrameForTesting(snapshot: .init(world: world), step: 0); XCTFail("non-finite impact geometry was published") }
        catch ReferenceMetalGeometryError.nonFiniteState { }
    }

    private func makeWorld() -> ReferenceWorld {
        ReferenceWorld(configuration: .init(timeStep: 1, linearDamping: 0), broadPhase: BruteForceBroadPhase())
    }

    private func bubble(_ id: Int, _ x: Float, _ y: Float, velocity: ReferenceVector2 = .zero) throws -> ReferenceBubble {
        try .init(id: .init(rawValue: id), center: .init(x: x, y: y), velocity: velocity, mass: 1, targetRadius: 1)
    }

    // Independent CPU geometry oracle, preserving CPU dictionary overwrite order.
    private func oracleContacts(_ world: ReferenceWorld) -> [ReferenceContact] {
        var predicted = world.bubbles
        for i in predicted.indices { predicted[i].center = predicted[i].center + predicted[i].velocity * world.configuration.timeStep }
        var contacts: [ReferenceContactID: ReferenceContact] = [:]
        for a in predicted.indices {
            for b in predicted.indices where b > a {
                let contact = ReferenceDiscreteContactGenerator.bubbleBubbleCandidate(predicted[a], predicted[b])
                if contact.penetration > world.configuration.contactTolerance { contacts[contact.id] = contact }
            }
        }
        for segment in world.segments {
            for bubble in predicted {
                let contact = ReferenceDiscreteContactGenerator.bubbleSegmentCandidate(bubble, segment)
                if contact.penetration > world.configuration.contactTolerance { contacts[contact.id] = contact }
            }
        }
        return contacts.values.sorted { $0.id < $1.id }
    }
}
