# BubblePhysics

`BubblePhysics` to pakiet Swift z silnikiem fizycznym GPU dla deformowalnych baniek 2D, sztywnych brył (wielokąty, koła, kapsuły), więzów, sensorów i pól sił. Działa na iOS 16+ i macOS 13+ (GPU Apple z Metal).

**Wersja 2.1.0.** Zmiany w kolejnych wydaniach opisuje [CHANGELOG.md](CHANGELOG.md). Wersja 2.0.0 zmieniła publiczne API względem 1.x, a przejście z `v1.0.0` opisuje [docs/MIGRATION-v2.md](docs/MIGRATION-v2.md). Integrację z `MTKView`, rejestrację zasobów, zapytania i zdarzenia opisuje [docs/integration-guide.md](docs/integration-guide.md).

## Produkty

| Produkt | Przeznaczenie |
|---|---|
| `BubblePhysics` | API gry: `BubbleWorld`, `WorldTransaction`, `WorldFrame`, typy modelu i diagnostyka. |
| `BubblePhysicsAssets` | `AssetRegistry`: rejestr tekstur gry (`CGImage` albo `MTLTexture`), czcionek (atlas SDF) i gotowych atlasów glifów dla naklejek, per urządzenie Metal; świat dostaje go przy tworzeniu. |
| `BubblePhysicsMetalRender` | Renderuje opublikowaną klatkę świata bezpośrednio z buforów GPU do command buffera aplikacji. |
| `BubblePhysicsBenchmarkSupport` | Wyłącznie moduły diagnostyczne (solvery referencyjne, historyczne eksperymenty). Nie są częścią API gry. |
| `BubblePhysicsReferenceBench` | Runner benchmarków dla macOS z linii poleceń. |

Produkty dla gry działają na backendzie `native-metal` (trwały stan na GPU, trwały cache kontaktów, solver XPBD/PBD Jacobi). Referencyjny solver CPU (`BubblePhysicsReference`) jest wyrocznią poprawności dla testów i benchmarków; nie jest fallbackiem `BubbleWorld` w czasie działania. Na ścieżce gry nie ma `ReferenceWorld`, a pamięć kontaktów rośnie jak O(n·k) zamiast O(n²); kernele kontroli zawierania baniek pozostają O(n²), co jest pomijalne do kilkuset baniek.

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

Aplikacja hosta iOS jest w `Benchmarks/iOS/BubblePhysicsBench` i ma jeden ekran, który uruchamia `PublicWorldStressBenchmark` (moduł i produkt `BubblePhysicsMetalRenderBenchmark`, poza rendererem gry) na wybranej scenie. Świat i renderer (`BubblePhysicsMetalRender`) działają w tym samym command bufferze co krok fizyki, a render idzie poza ekranem w natywnej rozdzielczości ekranu (`UIScreen.main.nativeBounds`):

| Scena | Skład | Bramka p95 |
|-------|-------|------------|
| `stress-300` | 300 baniek, cztery ściany, poruszający się trójkąt | 10,4568 ms |
| `mixed` | 200 baniek, 60 brył (wielokąty, koła, kapsuły), 10 więzów, belki kinematyczne | 10,4568 ms |
| `decals` | stress-300 z teksturą przyklejoną i naklejką tekstową na każdej bańce | 10,4568 ms |
| `acceptance` | `decals`, trójkąt kinematyczny z `KinematicDrive`, połowa baniek na warstwie 1; dwa materiały alfa | 16,67 ms |

Scena `acceptance` jest punktem odniesienia strażnika i podstawą trybu pojemności; kryterium urządzenia to pomiar pojemności, bez wymaganego minimum. Tryb pojemności („capacity” w aplikacji, `PublicWorldStressBenchmark.measureCapacity`), który podaje, ile baniek scena akceptacyjna mieści w 60 FPS:

