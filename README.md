# BubblePhysics

`BubblePhysics` to pakiet Swift z silnikiem fizycznym GPU dla deformowalnych baniek 2D, sztywnych wielokątów, sensorów i pól sił. Działa na iOS 16+ i macOS 13+ (GPU Apple z Metal).

## Produkty

| Produkt | Przeznaczenie |
|---|---|
| `BubblePhysics` | API gry: `BubbleWorld`, `WorldTransaction`, `WorldFrame`, typy modelu i diagnostyka. |
| `BubblePhysicsMetalRender` | Renderuje opublikowaną klatkę świata bezpośrednio z buforów GPU do command buffera aplikacji. |
| `BubblePhysicsBenchmarkSupport` | Wyłącznie moduły diagnostyczne (solvery referencyjne, historyczne eksperymenty). Nie są częścią API gry. |
| `BubblePhysicsReferenceBench` | Runner benchmarków dla macOS z linii poleceń. |

Produkty dla gry działają na backendzie `native-metal` (trwały stan na GPU, trwały cache kontaktów, solver XPBD/PBD Jacobi). Referencyjny solver CPU (`BubblePhysicsReference`) jest wyrocznią poprawności dla testów i benchmarków; nie jest fallbackiem `BubbleWorld` w czasie działania.

## Szybki start

```swift
import BubblePhysics
import BubblePhysicsMetalRender
import Metal

let configuration = try WorldConfiguration(
    simulationRegion: WorldRectangle(min: [0, 0], max: [375, 700]),
    fixedTimeStep: 1.0 / 60)
let world = try BubbleWorld(configuration: configuration)

let material = PhysicsMaterialID(rawValue: 1)
let style = RenderStyleID(rawValue: 1)
world.submit(WorldTransaction()
    .updatePhysicsMaterial(material, material: try PhysicsMaterial(kind: .bubble))
    .updateRenderStyle(style, style: try RenderStyle())
    .add(.bubble(try BubbleDescriptor(id: ObjectID(rawValue: 1), position: [187, 350],
                                      targetRadius: 20, mass: 8,
                                      physicsMaterialID: material, renderStyleID: style))))

// Sam krok fizyki:
let frame = await world.advance(by: 1.0 / 60)
for event in frame.events { /* merge, wejście/wyjście z sensora, wyjście z regionu, ... */ }

// Fizyka i render w jednym command bufferze:
let renderer = try BubblePhysicsMetalRender(device: device)
let rendered = await world.advance(by: 1.0 / 60, commandBuffer: commandBuffer) {
    try renderer.encode(world: world, viewport: Viewport(center: [187.5, 350], size: [375, 700]),
                        commandBuffer: commandBuffer, renderPassDescriptor: passDescriptor)
}
// Drawable prezentuj tylko wtedy, gdy `world.diagnostics.lastAdvanceIssue == nil`.
```

`BubbleWorld` jest `@MainActor`. Każda zmiana świata przechodzi przez atomową `WorldTransaction` (dodanie/usunięcie/zamiana obiektów, materiały i style, role ruchu, napędy ścieżki/silnika/gracza, siła globalna, impulsy, przejścia parametrów, łączenie i dzielenie baniek, zamiana wielokątów). Każda `WorldFrame` zawiera potwierdzenia transakcji, zdarzenia opt-in, informację o przepełnieniu zdarzeń i feedback napędów.

## Zachowanie w czasie działania, o którym warto wiedzieć

- Czas płynie stałymi krokami. `advance(by:commandBuffer:encodeRender:)` wykonuje najwyżej jeden krok na command buffer; reszta czasu zostaje w `world.diagnostics.backlogSeconds`.
- Gdy krok GPU się nie powiedzie, `advance` zwraca ostatnią kompletną klatkę, ustawia `lastAdvanceIssue = .stepFailed` i zachowuje kolejkę transakcji na następne wywołanie. Ścieżka gry nie ma fallbacku CPU.
- Stan obiektów (pozycja, prędkość, obrót) nie ma jeszcze publicznego odczytu; renderer czyta go bezpośrednio z buforów GPU, a `DriveFeedback` podaje osiągnięty punkt obiektów sterowanych.
- `debugContourSnapshot()` kopiuje kontury na CPU i służy wyłącznie do debugowania.

## Testy

```bash
swift build --build-tests
swift test
```

Testy Metal działają na macOS z lokalnym GPU. Źródła shaderów są dołączone jako pliki `.metal-source` i kompilowane w czasie działania, raz na `MTLDevice`. `NativeMetalShaderABITests` sprawdza, czy rekordy buforów w Swift odpowiadają układowi struktur wygenerowanemu przez kompilator Metal.

## Benchmark na urządzeniu

Aplikacja hosta iOS jest w `Benchmarks/iOS/BubblePhysicsBench` i ma jeden ekran, który uruchamia `PublicWorldStressBenchmark`: 300 baniek, cztery ściany i poruszający się trójkąt, renderowane przez `BubblePhysicsMetalRender` w tym samym command bufferze co krok fizyki.

1. Skopiuj `Benchmarks/iOS/BubblePhysicsBench/Signing.local.xcconfig.example` do `Signing.local.xcconfig` (ignorowany przez git) i ustaw swój `DEVELOPMENT_TEAM` oraz bundle identifier.
2. Otwórz `BubblePhysicsBench.xcodeproj`, wybierz fizyczny iPhone i uruchom konfigurację Release.
3. Użyj „Kopiuj raport” i zapisz surowy wynik w `docs/benchmarks/`.

Build kontrolny bez podpisu:

```bash
xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj \
  -scheme BubblePhysicsBench -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Bramka akceptacji to p95 pełnej klatki nie większe niż `PublicWorldStressBenchmark.p95GateMilliseconds` (10.4568 ms) na iPhonie X, przy zerze nieudanych klatek, zerze klatek `non-finite` i bez readbacku konturów na CPU. Raport wypisuje tę wartość jako `p95_gate_ms`. Jedyny dotychczasowy pomiar urządzeniowy (2026-10-14, `docs/benchmarks/native-metal-bubble-solver-2026-10-14.md`) wykonano na wcześniejszej ścieżce `NativeMetalBenchmarkRunner`; ścieżka gry `BubbleWorld` + renderer nie była jeszcze mierzona na urządzeniu.

## Układ repozytorium

- `Sources/BubblePhysicsPublic`, `Sources/BubblePhysicsRuntime`, `Sources/BubblePhysicsNativeMetal`, `Sources/BubblePhysicsMetalRender` — ścieżka produkcyjna.
- `Sources/BubblePhysicsReference` — referencyjny solver CPU i deterministyczne scenariusze benchmarków.
- `Sources/BubblePhysicsReferenceMetal` — referencyjny solver Newton/PCG na GPU (diagnostyczny).
- `Sources/BubblePhysics` (`BubblePhysicsLegacy`), `Sources/BubblePhysicsCore`, `Sources/BubblePhysicsMetal` — historyczne eksperymenty zachowane do porównań.
- `docs/benchmarks` — pomiary na urządzeniu i Macu; `docs/superpowers` — specyfikacje i plany implementacji.
