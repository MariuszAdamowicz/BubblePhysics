import CoreGraphics
import CoreText
import Metal

/// Generator atlasu SDF z czcionki: raster glifu w wysokiej rozdzielczości (Core Text), transformata odległości na CPU,
/// atlas `r8Unorm` z metrykami. Działa wyłącznie w wywołaniu rejestracji, nigdy w klatce.
///
/// Skala 1× to glif, którego wysokość linii (`ascent + descent`) wynosi 32 teksle. Wartość tekselu to
/// `0,5 + odległość ze znakiem / (2 · spread)` (dodatnia wewnątrz glifu), więc krawędź glifu leży na 0,5, a atlas wystarcza
/// do ostrej krawędzi przy skalach od 0,25× do 4×.
enum SDFAtlasGenerator {
    /// Wysokość linii przy skali 1×, w tekselach atlasu.
    static let lineHeight: Float = 32
    /// Zasięg pola odległości po obu stronach krawędzi, w tekselach; to także margines komórki glifu.
    static let spread = 4
    /// Raster glifu jest `oversample` razy gęstszy niż atlas.
    static let oversample = 4
    static let maximumTextureSide = 4096

    /// Znajduje czcionkę po nazwie PostScript, pełnej albo rodziny. Core Text podstawia czcionkę domyślną dla nieznanej
    /// nazwy, więc dopasowanie jest obowiązkowe (`nil`, gdy nic nie pasuje).
    static func font(named name: String, size: CGFloat) -> CTFont? {
        for attribute in [kCTFontNameAttribute, kCTFontDisplayNameAttribute, kCTFontFamilyNameAttribute] {
            let descriptor = CTFontDescriptorCreateWithAttributes([attribute: name] as CFDictionary)
            if let matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, NSSet(object: attribute) as CFSet) {
                return CTFontCreateWithFontDescriptor(matched, size, nil)
            }
        }
        return nil
    }

    private struct Cell {
        let character: Character
        let glyph: CGGlyph
        /// Lewy dolny róg komórki w układzie glifu (Y w górę), całkowity.
        let originX: Int, originY: Int
        let width: Int, height: Int
        let advance: Float
        var packX = 0, packY = 0
    }

    static func generate(fontName: String, characters: String, device: MTLDevice) throws -> GlyphAtlas {
        guard var font = font(named: fontName, size: 100) else { throw AssetError.fontNotFound }
        // Rozmiar czcionki tak, żeby ascent + descent dawały dokładnie 32 teksle.
        let natural = Float(CTFontGetAscent(font) + CTFontGetDescent(font))
        guard natural > 0, natural.isFinite else { throw AssetError.fontNotFound }
        let factor = lineHeight / natural
        font = CTFontCreateCopyWithAttributes(font, 100 * CGFloat(factor), nil, nil)
        let ascent = Float(CTFontGetAscent(font)), descent = Float(CTFontGetDescent(font))

        var cells: [Cell] = []
        for character in Set(characters).sorted() {
            // Klastry wielu znaków unikodu (np. emoji z modyfikatorami) nie mają jednego glifu.
            guard character.unicodeScalars.count == 1 else { continue }
            let units = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) else { continue }
            var glyph = glyphs[0]
            var advances = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advances, 1)
            let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
            let minX: Int, minY: Int, maxX: Int, maxY: Int
            if bounds.isNull || bounds.isEmpty || !bounds.minX.isFinite || !bounds.maxX.isFinite {
                (minX, minY, maxX, maxY) = (0, 0, 0, 0)
            } else {
                (minX, minY) = (Int(floor(bounds.minX)), Int(floor(bounds.minY)))
                (maxX, maxY) = (Int(ceil(bounds.maxX)), Int(ceil(bounds.maxY)))
            }
            cells.append(Cell(character: character, glyph: glyph, originX: minX - spread, originY: minY - spread,
                              width: maxX - minX + 2 * spread, height: maxY - minY + 2 * spread,
                              advance: Float(advances.width)))
        }
        guard !cells.isEmpty else { throw AssetError.invalidGlyphAtlas }

        let side = try pack(&cells)
        var pixels = [UInt8](repeating: 0, count: side * side)
        for cell in cells {
            let field = try distanceField(of: cell, font: font)
            for row in 0..<cell.height {
                let target = (cell.packY + row) * side + cell.packX
                for column in 0..<cell.width { pixels[target + column] = field[row * cell.width + column] }
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: side, height: side, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw AssetError.textureCreationFailed }
        texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: pixels, bytesPerRow: side)

        var metrics: [Character: GlyphMetrics] = [:]
        for cell in cells {
            metrics[cell.character] = GlyphMetrics(origin: SIMD2(Float(cell.packX), Float(cell.packY)),
                size: SIMD2(Float(cell.width), Float(cell.height)),
                offset: SIMD2(Float(cell.originX), Float(cell.originY)), advance: cell.advance)
        }
        return GlyphAtlas(texture: texture, glyphs: metrics, ascent: ascent, descent: descent, isSignedDistanceField: true)
    }

    /// Układa komórki półkami w najmniejszej kwadratowej teksturze o boku będącym potęgą dwójki; zwraca ten bok.
    private static func pack(_ cells: inout [Cell]) throws -> Int {
        let order = cells.indices.sorted { cells[$0].height != cells[$1].height ? cells[$0].height > cells[$1].height : $0 < $1 }
        var side = 64
        while side <= maximumTextureSide {
            var x = 0, y = 0, shelf = 0, fits = true
            var placed: [(Int, Int)] = Array(repeating: (0, 0), count: cells.count)
            for index in order {
                let cell = cells[index]
                if cell.width > side || cell.height > side { fits = false; break }
                if x + cell.width > side { x = 0; y += shelf; shelf = 0 }
                if y + cell.height > side { fits = false; break }
                placed[index] = (x, y)
                x += cell.width; shelf = max(shelf, cell.height)
            }
            if fits {
                for index in cells.indices { (cells[index].packX, cells[index].packY) = placed[index] }
                return side
            }
            side *= 2
        }
        throw AssetError.invalidGlyphAtlas
    }

    /// Pole odległości komórki w tekselach atlasu: wiersz 0 u góry, wartość 0,5 na krawędzi glifu.
    private static func distanceField(of cell: Cell, font: CTFont) throws -> [UInt8] {
        let scale = oversample
        let width = cell.width * scale, height = cell.height * scale
        var raster = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = raster.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            var glyph = cell.glyph
            var position = CGPoint(x: -cell.originX, y: -cell.originY)
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
            return true
        }
        guard drawn else { throw AssetError.textureCreationFailed }
        let inside = raster.map { $0 >= 128 }
        // Odległość do najbliższego piksela po drugiej stronie krawędzi, osobno wewnątrz i na zewnątrz.
        let toOutside = squaredDistance(to: inside.map { !$0 }, width: width, height: height)
        let toInside = squaredDistance(to: inside, width: width, height: height)
        func signed(_ x: Int, _ y: Int) -> Float {
            let index = y * width + x
            return inside[index] ? (toOutside[index].squareRoot() - 0.5) : -(toInside[index].squareRoot() - 0.5)
        }
        var field = [UInt8](repeating: 0, count: cell.width * cell.height)
        let half = scale / 2
        for row in 0..<cell.height {
            for column in 0..<cell.width {
                // Środek tekselu leży na styku czterech pikseli rastra.
                let x = column * scale + half, y = row * scale + half
                let average = (signed(x - 1, y - 1) + signed(x, y - 1) + signed(x - 1, y) + signed(x, y)) / 4
                let texels = average / Float(scale)
                let value = 0.5 + texels / Float(2 * spread)
                field[row * cell.width + column] = UInt8((min(max(value, 0), 1) * 255).rounded())
            }
        }
        return field
    }

    /// Kwadrat odległości każdego piksela do najbliższego piksela z `targets` (Felzenszwalb–Huttenlocher, dwa przebiegi).
    private static func squaredDistance(to targets: [Bool], width: Int, height: Int) -> [Float] {
        let infinity: Float = 1e12
        var grid = targets.map { $0 ? Float(0) : infinity }
        var column = [Float](repeating: 0, count: height)
        for x in 0..<width {
            for y in 0..<height { column[y] = grid[y * width + x] }
            let result = transform(column)
            for y in 0..<height { grid[y * width + x] = result[y] }
        }
        var row = [Float](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width { row[x] = grid[y * width + x] }
            let result = transform(row)
            for x in 0..<width { grid[y * width + x] = result[x] }
        }
        return grid
    }

    /// Jednowymiarowa transformata kwadratu odległości (dolna otoczka parabol).
    private static func transform(_ samples: [Float]) -> [Float] {
        let count = samples.count
        var result = [Float](repeating: 0, count: count)
        var vertices = [Int](repeating: 0, count: count)
        var boundaries = [Float](repeating: 0, count: count + 1)
        var last = 0
        boundaries[0] = -.infinity; boundaries[1] = .infinity
        func intersection(_ q: Int, _ p: Int) -> Float {
            ((samples[q] + Float(q * q)) - (samples[p] + Float(p * p))) / Float(2 * q - 2 * p)
        }
        for q in 1..<max(count, 1) {
            var s = intersection(q, vertices[last])
            while s <= boundaries[last] {
                last -= 1
                s = intersection(q, vertices[last])
            }
            last += 1
            vertices[last] = q
            boundaries[last] = s
            boundaries[last + 1] = .infinity
        }
        last = 0
        for q in 0..<count {
            while boundaries[last + 1] < Float(q) { last += 1 }
            let distance = Float(q - vertices[last])
            result[q] = distance * distance + samples[vertices[last]]
        }
        return result
    }
}
