# BubblePhysics

`BubblePhysics` to pakiet Swift z silnikiem fizycznym GPU dla deformowalnych baniek 2D, sztywnych brył (wielokąty, koła, kapsuły), więzów, sensorów i pól sił. Działa na iOS 16+ i macOS 13+ (GPU Apple z Metal).

**Wersja 2.0.0** zmienia publiczne API względem 1.x. Przejście z `v1.0.0` opisuje [docs/MIGRATION-v2.md](docs/MIGRATION-v2.md), a integrację z `MTKView`, rejestrację zasobów, zapytania i zdarzenia [docs/integration-guide.md](docs/integration-guide.md).

## Produkty

| Produkt | Przeznaczenie |
|---|---|
| `BubblePhysics` | API gry: `BubbleWorld`, `WorldTransaction`, `WorldFrame`, typy modelu i diagnostyka. |
| `BubblePhysicsAssets` | `AssetRegistry`: rejestr tekstur gry (`CGImage` albo `MTLTexture`), czcionek (atlas SDF) i gotowych atlasów glifów dla naklejek, per urządzenie Metal; świat dostaje go przy tworzeniu. |
| `BubblePhysicsMetalRender` | Renderuje opublikowaną klatkę świata bezpośrednio z buforów GPU do command buffera aplikacji. |
| `BubblePhysicsBenchmarkSupport` | Wyłącznie moduły diagnostyczne (solvery referencyjne, historyczne eksperymenty). Nie są częścią API gry. |
| `BubblePhysicsReferenceBench` | Runner benchmarków dla macOS z linii poleceń. |

Produkty dla gry działają na backendzie `native-metal` (trwały stan na GPU, trwały cache kontaktów, solver XPBD/PBD Jacobi). Referencyjny solver CPU (`BubblePhysicsReference`) jest wyrocznią poprawności dla testów i benchmarków; nie jest fallbackiem `BubbleWorld` w czasie działania.

## Szybki start

```swift
import BubblePhysics
import BubblePhysicsAssets
import BubblePhysicsMetalRender
import Metal

let configuration = try WorldConfiguration(
    simulationRegion: WorldRectangle(min: [0, 0], max: [375, 700]),
    fixedTimeStep: 1.0 / 60)
let world = try BubbleWorld(configuration: configuration)

// Tekstury rejestruje się synchronicznie, poza klatką; transakcje wskazują je przez `TextureID`.
// Świat bez własnego rejestru ma pusty rejestr swojego urządzenia: `world.assets`.
let texture = try world.assets!.register(cgImage)   // `CGImage` albo gotowa `MTLTexture`

let material = PhysicsMaterialID(rawValue: 1)
let look = RenderMaterialID(rawValue: 1)
world.submit(WorldTransaction()
    .updatePhysicsMaterial(material, material: try PhysicsMaterial(kind: .bubble))
    .updateRenderMaterial(look, material: try RenderMaterial(texture: texture, color: RGBA(1, 0.8, 0.9, 1)))
    .add(.bubble(try BubbleDescriptor(id: ObjectID(rawValue: 1), position: [187, 350],
                                      targetRadius: 20, mass: 8,
                                      physicsMaterialID: material, renderMaterialID: look))))

// Sam krok fizyki:
let frame = await world.advance(by: 1.0 / 60)
for event in frame.events { /* merge, wejście/wyjście z sensora, wyjście z regionu, ... */ }

// Fizyka i render w jednym command bufferze:
let renderer = try BubblePhysicsMetalRender(device: device, assets: world.assets!)
let rendered = await world.advance(by: 1.0 / 60, commandBuffer: commandBuffer) {
    try renderer.encode(world: world, viewport: Viewport(center: [187.5, 350], size: [375, 700]),
                        commandBuffer: commandBuffer, renderPassDescriptor: passDescriptor)
}
// Drawable prezentuj tylko wtedy, gdy `world.diagnostics.didRenderLastAdvance` jest prawdą.
```

