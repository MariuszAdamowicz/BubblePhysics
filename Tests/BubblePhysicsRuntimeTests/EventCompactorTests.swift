import BubblePhysicsModel
@testable import BubblePhysicsRuntime
import XCTest

final class EventCompactorTests: XCTestCase {
    func testDriveBlockedIsEmittedOnEntryAndFeedbackStaysContinuous() throws {
        let config = try WorldConfiguration(simulationRegion: WorldRectangle(min: [-10, -10], max: [10, 10]))
        var state = RuntimeState(configuration: config)
        let id = ObjectID(rawValue: 1), blocker = ObjectID(rawValue: 2)
        let descriptor = try BubbleDescriptor(id: id, position: .zero, targetRadius: 1,
            physicsMaterialID: PhysicsMaterialID(rawValue: 1), renderMaterialID: RenderMaterialID(rawValue: 1),
            eventInterest: .driveBlocked)
        state.objects[id] = RuntimeObject(.bubble(descriptor))
        let feedback = DriveFeedback(objectID: id, playerDriveID: nil, target: [3, 0], achievedPoint: .zero,
            blockingContact: DriveBlockingContact(objectID: blocker, point: [1, 0], normal: [-1, 0]), isStopped: false)
        let first = EventCompactor.finish([], overflow: WorldEventOverflow(), feedback: [feedback], state: state,
            previousBlockers: [:])
        XCTAssertEqual(first.events, [.driveBlocked(id, by: blocker, point: [1, 0])])
        let second = EventCompactor.finish([], overflow: WorldEventOverflow(), feedback: [feedback], state: state,
            previousBlockers: first.blockers)
        XCTAssertTrue(second.events.isEmpty)
        XCTAssertEqual(second.blockers[id], blocker)
    }

    // MARK: - Zdarzenia kontaktu (etap 2, P-B-13..15)

