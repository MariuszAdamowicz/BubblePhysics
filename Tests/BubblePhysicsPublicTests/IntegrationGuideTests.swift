import Foundation
import XCTest

/// P-B-60 (G13-AC2): każdy blok `swift` w `docs/integration-guide.md` ma znacznik `<!-- guide-region: nazwa -->` tuż nad sobą
/// i jest identyczny z regionem `// guide-region: nazwa` … `// guide-region-end` w źródłach przykładowej aplikacji,
/// więc kompiluje się razem z nią. Każdy region jest użyty, a przewodnik ma nagłówki siedmiu tematów.
final class IntegrationGuideTests: XCTestCase {
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

    /// Usuwa wspólne wcięcie i końcowe puste wiersze, żeby porównanie nie zależało od głębokości zagnieżdżenia w źródle.
    private func normalized(_ lines: [Substring]) -> String {
        var lines = lines.map { String($0) }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines.map { $0.count >= indent ? String($0.dropFirst(indent)) : $0 }
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    /// Regiony z plików `.swift` przykładu: nazwa → treść. Zduplikowana nazwa i region bez końca to błąd.
    private func exampleRegions() throws -> [String: String] {
        let directory = root.appendingPathComponent("Examples/BubblePhysicsShowcase/App")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let files = names.filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertFalse(files.isEmpty, "brak źródeł przykładu w Examples/BubblePhysicsShowcase/App")
        var regions: [String: String] = [:]
        for file in files {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            var current: (name: String, lines: [Substring])?
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "// guide-region-end" {
                    guard let open = current else { XCTFail("\(file): guide-region-end bez początku"); continue }
                    XCTAssertNil(regions[open.name], "region \(open.name) zdefiniowany dwa razy")
                    regions[open.name] = normalized(open.lines)
                    current = nil
                } else if trimmed.hasPrefix("// guide-region:") {
                    XCTAssertNil(current, "\(file): region zagnieżdżony w \(current?.name ?? "")")
                    current = (trimmed.dropFirst("// guide-region:".count).trimmingCharacters(in: .whitespaces), [])
                } else if current != nil {
                    current?.lines.append(line)
                }
            }
            XCTAssertNil(current, "\(file): region \(current?.name ?? "") bez guide-region-end")
        }
        return regions
    }

    private struct GuideBlock {
        let region: String?
        let code: String
        let line: Int
    }

    private func guideBlocks(_ guide: String) -> [GuideBlock] {
        var blocks: [GuideBlock] = []
        var marker: String?
        var open: (region: String?, lines: [Substring], line: Int)?
        for (index, line) in guide.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = open {
                if trimmed == "```" {
                    blocks.append(GuideBlock(region: current.region, code: normalized(current.lines), line: current.line))
                    open = nil
                } else { open?.lines.append(line) }
            } else if trimmed == "```swift" {
                open = (marker, [], index + 1)
                marker = nil
            } else if trimmed.hasPrefix("<!-- guide-region:"), trimmed.hasSuffix("-->") {
                marker = trimmed.dropFirst("<!-- guide-region:".count).dropLast(3).trimmingCharacters(in: .whitespaces)
            } else if !trimmed.isEmpty { marker = nil }
        }
        return blocks
    }

    func testEverySwiftBlockHasAMarkerAndEqualsItsExampleRegion() throws {
        let guide = try read("docs/integration-guide.md")
        let regions = try exampleRegions()
        let blocks = guideBlocks(guide)
        XCTAssertFalse(blocks.isEmpty, "przewodnik ma bloki kodu swift")
        for block in blocks {
            guard let name = block.region else {
                XCTFail("blok swift w wierszu \(block.line) bez znacznika <!-- guide-region: nazwa --> nad nim"); continue
            }
            guard let source = regions[name] else {
                XCTFail("blok w wierszu \(block.line): przykład nie ma regionu \(name)"); continue
            }
            XCTAssertEqual(block.code, source, "blok w wierszu \(block.line) różni się od regionu \(name) przykładu")
        }
    }

    func testEveryExampleRegionIsUsedByTheGuide() throws {
        let guide = try read("docs/integration-guide.md")
        let regions = try exampleRegions()
        XCTAssertFalse(regions.isEmpty, "przykład ma oznaczone regiony")
        let used = Set(guideBlocks(guide).compactMap(\.region))
        for name in regions.keys.sorted() {
            XCTAssertTrue(used.contains(name), "region \(name) nie jest użyty w przewodniku")
        }
    }

    func testGuideHasHeadingsForTheSevenTopics() throws {
        let guide = try read("docs/integration-guide.md")
        let headings = guide.split(separator: "\n").filter { $0.hasPrefix("## ") }.map { $0.lowercased() }
        let topics = ["pętla mtkview", "prezentacja drawable", "cykl życia", "rejestracja tekstur", "zapytania",
                      "obsługa zdarzeń", "formaty passu"]
        for topic in topics {
            XCTAssertTrue(headings.contains { $0.contains(topic) }, "brak nagłówka tematu „\(topic)”")
        }
    }
}