`BubbleWorld` jest `@MainActor`. Każda zmiana świata przechodzi przez atomową `WorldTransaction` (dodanie/usunięcie/zamiana obiektów, materiały fizyki i renderu, warstwy i tło, role ruchu, napędy ścieżki/silnika/gracza, siła globalna, impulsy, przejścia parametrów, łączenie i dzielenie baniek, zamiana wielokątów). Każda `WorldFrame` zawiera potwierdzenia transakcji, zdarzenia opt-in, informację o przepełnieniu zdarzeń i feedback napędów.

## Zachowanie w czasie działania, o którym warto wiedzieć

- Czas płynie stałymi krokami. `advance(by:commandBuffer:encodeRender:)` wykonuje najwyżej jeden krok na command buffer; reszta czasu zostaje w `world.diagnostics.backlogSeconds`. Gdy czas nie wystarcza na krok (np. ekran 120 Hz przy kroku 1/60), `advance` i tak woła `encodeRender`, zatwierdza bufor i rysuje opublikowany stan z interpolacją między krokami t−1 i t; nic nie jest wtedy publikowane. Pauza, stan „zawiódł” i odrzucona klatka nie zatwierdzają bufora (`didRenderLastAdvance == false`). Gdy aplikacja przechodzi w tło, świat pauzuje sam (`WorldConfiguration.automaticPause`, domyślnie włączone; na iOS według powiadomień UIKit, własne źródło podaje parametr `lifecycle:` inicjalizatora): `advance` zwraca ostatnią klatkę, nie rysuje i nie zatwierdza bufora, a po powrocie pierwszy przyrost czasu jest odrzucany. Pauza automatyczna jest niezależna od `pause()` i `resume()`. Zaległy czas ma górny limit `WorldConfiguration.maximumBacklog` (domyślnie 0,25 s): nadmiar jest odrzucany, a jego sumę podaje `world.diagnostics.discardedBacklogSeconds`.
- Błąd w kroku ma trzy skutki. Błąd wykonania bufora na GPU albo wartości nieskończone (NaN, ±∞) przełączają świat w stan końcowy „zawiódł” (`diagnostics.failureReason`): kolejka transakcji jest porzucana, a `advance` i `submit` nic nie robią i zwracają ostatnią klatkę (`lastAdvanceIssue = .worldFailed`); dalej prowadzi tylko nowy `BubbleWorld`. Błąd zgłoszony przez domknięcie `encodeRender` albo kodowanie renderu odrzuca tylko klatkę (`lastAdvanceIssue = .frameRejected`): krok nie jest publikowany, poprzednia klatka zostaje, kolejka czeka na następne `advance`. Inne błędy solvera (naruszenie strażnika, niepoprawna klatka, wartość skończona poza zakresem) odrzucają krok (`lastAdvanceIssue = .stepFailed`, powód w `diagnostics.lastRejectionReason`) i też zachowują kolejkę. Ścieżka gry nie ma fallbacku CPU.
- Stan obiektów (pozycja, prędkość, obrót, AABB) czyta się z `WorldFrame.objects` bez odczytu z GPU; renderer czyta kontury bezpośrednio z buforów GPU, a `DriveFeedback` podaje osiągnięty punkt obiektów sterowanych.
- Tekstury mają alfę przemnożoną (premultiplied alpha). `register(_: CGImage)` przemnaża obraz sam (dekoduje do `rgba8Unorm` w sRGB), a `register(_: MTLTexture)` przyjmuje bajty bez zmian, więc gotowa tekstura musi już mieć RGB pomnożone przez alfę; akceptowane są formaty `rgba8Unorm` i `bgra8Unorm` (warianty `_srgb` są odrzucane, bo potok liczy w przestrzeni celu renderu bez konwersji liniowej). Przesunięcie i skala UV materiału (`uvOffset`, `uvScale`) dotyczą tylko brył, na bańkach są ignorowane.
- `debugContourSnapshot()` kopiuje kontury na CPU i służy wyłącznie do debugowania.

## Testy

```bash
swift build --build-tests
swift test
```

Testy Metal działają na macOS z lokalnym GPU. Źródła shaderów są dołączone jako pliki `.metal-source` i kompilowane w czasie działania, raz na `MTLDevice`. `NativeMetalShaderABITests` sprawdza, czy rekordy buforów w Swift odpowiadają układowi struktur wygenerowanemu przez kompilator Metal.