- Poziomy to 100, 150, …, 400 baniek w stałej skali sceny `acceptance` (15 kolumn, szerokość obszaru 375, ten sam generator, więc pierwsze n baniek jest takie samo na każdym poziomie); cel renderu ma 1125 pikseli szerokości i ⌊2436·H/700⌋ wysokości, czyli od 920 do 3252 px, a poziom 300 to dokładnie scena `acceptance`. Każdy poziom ma 30 klatek rozgrzewki i 300 mierzonych w serii z renderem oraz serię bez renderu (fizyka GPU); serie podziału renderu są pominięte.
- Przed każdym poziomem pomiar czeka, aż `ProcessInfo.thermalState` wróci do `nominal`, najdłużej 10 minut (po przekroczeniu poziom jest mierzony mimo to, a raport notuje `cooldown_timeout=1`). Raport podaje czas czekania (`cooldown_s`) i najgorszy stan z klatek mierzonych obu serii (`thermal_worst`); poziom ze stanem `serious` albo `critical` jest nieważny (`valid=0`).
- Reguła pojemności: największy poziom, przy którym p95 pełnej klatki nie przekracza 16,67 ms na nim i na wszystkich niższych poziomach (`capacity=<n>`). Wszystkie te poziomy i pierwszy niezdający muszą być ważne, inaczej `capacity=undecided_thermal` i pomiar trzeba powtórzyć; poziom jest ważny tylko przy stanie termicznym `nominal` albo `fair` i przy zerach poprawności z następnego punktu. Gdy przy `capacity=undecided_thermal` `thermal_worst` to `nominal` albo `fair`, przyczyną jest licznik poprawności (nieudane klatki, wartości nieskończone, odczyty konturów, przepełnienie kandydatów, liczba baniek albo niepełna próbka), więc to błąd do zbadania, nie termika. Gdy zdają wszystkie, jest `capacity=>=400`, a gdy nie zdaje 100, `capacity=<100`. Pojemność nie ma wymaganego minimum.
- Na każdym poziomie liczniki `failed_frames`, `non_finite_frames`, `contour_cpu_readbacks` i `contact_candidate_overflow` mają być zerem, `bubbles=<n>` oznacza n baniek w każdej klatce (`bubbles=mismatch` to błąd), a obie serie muszą zebrać pełną liczbę klatek mierzonych (seria z nieudaną klatką jest ucinana). Naruszenie któregokolwiek z tych warunków daje `valid=0` (poziom nie wchodzi do reguły pojemności), a `max_candidates_per_object` ma być nie większe niż połowa `candidate_limit`.
- Raport trafia do schowka przez „Kopiuj raport”; zapisz go jako `docs/benchmarks/v2-iphone-x-capacity.md` z linią `Mierzony commit` w nagłówku. Wynik iPhone’a X z 2026-11-11: pojemność 150 — [raport](docs/benchmarks/v2-iphone-x-capacity.md).

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

- Punkt kontrolny po optymalizacjach CPU: p95 `21,7425 ms` przy progu `16,67 ms`; [raport](docs/benchmarks/v2-iphone-x-checkpoint-8.md). Prognoza strażnika dla zmierzonego commita `2c22f84`: `19,8663 ms`, błąd łączny względem pomiaru `-8,6%` (limit 10%, `PREDICTION_ERROR ... PASS`); składowe GPU zgadzają się z urządzeniem w granicach 1,5%, ale składowa CPU jest zaniżona o 30,6% (prognoza `4,89 ms`, urządzenie `7,05 ms`, rzeczywisty stosunek iPhone/Mac około 5,66 zamiast skalibrowanego 3,93), więc cel CPU ≤ 5,0 ms jest spełniony tylko w prognozie. Błąd łączny mieści się w limicie; etap 9 przekalibrował stosunek CPU na podstawie tego raportu (zadanie 92).
- Punkt kontrolny etapu 9: p95 `20,5663 ms`, próg niespełniony; [raport](docs/benchmarks/v2-iphone-x-checkpoint-9.md). Prognoza strażnika dla zmierzonego commita `c02571a` (kalibracja z punktu kontrolnego 8): `18,7811 ms`, błąd łączny `-8,7%` (limit 10%, `PREDICTION_ERROR ... PASS`); składowe: CPU `6,63 ms` wobec `6,47 ms` (+2,4%), fizyka GPU `5,82 ms` wobec `8,03 ms` (-27,5%), render GPU `6,33 ms` wobec `6,37 ms` (-0,7%). Fizyka GPU `8,0262 ms` przekracza budżet `6,0 ms`, co jest warunkiem stopu P-B-87 i czeka na decyzję właściciela; kodowanie `2,0140 ms` (< 2,42 ms) i wykonalność budżetu renderu 4,0 ms (czyszczenie `0,9313 ms`, wymagane cięcie `2,37 ms` to 43,6% części kandydatów, limit 50%) są spełnione. Nowa kalibracja (`docs/benchmarks/iphone-x-calibration.json`): `ratios.cpu` 5,968, `ratios.physics` 7,101. Z nową kalibracją (`ratios.cpu` 5,968, `ratios.physics` 7,101) strażnik na HEAD prognozuje fizykę GPU ≈ 8,02 ms i CPU ≈ 6,67 ms (`--check-prediction` na HEAD: `PREDICT p95=21.0629 cpu=6.6718 physics=8.0176`, błąd +2,4%, PASS), więc oba budżety 6,0 ms są niespełnione już w prognozie; ponowny pomiar sceny `acceptance` na HEAD (`PREDICT p95=20.9304 cpu=6.5535 physics=8.0034`, load averages 1,96 1,77 2,76 przed przebiegiem, średnia 15-minutowa powyżej progu 2, więc pomiar orientacyjny) potwierdza te wartości.

### Pomiar zastępczy na Macu

Strażnik wydajności mierzy na Macu te same sceny i prognozuje p95 iPhone'a X, więc optymalizacja nie czeka na każdy pomiar na urządzeniu. Uruchamia się go na bezczynnej maszynie (średnie obciążenie ≤ 2 w `uptime`):

