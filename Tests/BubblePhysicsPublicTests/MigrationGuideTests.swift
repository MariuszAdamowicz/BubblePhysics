import Foundation
import XCTest

/// P-B-10 (G1-AC1): `docs/migration/v1-api-diff.txt` to wynik `swift-api-digester -diagnose-sdk` między `v1.0.0` a HEAD,
/// a `docs/MIGRATION-v2.md` ma zamiennik każdego symbolu z tego diffu. README podaje 2.0.0 i odsyła do obu dokumentów.
/// Korzeń repozytorium wynika z `#filePath`, jak w `PackageGraphTests`.
final class MigrationGuideTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("brak pliku \(path)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Wiersz diagnostyczny digestera, np. `BubblePhysicsModel: Struct RenderStyle has been removed`.
    private struct DiffSymbol {
        let line: String
        /// `Owner.member` albo sama nazwa typu, bez sygnatury (`RenderStyle`, `WorldTransaction.updateRenderStyle`).
        let name: String
        /// Typ właściciela, gdy symbol jest członkiem (`WorldTransaction`).
        let owner: String?
    }

    private func symbols(in diff: String) -> [DiffSymbol] {
        var result: [DiffSymbol] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
            // `Module: Kind symbol has ...`
            guard let colon = line.range(of: ": "), !line[line.startIndex..<colon.lowerBound].contains(" ") else { continue }
            let rest = line[colon.upperBound...]
            guard let space = rest.firstIndex(of: " "), let has = rest.range(of: " has ") else { continue }
            var declaration = String(rest[rest.index(after: space)..<has.lowerBound])
            if let paren = declaration.firstIndex(of: "(") { declaration = String(declaration[..<paren]) }
            let owner = declaration.contains(".") ? String(declaration[..<declaration.lastIndex(of: ".")!]) : nil
            result.append(DiffSymbol(line: String(line), name: declaration, owner: owner))
        }
        return result
    }

    /// Wiersze tabel dokumentu migracji: komórka symbolu (pierwsza) i zamiennik (druga).
    private func migrationRows(_ document: String) -> [(symbols: String, replacement: String)] {
        document.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("|") else { return nil }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2 else { return nil }
            return (cells[0], cells[1])
        }
    }

    func testDiffHasACommandHeaderWithRelativePathsAndNothingThatVariesBetweenRuns() throws {
        let diff = try read("docs/migration/v1-api-diff.txt")
        let header = diff.split(separator: "\n").filter { $0.hasPrefix("#") }.joined(separator: "\n")
        XCTAssertTrue(header.contains("swift-api-digester -dump-sdk"), "nagłówek podaje polecenie zrzutu")
        XCTAssertTrue(header.contains("swift-api-digester -diagnose-sdk"), "nagłówek podaje polecenie diffu")
        XCTAssertTrue(header.contains(".build/v1-worktree"), "worktree tagu v1.0.0 pod stałą ścieżką")
        for module in ["BubblePhysics", "BubblePhysicsModel", "BubblePhysicsMetalRender"] {
            XCTAssertTrue(header.contains(module), "nagłówek wymienia moduł \(module)")
        }
        for absolute in ["/Users/", "/private/", "/var/", "/tmp/", "/Applications/"] {
            XCTAssertFalse(diff.contains(absolute), "diff zawiera ścieżkę bezwzględną \(absolute)")
        }
        let date = try NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#)
        XCTAssertNil(date.firstMatch(in: diff, range: NSRange(diff.startIndex..., in: diff)), "diff zawiera datę")
    }

    func testEverySymbolFromTheApiDiffHasAMigrationEntryWithAReplacement() throws {
        let diff = try read("docs/migration/v1-api-diff.txt")
        let migration = try read("docs/MIGRATION-v2.md")
        let all = symbols(in: diff)
        XCTAssertGreaterThan(all.count, 20, "diff ma wiersze diagnostyczne digestera")
        XCTAssertTrue(all.contains { $0.name == "RenderStyle" })
        XCTAssertTrue(all.contains { $0.name == "PolygonDescriptor" })
        XCTAssertTrue(all.contains { $0.name.hasSuffix("measure") })
        let rows = migrationRows(migration)
        // Wiersz z samym typem właściciela obejmuje jego członków tylko wtedy, gdy diff zgłasza usunięcie tego typu;
        // w przeciwnym razie członek potrzebuje własnego wpisu `Owner.member`.
        let removedTypes = Set(all.filter { $0.owner == nil && $0.line.contains(" has been removed") }.map(\.name))
        for symbol in all {
            var keys = ["`\(symbol.name)`"]
            if let owner = symbol.owner, removedTypes.contains(owner) { keys.append("`\(owner)`") }
            let covered = rows.contains { row in
                keys.contains { row.symbols.contains($0) } && row.replacement.count >= 3
            }
            XCTAssertTrue(covered, "brak wpisu w MIGRATION-v2.md (tabela: symbol w pierwszej komórce, zamiennik w drugiej) dla: \(symbol.line)")
        }
    }

    func testMigrationNamesTheKeyReplacementsAndTheMovedDiagnostics() throws {
        let migration = try read("docs/MIGRATION-v2.md")
        for needle in ["RenderMaterial", "RigidBodyDescriptor", "PresentationParameters", "ParameterID",
                       "measure(device:scene:renderSize:progress:)", "BubblePhysicsNativeMetalDiagnostics",
                       "didExitSimulationRegion", "frameRejected", "worldFailed", "SensorDescriptor"] {
            XCTAssertTrue(migration.contains(needle), "MIGRATION-v2.md nie wspomina o \(needle)")
        }
    }

    func testReadmeStatesVersion2AndLinksBothGuides() throws {
        let readme = try read("README.md")
        XCTAssertTrue(readme.contains("2.0.0"), "README podaje wersję 2.0.0")
        XCTAssertTrue(readme.contains("(docs/MIGRATION-v2.md)"), "README odsyła do dokumentu migracji")
        XCTAssertTrue(readme.contains("(docs/integration-guide.md)"), "README odsyła do przewodnika integracji")
    }
}