## Benchmark na urządzeniu

Aplikacja hosta iOS jest w `Benchmarks/iOS/BubblePhysicsBench` i ma jeden ekran, który uruchamia `PublicWorldStressBenchmark` na wybranej scenie. Świat i renderer (`BubblePhysicsMetalRender`) działają w tym samym command bufferze co krok fizyki, a render idzie poza ekranem w natywnej rozdzielczości ekranu (`UIScreen.main.nativeBounds`):

| Scena | Skład | Bramka p95 |
|-------|-------|------------|
| `stress-300` | 300 baniek, cztery ściany, poruszający się trójkąt | 10,4568 ms |
| `mixed` | 200 baniek, 60 brył (wielokąty, koła, kapsuły), 10 więzów, belki kinematyczne | 10,4568 ms |
| `decals` | stress-300 z teksturą przyklejoną i naklejką tekstową na każdej bańce | 10,4568 ms |
| `acceptance` | `decals`, trójkąt kinematyczny z `KinematicDrive`, połowa baniek na warstwie 1; dwa materiały alfa | 16,67 ms |

Wynik akceptacyjny wydania to scena `acceptance`.

1. Skopiuj `Benchmarks/iOS/BubblePhysicsBench/Signing.local.xcconfig.example` do `Signing.local.xcconfig` (ignorowany przez git) i ustaw swój `DEVELOPMENT_TEAM` oraz bundle identifier.
2. Otwórz `BubblePhysicsBench.xcodeproj`, wybierz fizyczny iPhone i uruchom konfigurację Release.
3. Użyj „Kopiuj raport” i zapisz surowy wynik w `docs/benchmarks/`.

Build kontrolny bez podpisu:

```bash
xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj \
  -scheme BubblePhysicsBench -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Bramka sceny akceptacyjnej to p95 pełnej klatki nie większe niż 16,67 ms (`PublicWorldStressBenchmark.acceptanceGateMilliseconds`) na iPhonie X w natywnej rozdzielczości, przy zerze nieudanych klatek, zerze klatek `non-finite`, bez readbacku konturów na CPU, z zerem przepełnień kandydatów kontaktu i z największą liczbą kandydatów na obiekt nie większą niż połowa limitu (`candidate_limit`). Pozostałe sceny mają bramkę `PublicWorldStressBenchmark.p95GateMilliseconds` (10,4568 ms). Raport wypisuje bramkę jako `p95_gate_ms`, rozmiar celu jako `render_px`, a liczniki kandydatów w linii `contact_candidate_overflow`. Ponowny pomiar sceny `acceptance` na iPhonie X z 2026-11-10 przy renderze `1125×2436`: p95 `24,2744 ms`, bramka `16,67 ms` niespełniona; jakość `native_quality_envelope` nie została oceniona. Pełny wynik: [v2-iphone-x-2026-11-10-retest.md](docs/benchmarks/v2-iphone-x-2026-11-10-retest.md).

## Układ repozytorium

- `Sources/BubblePhysicsPublic`, `Sources/BubblePhysicsRuntime`, `Sources/BubblePhysicsNativeMetal`, `Sources/BubblePhysicsMetalRender` — ścieżka produkcyjna.
- `Sources/BubblePhysicsReference` — referencyjny solver CPU i deterministyczne scenariusze benchmarków.
- `Sources/BubblePhysicsReferenceMetal` — referencyjny solver Newton/PCG na GPU (diagnostyczny).
- `Sources/BubblePhysics` (`BubblePhysicsLegacy`), `Sources/BubblePhysicsCore`, `Sources/BubblePhysicsMetal` — historyczne eksperymenty zachowane do porównań.
- `Examples/BubblePhysicsShowcase` — przykładowa aplikacja iOS z `MTKView` i dwiema scenami (bańki; bryły z więzami); jej oznaczone regiony są blokami kodu w [docs/integration-guide.md](docs/integration-guide.md). Build bez podpisu: `xcodebuild -project Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj -scheme BubblePhysicsShowcase -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- `docs/benchmarks` — pomiary na urządzeniu i Macu; `docs/superpowers` — specyfikacje i plany implementacji.
