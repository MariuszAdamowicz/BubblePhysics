import Foundation
import XCTest

/// P-B-1 (G1-AC4): moduły produkcyjne nie zależą, nawet pośrednio, od Reference, ReferenceMetal,
/// Legacy, Core ani Metal. Graf pochodzi z `swift package dump-package`.
final class PackageGraphTests: XCTestCase {
    private static let productionTargets = ["BubblePhysics", "BubblePhysicsMetalRender", "BubblePhysicsAssets"]
    private static let forbidden: Set<String> = [
        "BubblePhysicsReference", "BubblePhysicsReferenceMetal", "BubblePhysicsLegacy",
        "BubblePhysicsCore", "BubblePhysicsMetal"
    ]

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Wynik: nazwa celu → bezpośrednie zależności od innych celów pakietu.
    private func loadGraph() throws -> [String: [String]] {
        // Osobny katalog roboczy: trwający `swift test` trzyma blokadę `.build`, a dump-package
        // czekałby na nią w nieskończoność.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("package-graph-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "package", "--package-path", packageRoot.path,
                             "--scratch-path", scratch.path, "dump-package"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        var data = Data()
        let reader = DispatchQueue(label: "dump-package-output")
        let read = DispatchSemaphore(value: 0)
        reader.async { data = output.fileHandleForReading.readDataToEndOfFile(); read.signal() }
        guard finished.wait(timeout: .now() + 120) == .success else {
            process.terminate()
            struct DumpPackageTimeout: Error {}
            // Przekroczenie czasu ma oblać test G1-AC4, a nie go pominąć.
            XCTFail("dump-package nie zakończył się w 120 s")
            throw DumpPackageTimeout()
        }
        read.wait()
        XCTAssertEqual(process.terminationStatus, 0)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let targets = try XCTUnwrap(manifest["targets"] as? [[String: Any]])
        var graph: [String: [String]] = [:]
        for target in targets {
            let name = try XCTUnwrap(target["name"] as? String)
            let dependencies = target["dependencies"] as? [[String: Any]] ?? []
            graph[name] = dependencies.flatMap { dependency -> [String] in
                for key in ["byName", "target"] {
                    if let values = dependency[key] as? [Any], let first = values.first as? String { return [first] }
                }
                return []
            }
        }
        return graph
    }

    private func closure(of roots: [String], in graph: [String: [String]]) -> Set<String> {
        var seen: Set<String> = []
        var pending = roots
        while let next = pending.popLast() {
            guard seen.insert(next).inserted else { continue }
            pending += graph[next] ?? []
        }
        return seen
    }

    func testClosureFollowsIndirectDependencies() {
        let graph = ["A": ["B"], "B": ["C"], "C": []]
        XCTAssertEqual(closure(of: ["A"], in: graph), ["A", "B", "C"])
    }

    func testProductionModulesDoNotDependOnReferenceLegacyCoreOrMetal() throws {
        let graph = try loadGraph()
        XCTAssertNotNil(graph["BubblePhysics"])
        XCTAssertNotNil(graph["BubblePhysicsMetalRender"])
        // BubblePhysicsAssets powstaje w etapie 5; od tej chwili test obejmie go bez zmian.
        for target in Self.productionTargets where graph[target] != nil {
            let reached = closure(of: [target], in: graph)
            XCTAssertTrue(reached.isDisjoint(with: Self.forbidden),
                "\(target) zależy od \(reached.intersection(Self.forbidden).sorted())")
        }
    }
}