    private func state(bubbles ids: [UInt64], interest: EventInterest = .contact, capacity: Int = 1024) throws -> RuntimeState {
        var state = RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-10, -10], max: [10, 10]), eventBufferCapacity: capacity))
        for id in ids {
            state.objects[ObjectID(rawValue: id)] = RuntimeObject(.bubble(try BubbleDescriptor(
                id: ObjectID(rawValue: id), position: .zero, targetRadius: 1,
                physicsMaterialID: PhysicsMaterialID(rawValue: 1), renderMaterialID: RenderMaterialID(rawValue: 1),
                eventInterest: interest)))
        }
        return state
    }

    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }
    private func pair(_ a: UInt64, _ b: UInt64) -> ContactPair { ContactPair(id(a), id(b)) }
    private func began(_ a: UInt64, _ b: UInt64) -> WorldEvent {
        .contactBegan(id(a), id(b), point: [1, 0], normal: [1, 0], impulse: 2)
    }
    private func merge(_ a: UInt64, _ b: UInt64) -> WorldEvent { .mergeContact(id(a), id(b), point: [1, 0]) }
    private func finish(_ events: [WorldEvent], state: RuntimeState, previous: Set<ContactPair> = [],
                        removed: Set<ObjectID> = [], dropped: Int = 0) -> (events: [WorldEvent], contacts: Set<ContactPair>, dropped: Int) {
        let result = EventCompactor.finish(events, overflow: WorldEventOverflow(droppedCount: dropped), feedback: [],
            state: state, previousBlockers: [:], previousContacts: previous, removedObjects: removed)
        return (result.events, result.contacts, result.overflow.droppedCount)
    }

    // GPU układa zdarzenia przez atomiki w dowolnej kolejności; kompaktor sortuje po parze, a w parze
    // contactBegan idzie przed mergeContact (P-B-13).
    func testContactBeganIsOrderedBeforeMergeContactAndEventsAreSortedByPair() throws {
        let state = try state(bubbles: [1, 2, 3, 4])
        let result = finish([began(3, 4), merge(1, 2), began(1, 2)], state: state)
        XCTAssertEqual(result.events, [began(1, 2), merge(1, 2), began(3, 4)])
        XCTAssertEqual(result.contacts, [pair(1, 2), pair(3, 4)])
    }

    // Koniec kontaktu pary odkłada się w historii; kolejny początek tej pary (jej koniec przepadł) jest pomijany.
    func testContactBeganForPairAlreadyInHistoryIsSkipped() throws {
        let state = try state(bubbles: [1, 2])
        let result = finish([began(1, 2)], state: state, previous: [pair(1, 2)])
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.contacts, [pair(1, 2)])
    }

    // P-B-15: początek, który przepadł w przepełnieniu GPU, nie może dać późniejszego końca bez początku.
    func testContactEndedWithoutDeliveredBeganIsDropped() throws {
        let state = try state(bubbles: [1, 2, 3, 4])
        let first = finish([began(1, 2)], state: state, dropped: 1)
        XCTAssertEqual(first.events, [began(1, 2)])
        XCTAssertEqual(first.contacts, [pair(1, 2)], "w historii tylko pary z dostarczonym początkiem")
        let second = finish([.contactEnded(id(1), id(2)), .contactEnded(id(3), id(4))], state: state, previous: first.contacts)
        XCTAssertEqual(second.events, [.contactEnded(id(1), id(2))])
        XCTAssertTrue(second.contacts.isEmpty)
    }

    // G7-AC2: usunięcie, scalenie albo podział obiektu daje koniec kontaktu pozostałemu partnerowi.
    func testRemovedObjectEndsItsContactsForRemainingPartnerOnly() throws {
        let state = try state(bubbles: [1, 3, 4])   // obiektu 2 już nie ma
        let result = finish([], state: state, previous: [pair(1, 2), pair(3, 4)], removed: [id(2)])
        XCTAssertEqual(result.events, [.contactEnded(id(1), id(2))])
        XCTAssertEqual(result.contacts, [pair(3, 4)])
    }

    func testContactBetweenTwoRemovedObjectsProducesNoEventAndLeavesHistory() throws {
        let state = try state(bubbles: [1])
        let result = finish([], state: state, previous: [pair(2, 3)], removed: [id(2), id(3)])
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.contacts.isEmpty)
    }

    func testGPUEndForRemovedObjectIsNotDuplicated() throws {
        let state = try state(bubbles: [1])
        let result = finish([.contactEnded(id(1), id(2))], state: state, previous: [pair(1, 2)], removed: [id(2)])
        XCTAssertEqual(result.events, [.contactEnded(id(1), id(2))])
        XCTAssertTrue(result.contacts.isEmpty)
    }

    // P-B-15: koniec, który nie mieści się w buforze, zostaje w historii i wychodzi w następnym kroku.
    func testEndThatDoesNotFitTheEventBufferStaysInHistoryAndIsEmittedNextStep() throws {
        let state = try state(bubbles: [1, 3], capacity: 1)   // obiektów 2 i 4 już nie ma
        let first = finish([], state: state, previous: [pair(1, 2), pair(3, 4)], removed: [id(2), id(4)])
        XCTAssertEqual(first.events, [.contactEnded(id(1), id(2))], "w buforze o pojemności 1 mieści się jeden koniec")
        XCTAssertEqual(first.dropped, 1)
        XCTAssertEqual(first.contacts, [pair(3, 4)], "koniec, który się nie zmieścił, zostaje w historii")
        let second = finish([], state: state, previous: first.contacts, removed: [id(4)])
        XCTAssertEqual(second.events, [.contactEnded(id(3), id(4))])
        XCTAssertTrue(second.contacts.isEmpty)
    }

    func testEndForRemovedObjectDoesNotFitWhenGPUEventsFillTheBuffer() throws {
        let state = try state(bubbles: [1, 5, 6], capacity: 1)   // obiektu 2 już nie ma
        let first = finish([began(5, 6)], state: state, previous: [pair(1, 2)], removed: [id(2)])
        XCTAssertEqual(first.events, [began(5, 6)])
        XCTAssertEqual(first.contacts, [pair(1, 2), pair(5, 6)])
        let second = finish([], state: state, previous: first.contacts, removed: [id(2)])
        XCTAssertEqual(second.events, [.contactEnded(id(1), id(2))])
        XCTAssertEqual(second.contacts, [pair(5, 6)])
    }
}
