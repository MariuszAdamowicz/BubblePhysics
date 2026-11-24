import Foundation
import XCTest

/// P-B-10 (G1-AC1): `docs/migration/v1-api-diff.txt` to wynik `swift-api-digester -diagnose-sdk` między `v1.0.0` a HEAD,
/// a `docs/MIGRATION-v2.md` ma zamiennik każdego symbolu z tego diffu. README podaje bieżącą wersję 4.0.0 i odsyła
/// do `CHANGELOG.md` i do `docs/MIGRATION-v4.md`, a dalej wspomina 2.0.0 jako wersję migracji i odsyła do starszych przewodników.
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

    func testReadmeStatesCurrentVersionAndLinksTheChangelogAndAllGuides() throws {
        let readme = try read("README.md")
        XCTAssertTrue(readme.contains("Wersja 4.0.0"), "README podaje bieżącą wersję 4.0.0")
        XCTAssertFalse(readme.contains("Wersja 3.0.2"), "README nie podaje starej wersji jako bieżącej")
        XCTAssertTrue(readme.contains("(docs/MIGRATION-v4.md)"), "README odsyła do dokumentu migracji na 4.0.0")
        XCTAssertTrue(readme.contains("(CHANGELOG.md)"), "README odsyła do changeloga")
        XCTAssertTrue(readme.contains("2.0.0"), "README wspomina 2.0.0 jako wersję migracji z 1.x")
        XCTAssertTrue(readme.contains("(docs/MIGRATION-v2.md)"), "README odsyła do dokumentu migracji")
        XCTAssertTrue(readme.contains("(docs/MIGRATION-v3.md)"), "README odsyła do dokumentu migracji na 3.0.0")
        XCTAssertTrue(readme.contains("(docs/integration-guide.md)"), "README odsyła do przewodnika integracji")
    }

    /// P-B-2 (G1-AC2): `docs/MIGRATION-v4.md` ma wiersz tabeli (symbol w pierwszej komórce, zastępstwo albo powód usunięcia
    /// w drugiej) dla każdego symbolu usuniętego z publicznego API w 4.0.0.
    func testMigrationV4HasARowWithAReplacementForEveryRemovedSymbol() throws {
        let rows = migrationRows(try read("docs/MIGRATION-v4.md"))
        let removed = [
            "BubbleContactCompliance", "contactCompliance", "contactDampingRatio", "deformability",
            "PhysicsParameter.deformability", "SolverGuardCause.centerCrossing", "containedBubblePairCount",
            "NativeMetalConfiguration.solverIterationCount", "NativeMetalConfiguration.contactCompliance",
            "NativeMetalConfiguration.cacheExpiryFrames", "NativeMetalConfiguration.teleportDistanceMultiplier",
            "NativeMetalConfiguration.ccdVelocityMultiplier",
            "NativeMetalFrameTelemetry.cacheHitCount", "NativeMetalFrameTelemetry.cacheResetCount",
            "NativeMetalFrameTelemetry.solverIterationCount", "NativeMetalFrameTelemetry.ccdCandidateCount",
            "NativeMetalFrameTelemetry.guardCorrectionCount", "NativeMetalFrameTelemetry.cacheInvalidationCount"]
        for symbol in removed {
            let covered = rows.contains { $0.symbols.contains("`\(symbol)`") && $0.replacement.count >= 10 }
            XCTAssertTrue(covered, "brak wiersza w MIGRATION-v4.md (symbol w pierwszej komórce, zastępstwo w drugiej) dla: \(symbol)")
        }
    }

    /// G9-AC4: `CHANGELOG.md` ma sekcję 4.0.0 nad 3.0.2 i odsyła do przewodnika migracji we wstępie.
    func testChangelogHasThe400SectionAndLinksTheV4Guide() throws {
        let changelog = try read("CHANGELOG.md")
        let sectionStart = try XCTUnwrap(changelog.range(of: "\n## 4.0.0\n"), "CHANGELOG.md bez sekcji `## 4.0.0`").lowerBound
        let previous = try XCTUnwrap(changelog.range(of: "\n## 3.0.2\n")).lowerBound
        XCTAssertLessThan(sectionStart, previous, "sekcja 4.0.0 leży nad 3.0.2")
        XCTAssertTrue(changelog[..<sectionStart].contains("(docs/MIGRATION-v4.md)"), "wstęp CHANGELOG.md odsyła do MIGRATION-v4.md")
    }

    /// G9-AC4: przyczyny odrzucenia i błędu z 4.0.0 są nazwane, a znane ograniczenia opisują sztywne `contactStiffness` i przeguby z bańkami.
    func testMigrationV4NamesTheNewRejectionsAndTheRigidStiffnessLimit() throws {
        let migration = try read("docs/MIGRATION-v4.md")
        for needle in ["substepLimitExceeded", "unsupportedJointBody", "unsupportedBubbleWithDynamicRigidBody"] {
            XCTAssertTrue(migration.contains(needle), "MIGRATION-v4.md nie wspomina o \(needle)")
        }
        let limits = try XCTUnwrap(migration.range(of: "## Znane ograniczenia"), "brak sekcji Znane ograniczenia")
        let bullets = migration[limits.upperBound...].split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertTrue(bullets.contains { $0.contains("contactStiffness") && $0.contains("sztywn") },
                      "znane ograniczenia nie opisują sztywnego `contactStiffness`")
        XCTAssertTrue(bullets.contains { $0.contains("unsupportedJointBody") },
                      "znane ograniczenia nie opisują przegubów z bańkami (`unsupportedJointBody`)")
    }

    func testMigrationV4NamesTheAddedSymbolsAndTheKnownLimits() throws {
        let migration = try read("docs/MIGRATION-v4.md")
        for needle in ["contactStiffness", "PhysicsParameter.contactStiffness", "WorldFailureDetail", "contactViolation",
                       "substepCount", "gridRebuildCount", "substepBufferCount", "executionPath", "singleGroupWidth",
                       "physicsGPUMilliseconds", "contourGPUMilliseconds",
                       "rigidRotationBudget", "candidateLimitPerObject", "contactCandidateOverflow"] {
            XCTAssertTrue(migration.contains(needle), "MIGRATION-v4.md nie wspomina o \(needle)")
        }
    }
}