```bash
swift run -c release BubblePhysicsPerfGuard                         # wszystkie sceny i skalowanie 600/300
swift run -c release BubblePhysicsPerfGuard --scene acceptance      # tylko scena akceptacyjna w 1125×2436
swift run -c release BubblePhysicsPerfGuard --scene acceptance --calibrate docs/benchmarks/<raport>.md
swift run -c release BubblePhysicsPerfGuard --scene acceptance --check-prediction docs/benchmarks/<raport>.md
```

Scena `acceptance` ma w `docs/benchmarks/perf-guard.json` punkt odniesienia i limit +10% jak pozostałe. Linia `STAGES` rozkłada klatkę na składowe (mediany p95 z przebiegów, w ms): `host_preparation`, `host_encoding`, `host_waiting`, `host_publication`, `host_non_gpu` (CPU poza GPU), `gpu` i `gpu_physics` (druga seria bez renderu). Raport z iPhone'a ma te same składowe w liniach `*_p95_ms`.

`--calibrate` czyta raport z iPhone'a (jego commit z nagłówka `Mierzony kod: ...` jest wymagany i musi być bieżącym commitem; raport bez commitu jest odrzucany) i zapisuje `docs/benchmarks/iphone-x-calibration.json`: składowe iPhone'a i Maca z jednego commitu, mnożniki `cpu` i `physics` oraz koszt renderu GPU iPhone'a. Gdy plik istnieje, strażnik wypisuje linię `PREDICT`:

```text
prognoza = CPU_skladowe + r_fiz · gpu_physics(Mac) + render_GPU(iPhone)
CPU_skladowe = Σ_i (iphone_i / mac_i) · mac_teraz_i,  i ∈ {przygotowanie, kodowanie, publikacja, reszta}
reszta = host_non_gpu − przygotowanie − kodowanie − publikacja   (oczekiwanie ponad GPU, nie mniej niż 0)
```

Każda składowa CPU ma własny mnożnik `iphone_i / mac_i` z pól `iphone` i `mac` pliku kalibracji. Gdy reszta Maca w kalibracji nie przekracza 0,1 ms (szum pomiaru, zła podstawa dzielnika), reszta dostaje mnożnik łączny `ratios.cpu = host_non_gpu(iPhone) / host_non_gpu(Mac)`; ten sam mnożnik zastępuje mnożnik składowej, której Mac nie ma do podzielenia. Linia `PREDICT_CPU` podaje składowe (`preparation`, `encoding`, `publication`, `waiting`), a `PREDICT` ich sumę jako `cpu=`.

Na commicie kalibracji prognoza równa się `host_non_gpu_p95_ms + gpu_p95_ms` raportu. Od etapu 9 prognoza nie ma własnego celu w milisekundach (`target=15.00` nie jest kryterium): budżety to CPU ≤ 6,0 ms, fizyka ≤ 6,0 ms i render ≤ 4,0 ms, a bramką jest p95 pełnej klatki ≤ 16,67 ms. `--check-prediction` porównuje prognozę z p95 nowego raportu z urządzenia, wypisuje `PREDICTION_ERROR` i kończy się kodem 1 przy błędzie większym niż 10%. Etap 9 kalibruje na nowo na punkcie kontrolnym 9 (raport z urządzenia z commitu po zadaniu 97), a kolejne kalibracje robi się po każdym pomiarze, który rozjedzie się z prognozą o ponad 10%.

Raport z punktu kontrolnego 9 musi mieć dwie dodatkowe linie podziału renderu, wypisywane tylko dla sceny akceptacyjnej: `gpu_render_clear_estimate_ms` (koszt samego czyszczenia celu renderu: czas GPU passa z samym czyszczeniem minus czas GPU fizyki) i `gpu_render_decals_estimate_ms` (udział naklejek: czas GPU pełnego renderu minus czas GPU renderu bez naklejek). Właściciel potrzebuje ich, by rozstrzygnąć wykonalność budżetu renderu 4,0 ms obok `gpu_render_estimate_ms`.

## Układ repozytorium

- `Sources/BubblePhysicsPublic`, `Sources/BubblePhysicsRuntime`, `Sources/BubblePhysicsNativeMetal`, `Sources/BubblePhysicsMetalRender` — ścieżka produkcyjna.
- `Sources/BubblePhysicsReference` — referencyjny solver CPU i deterministyczne scenariusze benchmarków.
- `Sources/BubblePhysicsReferenceMetal` — referencyjny solver Newton/PCG na GPU (diagnostyczny).
- `Sources/BubblePhysics` (`BubblePhysicsLegacy`), `Sources/BubblePhysicsCore`, `Sources/BubblePhysicsMetal` — historyczne eksperymenty zachowane do porównań.
- `Examples/BubblePhysicsShowcase` — przykładowa aplikacja iOS z `MTKView` i dwiema scenami (bańki; bryły z więzami); jej oznaczone regiony są blokami kodu w [docs/integration-guide.md](docs/integration-guide.md). Build bez podpisu: `xcodebuild -project Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj -scheme BubblePhysicsShowcase -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- `docs/benchmarks` — pomiary na urządzeniu i Macu; `docs/superpowers` — specyfikacje i plany implementacji.
