# Contact Envelope Reference Solver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zbudować deterministyczny solver CPU i benchmark iOS dla baniek reprezentowanych przez środki, kierunkową deformację i sztywne odcinki.

**Architecture:** Nowy target `BubblePhysicsReference` powstaje obok dotychczasowych solverów i nie używa ich dynamicznych punktów powierzchni. Sekwencyjny solver XPBD utrzymuje trwały zbiór kontaktów, wyznacza tylko kierunkowe promienie potrzebne kontaktom, a pełny kontur generuje po osiągnięciu równowagi. Wymienne implementacje broad phase są sprawdzane względem brute force, a wspólny runner udostępnia deterministyczne sceny testom i aplikacji iOS.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, simd, SwiftUI dla istniejącego hosta iOS.

**Spec:** `docs/superpowers/specs/2026-10-02-bubble-physics-contact-envelope-design.md`

## Global Constraints

- Platformy pozostają na poziomie iOS 16 i macOS 13.
- Target referencyjny nie zależy od Metala, SwiftUI, SpriteKit ani starego targetu `BubblePhysics`.
- CPU jest wzorcem poprawności; nie ma twardego progu czasu klatki.
- Pełna klatka przyszłego backendu Metal dla 300 baniek na iPhonie X ma osiągnąć `p95 <= 16,67 ms`.
- Pełny kontur nie uczestniczy w broad phase, CCD ani iteracjach równowagi.
- Sztywne odcinki są ograniczeniami bezwzględnymi i nie przemieszczają się pod naciskiem.
- Każda pętla iteracyjna ma jawny limit i raportuje jego osiągnięcie.
- Nie wprowadzamy maksymalnego `N`; liczba punktów konturu wynika z promienia i `maxContourSegmentLength`.
- Pierwszy kamień milowy nie obejmuje łączenia, dzielenia, chwytu, renderera gry ani reguł `2KBubbles`.

## Review Focus

- Zerowej długości odcinek `A == B` ma zachowywać się jak punkt, bez dzielenia przez zero; test należy do Task 3.
- Zbieżne środki dwóch baniek muszą otrzymać deterministyczną normalną i skończony wynik; test należy do Task 3.
- Szybki, obracający się odcinek nie może zmienić dozwolonej strony środka bez kontaktu; test należy do Task 4.
- Kontakt nie może oscylować między stanem aktywnym i nieaktywnym przy błędzie numerycznym wokół zera; test należy do Task 6.
- Bańka większa od planszy musi zakończyć krok w skończonym stanie i w limicie iteracji, mimo braku rozwiązania bez kompresji; test należy do Task 7.

---

## Mapa plików

Nowy kod jest izolowany w `Sources/BubblePhysicsReference`:

```text
Model/          wartości, konfiguracja, stan bańki, odcinka i kontaktu
Geometry/       najbliższy punkt, AABB, promień kierunkowy i kontur
CCD/            czas pierwszego kontaktu baniek i odcinków
BroadPhase/     wspólny protokół, brute force, sweep-and-prune i drzewo AABB
Solver/         aktywny zbiór kontaktów, XPBD i pełny krok świata
Benchmark/      scenariusze, pomiary oraz raport
```

Testy odwzorowują te odpowiedzialności w `Tests/BubblePhysicsReferenceTests`.
Istniejący host iOS otrzymuje oddzielny ekran uruchamiający ten sam runner.

### Task 1: Izolowany target i podstawowy model danych

**Files:**
- Modify: `Package.swift`
- Create: `Sources/BubblePhysicsReference/Model/ReferenceVector2.swift`
- Create: `Sources/BubblePhysicsReference/Model/ReferenceAABB.swift`
- Create: `Sources/BubblePhysicsReference/Model/ReferenceConfiguration.swift`
- Create: `Sources/BubblePhysicsReference/Model/ReferenceBubble.swift`
- Create: `Sources/BubblePhysicsReference/Model/ReferenceSegment.swift`
- Create: `Sources/BubblePhysicsReference/Model/ReferenceContact.swift`
- Create: `Tests/BubblePhysicsReferenceTests/ReferenceModelTests.swift`

**Interfaces:**
- Produces: `ReferenceVector2`, `ReferenceAABB`, `ReferenceConfiguration`, `ReferenceBubble`, `ReferenceSegment`, `ReferenceContact`, `ReferenceContactID`.
- Produces: produkt i target `BubblePhysicsReference` oraz target testowy `BubblePhysicsReferenceTests`.

- [ ] **Step 1: Dodać test kompilacji i niezmienników modelu**

Testy `testBubbleRejectsNonPositiveMassAndRadius()`, `testStaticSegmentKeepsPreviousAndCurrentEndpoints()` oraz `testDefaultConfigurationHasFinitePositiveBudgets()` mają sprawdzać walidację inicjalizatorów i skończone wartości domyślne.

- [ ] **Step 2: Uruchomić test i potwierdzić brak targetu**

Run: `swift test --filter BubblePhysicsReferenceTests.ReferenceModelTests`

Expected: FAIL, ponieważ target lub typy jeszcze nie istnieją.

- [ ] **Step 3: Dodać target oraz typy wartościowe**

W `Package.swift` dodać niezależny produkt/target `BubblePhysicsReference` i jego testy. Zaimplementować `ReferenceVector2` z arytmetyką, iloczynem skalarnym, długością i bezpieczną normalizacją oraz następujące publiczne modele:

```swift
public struct ReferenceConfiguration: Sendable, Equatable
public struct ReferenceBubble: Sendable, Equatable
public struct ReferenceSegment: Sendable, Equatable
public struct ReferenceContact: Sendable, Equatable
```

Konfiguracja zawiera `timeStep`, `solverIterations` domyślnie 12, tolerancje kontaktu, podatność, nieliniowe usztywnienie, tłumienie liniowe i kątowe, tarcie powierzchni, budżet TOI i `maxContourSegmentLength`.

- [ ] **Step 4: Uruchomić testy modelu i cały pakiet**

Run: `swift test --filter BubblePhysicsReferenceTests.ReferenceModelTests && swift test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/BubblePhysicsReference Tests/BubblePhysicsReferenceTests/ReferenceModelTests.swift
git commit -m "feat: add reference bubble physics model"
```

### Task 2: Kierunkowa deformacja i końcowy kontur

**Files:**
- Create: `Sources/BubblePhysicsReference/Geometry/DirectionalDeformation.swift`
- Create: `Sources/BubblePhysicsReference/Geometry/SupportRadius.swift`
- Create: `Sources/BubblePhysicsReference/Geometry/ContourGenerator.swift`
- Create: `Tests/BubblePhysicsReferenceTests/SupportRadiusTests.swift`
- Create: `Tests/BubblePhysicsReferenceTests/ContourGeneratorTests.swift`

**Interfaces:**
- Consumes: `ReferenceVector2`, `ReferenceBubble`, `ReferenceConfiguration`, `ReferenceContactID` z Task 1.
- Produces: `DirectionalDeformation`, `ReferenceBubble.supportRadius(along:)`, `ReferenceContourGenerator.points(for:configuration:)`.

- [ ] **Step 1: Napisać testy promienia kierunkowego**

Testy mają dowodzić, że brak kontaktów zwraca `targetRadius`, pojedynczy kontakt daje największe wgniecenie na swojej normalnej, wpływ maleje gładko do zera poza `angularWidth`, a złożenie dwóch kontaktów nigdy nie zwraca wartości ujemnej ani `NaN`.

- [ ] **Step 2: Uruchomić testy i potwierdzić brak implementacji**

Run: `swift test --filter BubblePhysicsReferenceTests.SupportRadiusTests`

Expected: FAIL z powodu brakujących typów lub metod.

- [ ] **Step 3: Zaimplementować deformację i `supportRadius`**

Użyć gładkiej funkcji `smoothstep` dla wpływu kątowego. Minimalny promień fizyczny ma wynosić `0`, bez sztucznego dodatniego ograniczenia. Nieliniowy opór jest parametrem solvera, a nie zaciskiem geometrii.

- [ ] **Step 4: Napisać testy generowania konturu**

Testy `testAdaptiveContourKeepsEverySegmentWithinConfiguredLength()`, `testCompressedBubbleUsesFewerPointsThanUncompressedBubble()` i `testContourSamplesSupportRadiusOnlyAfterSolve()` mają sprawdzić maksymalną długość każdego odcinka, brak górnego limitu `N` oraz zgodność każdego punktu z `supportRadius`.

- [ ] **Step 5: Zaimplementować adaptacyjny `ReferenceContourGenerator` i uruchomić testy**

Generator rozpoczyna od ośmiu kierunków i deterministycznie dzieli łuk na pół, dopóki odpowiadająca mu cięciwa przekracza `maxContourSegmentLength`. Podział odbywa się wyłącznie po zakończeniu solvera i nie zmienia stanu fizycznego.

Run: `swift test --filter BubblePhysicsReferenceTests.SupportRadiusTests && swift test --filter BubblePhysicsReferenceTests.ContourGeneratorTests`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/BubblePhysicsReference/Geometry Tests/BubblePhysicsReferenceTests/SupportRadiusTests.swift Tests/BubblePhysicsReferenceTests/ContourGeneratorTests.swift
git commit -m "feat: add directional bubble envelope"
```

### Task 3: Dyskretna geometria kontaktów

**Files:**
- Create: `Sources/BubblePhysicsReference/Geometry/ClosestPointOnSegment.swift`
- Create: `Sources/BubblePhysicsReference/Geometry/DiscreteContactGenerator.swift`
- Create: `Tests/BubblePhysicsReferenceTests/ClosestPointOnSegmentTests.swift`
- Create: `Tests/BubblePhysicsReferenceTests/DiscreteContactGeneratorTests.swift`

**Interfaces:**
- Consumes: modele z Task 1 i `supportRadius(along:)` z Task 2.
- Produces: `closestPoint(to:on:) -> ClosestPointResult`.
- Produces: `ReferenceDiscreteContactGenerator.bubbleBubble(_:_:)` oraz `.bubbleSegment(_:_:allowedSide:)`.

- [ ] **Step 1: Napisać testy najbliższego punktu `Q`**

Sprawdzić rzut wewnątrz odcinka, `Q == A`, `Q == B` oraz zerową długość `A == B`. Wynik zawiera `point`, zaciśnięte `t` i kwadrat odległości.

- [ ] **Step 2: Uruchomić testy i potwierdzić brak implementacji**

Run: `swift test --filter BubblePhysicsReferenceTests.ClosestPointOnSegmentTests`

Expected: FAIL.

- [ ] **Step 3: Zaimplementować pojedyncze obliczenie `Q`**

Sygnatura:

```swift
public func closestPoint(
    to point: ReferenceVector2,
    on segment: ReferenceSegmentEndpoints
) -> ClosestPointResult
```

Dla `A == B` zwrócić `A`, `t == 0` i skończoną odległość.

- [ ] **Step 4: Napisać testy kontaktów dyskretnych**

Sprawdzić jeden kontakt na parę baniek, brak pozornego kontaktu po kierunkowym wgnieceniu, kontakt z wnętrzem i końcem odcinka oraz deterministyczną normalną dla zbieżnych środków.

- [ ] **Step 5: Zaimplementować generatory i uruchomić testy**

Run: `swift test --filter BubblePhysicsReferenceTests.ClosestPointOnSegmentTests && swift test --filter BubblePhysicsReferenceTests.DiscreteContactGeneratorTests`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/BubblePhysicsReference/Geometry Tests/BubblePhysicsReferenceTests/ClosestPointOnSegmentTests.swift Tests/BubblePhysicsReferenceTests/DiscreteContactGeneratorTests.swift
git commit -m "feat: add reference discrete contacts"
```

### Task 4: Ciągłe wykrywanie kolizji

**Files:**
- Create: `Sources/BubblePhysicsReference/CCD/TimeOfImpact.swift`
- Create: `Sources/BubblePhysicsReference/CCD/BubbleBubbleTOI.swift`
- Create: `Sources/BubblePhysicsReference/CCD/BubbleSegmentTOI.swift`
- Create: `Tests/BubblePhysicsReferenceTests/BubbleBubbleTOITests.swift`
- Create: `Tests/BubblePhysicsReferenceTests/BubbleSegmentTOITests.swift`

**Interfaces:**
- Consumes: modele i geometria z Tasks 1–3.
- Produces: `TimeOfImpactResult` z przypadkami `.none`, `.initialOverlap`, `.impact(fraction:normal:point:)`.
- Produces: `ReferenceCCD.bubbleBubble(...)` i `ReferenceCCD.bubbleSegment(...)`.

- [ ] **Step 1: Napisać testy TOI dwóch baniek**

Testy obejmują ruch ku sobie, ruch równoległy bez zderzenia, początkową penetrację i dwa poruszające się środki. Ułamek czasu kontaktu ma być sprawdzony z tolerancją `1e-5`.

- [ ] **Step 2: Uruchomić testy i potwierdzić brak implementacji**

Run: `swift test --filter BubblePhysicsReferenceTests.BubbleBubbleTOITests`

Expected: FAIL.

- [ ] **Step 3: Zaimplementować względny ruch i równanie kwadratowe**

Promienie podparcia na potrzeby TOI są zamrożone na wartości z początku badanego podkroku; deformacja jest ponownie oceniana po utworzeniu kontaktu.

- [ ] **Step 4: Napisać testy TOI bańka–odcinek**

Sprawdzić translację względem środka i końca kapsuły, ruch obu uczestników, obrót odcinka oraz przypadek, w którym koniec odcinka w jednym kroku zmienia stronę środka. Test obrotu wymaga kontaktu lub jawnej korekty strony, nigdy cichego przejścia.

- [ ] **Step 5: Zaimplementować kapsułę i conservative advancement**

Translacja używa najwcześniejszego poprawnego wyniku części liniowej i dwóch okręgów końcowych. Obrót używa maksymalnie `configuration.toiIterationBudget` kroków conservative advancement oraz zwraca flagę wyczerpania budżetu.

- [ ] **Step 6: Uruchomić testy CCD i cały pakiet**

Run: `swift test --filter BubblePhysicsReferenceTests.BubbleBubbleTOITests && swift test --filter BubblePhysicsReferenceTests.BubbleSegmentTOITests && swift test`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/BubblePhysicsReference/CCD Tests/BubblePhysicsReferenceTests/BubbleBubbleTOITests.swift Tests/BubblePhysicsReferenceTests/BubbleSegmentTOITests.swift
git commit -m "feat: add continuous reference contacts"
```

### Task 5: Wymienny broad phase dla różnych skal

**Files:**
- Create: `Sources/BubblePhysicsReference/BroadPhase/ReferenceBroadPhase.swift`
- Create: `Sources/BubblePhysicsReference/BroadPhase/BruteForceBroadPhase.swift`
- Create: `Sources/BubblePhysicsReference/BroadPhase/SweepAndPruneBroadPhase.swift`
- Create: `Sources/BubblePhysicsReference/BroadPhase/AABBTreeBroadPhase.swift`
- Create: `Tests/BubblePhysicsReferenceTests/ReferenceBroadPhaseTests.swift`

**Interfaces:**
- Consumes: `ReferenceAABB`, identyfikatory i przewidywane stany z Task 1.
- Produces: `ReferenceBroadPhase` z `mutating func candidatePairs(for proxies: [ReferenceProxy]) -> [ReferencePair]`.
- Produces: trzy implementacje zwracające uporządkowane, unikalne pary.

- [ ] **Step 1: Napisać wspólny zestaw testów zgodności**

Dla każdej implementacji porównać wynik z brute force w scenach: pusta, jeden obiekt, identyczne AABB, obiekt większy od planszy, 300 mieszanych rozmiarów oraz deterministycznie poruszane proxy. Test musi wykrywać brakujące i powielone pary.

- [ ] **Step 2: Uruchomić testy i potwierdzić brak implementacji**

Run: `swift test --filter BubblePhysicsReferenceTests.ReferenceBroadPhaseTests`

Expected: FAIL.

- [ ] **Step 3: Zaimplementować brute force i sweep-and-prune**

Sweep-and-prune utrzymuje stabilnie uporządkowaną listę `minX`; przecięcie osi Y jest drugim testem. Kolejność wyniku jest niezależna od kolejności wejścia.

- [ ] **Step 4: Zaimplementować drzewo AABB**

Pierwsza wersja przebudowuje zbalansowane drzewo medianowym podziałem po dłuższej osi. Nie implementować jeszcze złożonych rotacji dynamicznego drzewa; pomiar zdecyduje o dalszej inwestycji.

- [ ] **Step 5: Uruchomić testy zgodności i cały pakiet**

Run: `swift test --filter BubblePhysicsReferenceTests.ReferenceBroadPhaseTests && swift test`

Expected: PASS, wszystkie indeksy zwracają te same pary co brute force.

- [ ] **Step 6: Commit**

```bash
git add Sources/BubblePhysicsReference/BroadPhase Tests/BubblePhysicsReferenceTests/ReferenceBroadPhaseTests.swift
git commit -m "feat: add scalable reference broad phases"
```

### Task 6: Trwały zbiór kontaktów i solver równowagi

**Files:**
- Create: `Sources/BubblePhysicsReference/Solver/ReferenceContactSet.swift`
- Create: `Sources/BubblePhysicsReference/Solver/ReferenceEquilibriumSolver.swift`
- Create: `Sources/BubblePhysicsReference/Solver/ReferenceSolverReport.swift`
- Create: `Tests/BubblePhysicsReferenceTests/ReferenceContactSetTests.swift`
- Create: `Tests/BubblePhysicsReferenceTests/ReferenceEquilibriumSolverTests.swift`

**Interfaces:**
- Consumes: kontakty z Task 3, TOI z Task 4 i pary z Task 5.
- Produces: `ReferenceContactSet.update(candidates:bubbles:segments:configuration:)`.
- Produces: `ReferenceEquilibriumSolver.solve(bubbles:segments:contacts:configuration:) -> ReferenceSolverReport`.

- [ ] **Step 1: Napisać testy trwałości i histerezy kontaktów**

Sprawdzić zachowanie `ContactID`, aktywację powyżej tolerancji, utrzymanie przy szumie wokół zera, usunięcie dopiero po przekroczeniu tolerancji rozłączenia oraz stabilną kolejność niezależną od wejścia.

- [ ] **Step 2: Uruchomić testy i potwierdzić brak implementacji**

Run: `swift test --filter BubblePhysicsReferenceTests.ReferenceContactSetTests`

Expected: FAIL.

- [ ] **Step 3: Zaimplementować `ReferenceContactSet`**

Kontakty mają być indeksowane przez uporządkowane identyfikatory uczestników i rodzaj powierzchni. Aktualizacja nie może alokować rekordu dla każdego punktu konturu.

- [ ] **Step 4: Napisać testy solvera pozycyjnego**

Testy obejmują symetryczny podział dla równych mas, większy ruch lżejszej bańki, nieruchomy odcinek, łańcuch trzech baniek, bańkę dociskaną do ściany, konwersję niedostępnej korekty na kierunkową deformację oraz ograniczone przekazanie prędkości stycznej i obrotu przez poruszający się odcinek.

- [ ] **Step 5: Zaimplementować sekwencyjny solver XPBD**

Każda iteracja rozwiązuje odcinki, pary baniek, ponownie odcinki, aktualizuje deformacje i aktywny zbiór. Efektywna podatność deformacji maleje wraz z kwadratem stosunku `depth / targetRadius`, co daje rosnący opór. Po korekcie normalnej ograniczone tarcie powierzchni przenosi część prędkości stycznej na prędkość liniową i kątową bańki; nie może dodać więcej energii niż wynika z względnego ruchu powierzchni. Solver kończy po zbieżności albo dokładnie przy `solverIterations` i raportuje przyczynę.

- [ ] **Step 6: Uruchomić testy solvera i cały pakiet**

Run: `swift test --filter BubblePhysicsReferenceTests.ReferenceContactSetTests && swift test --filter BubblePhysicsReferenceTests.ReferenceEquilibriumSolverTests && swift test`

Expected: PASS; wszystkie pozycje, prędkości zastępcze i deformacje są skończone.

- [ ] **Step 7: Commit**

```bash
git add Sources/BubblePhysicsReference/Solver Tests/BubblePhysicsReferenceTests/ReferenceContactSetTests.swift Tests/BubblePhysicsReferenceTests/ReferenceEquilibriumSolverTests.swift
git commit -m "feat: solve reference contact equilibrium"
```

### Task 7: Kompletny krok świata

**Files:**
- Create: `Sources/BubblePhysicsReference/Solver/ReferenceWorld.swift`
- Create: `Sources/BubblePhysicsReference/Solver/ReferenceWorldStepReport.swift`
- Create: `Tests/BubblePhysicsReferenceTests/ReferenceWorldTests.swift`

**Interfaces:**
- Consumes: wszystkie komponenty z Tasks 1–6.
- Produces: `ReferenceWorld.init(configuration:broadPhase:)`, `addBubble`, `addSegment`, `updateSegment`, `step() -> ReferenceWorldStepReport`, `contour(for:)`.

- [ ] **Step 1: Napisać testy kompletnego kroku**

Testy obejmują deterministyczne odtworzenie 600 kroków, przeniesienie prędkości ruchomego odcinka, zachowanie dozwolonej strony, opór swobodnego ruchu i brak nieograniczonego wzrostu pamięci kontaktów.

- [ ] **Step 2: Dodać przypadki graniczne świata**

Test `testBubbleLargerThanBoardCompressesAndStopsWithinIterationBudget()` ma umieścić bańkę większą od planszy między czterema ścianami i sprawdzić skończony stan, deformacje z czterech stron oraz zakończenie nie później niż po 12 iteracjach. Dodać również test szybkiego obracającego się odcinka bez zmiany zabronionej strony.

- [ ] **Step 3: Uruchomić testy i potwierdzić brak implementacji**

Run: `swift test --filter BubblePhysicsReferenceTests.ReferenceWorldTests`

Expected: FAIL.

- [ ] **Step 4: Zaimplementować pełną kolejność kroku**

`step()` wykonuje: polecenia, przewidywanie, broad phase, CCD, aktualizację kontaktów, solver, nowe prędkości, tłumienie i raport. Kontur jest generowany dopiero przez `contour(for:)` po zakończeniu kroku.

- [ ] **Step 5: Uruchomić testy świata i cały pakiet**

Run: `swift test --filter BubblePhysicsReferenceTests.ReferenceWorldTests && swift test`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/BubblePhysicsReference/Solver/ReferenceWorld.swift Sources/BubblePhysicsReference/Solver/ReferenceWorldStepReport.swift Tests/BubblePhysicsReferenceTests/ReferenceWorldTests.swift
git commit -m "feat: add reference bubble world step"
```

### Task 8: Deterministyczne scenariusze i benchmark CPU

**Files:**
- Create: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkScenario.swift`
- Create: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkRunner.swift`
- Create: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkReport.swift`
- Create: `Tests/BubblePhysicsReferenceTests/ReferenceBenchmarkTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `ReferenceWorld` i raport kroku z Task 7.
- Produces: `ReferenceBenchmarkScenario`, `ReferenceBenchmarkRunner.measure(scenario:warmupSteps:measuredSteps:)`, `ReferenceBenchmarkReport`.

- [ ] **Step 1: Napisać testy konstrukcji scenariuszy**

Sprawdzić sceny: dwie bańki, łańcuch, szybki odcinek, obracający odcinek, trójkąt, wielka bańka, mieszane rozmiary oraz pełne plansze 40/300/1000. Każda scena ma mieć stałe ziarno, identyczny stan przy ponownej konstrukcji i oczekiwaną liczbę obiektów.

- [ ] **Step 2: Uruchomić testy i potwierdzić brak implementacji**

Run: `swift test --filter BubblePhysicsReferenceTests.ReferenceBenchmarkTests`

Expected: FAIL.

- [ ] **Step 3: Zaimplementować scenariusze, pomiary i raport**

Raport zawiera p50/p95 całego kroku i faz, liczbę kandydatów, kontaktów, iteracji, testów TOI, największą penetrację, korekty strony, przekroczenia budżetów i szczytową liczbę trwałych kontaktów. Zegar używa `ContinuousClock`; warmup nie wchodzi do percentyli.

- [ ] **Step 4: Dodać porównanie broad phase**

Runner uruchamia identyczne sceny 300 i 1000 dla sweep-and-prune oraz drzewa AABB, potwierdza zgodną liczbę par i raportuje koszt obu wariantów bez automatycznego ukrywania wolniejszego wyniku.

- [ ] **Step 5: Uruchomić testy oraz krótki pomiar lokalny**

Run: `swift test && swift test -c release --filter BubblePhysicsReferenceTests.ReferenceBenchmarkTests`

Expected: PASS; raport nie zawiera `NaN`, ujemnych czasów ani rozbieżnych wyników indeksów.

- [ ] **Step 6: Udokumentować uruchomienie i commit**

```bash
git add Sources/BubblePhysicsReference/Benchmark Tests/BubblePhysicsReferenceTests/ReferenceBenchmarkTests.swift README.md
git commit -m "feat: benchmark reference bubble solver"
```

### Task 9: Uruchamianie benchmarku na fizycznym iPhonie

**Files:**
- Create: `Benchmarks/iOS/BubblePhysicsBench/App/ReferenceBenchmarkView.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/BubblePhysicsBenchApp.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`
- Create: `docs/benchmarks/iphone-x-reference-solver.md`

**Interfaces:**
- Consumes: `ReferenceBenchmarkRunner` i scenariusze z Task 8.
- Produces: tryb aplikacji `Reference CPU` z wyborem 40/300/1000, start/stop, postępem i pełnym raportem.

- [ ] **Step 1: Dodać tryb i widok benchmarku bez zmiany starego ekranu radialnego**

Benchmark ma wykonywać warmup i serię pomiarową poza głównym wątkiem, publikować wynik nie częściej niż cztery razy na sekundę i umożliwiać przerwanie pomiędzy krokami.

- [ ] **Step 2: Dodać target pakietu do hosta Xcode**

Zmienić wyłącznie wpisy wymagane do importu `BubblePhysicsReference` i kompilacji `ReferenceBenchmarkView.swift`. Zachować istniejące ustawienia podpisu, urządzenia i lokalne ustawienia użytkownika.

- [ ] **Step 3: Zbudować host właściwą wersją Xcode**

Run: `DEVELOPER_DIR=/Applications/Xcode-16.4.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

Expected: `BUILD SUCCEEDED`. Jeżeli lokalna nazwa zgodnej instalacji Xcode jest inna, najpierw rozwiązać ją przez `xcode-select`/`mdfind`, nie uruchamiać automatycznie najnowszego Xcode.

- [ ] **Step 4: Udokumentować pomiar na iPhonie X**

Instrukcja podaje właściwą wersję Xcode, scenariusz 300, długość warmup/measurement i pola raportu, które użytkownik ma przekazać. CPU pozostaje pomiarem informacyjnym bez progu zaliczenia.

- [ ] **Step 5: Uruchomić pełne testy i commit**

Run: `swift test`

Expected: PASS.

```bash
git add Benchmarks/iOS/BubblePhysicsBench docs/benchmarks/iphone-x-reference-solver.md
git commit -m "feat: run reference solver benchmark on iPhone"
```

### Task 10: Końcowa weryfikacja pierwszego kamienia milowego

**Files:**
- Modify: `README.md`
- Modify: `docs/benchmarks/iphone-x-reference-solver.md`

**Interfaces:**
- Consumes: cały solver i benchmark z Tasks 1–9.
- Produces: zweryfikowany punkt odniesienia przed osobnym planem backendu Metal.

- [ ] **Step 1: Uruchomić testy debug i release**

Run: `swift test && swift test -c release`

Expected: oba przebiegi PASS.

- [ ] **Step 2: Uruchomić pełne scenariusze lokalne**

Uruchomić runner dla 40, 300 i 1000 baniek oraz obu broad phases. Zapisać p50/p95, maksymalną penetrację, limit iteracji, korekty strony i rozmiar zbioru kontaktów w dokumencie benchmarku.

- [ ] **Step 3: Sprawdzić czystość i zakres diffu**

Run: `git diff --check && git status --short`

Expected: brak błędów whitespace; w commicie nie ma `.DS_Store`, `.swiftpm`, `xcuserdata` ani przypadkowych zmian ustawień podpisu.

- [ ] **Step 4: Zaktualizować dokumentację wyniku**

README ma jasno oznaczyć stary solver jako eksperymentalny, nowy CPU jako referencję oraz backend Metal jako następny, jeszcze niezrealizowany etap.

- [ ] **Step 5: Commit i push**

```bash
git add README.md docs/benchmarks/iphone-x-reference-solver.md
git commit -m "docs: record reference solver baseline"
git push origin main
```

Po pomiarze na fizycznym iPhonie X powstaje osobna specyfikacja wykonawcza i plan `BubblePhysicsMetalNext`; nie należy dopisywać backendu GPU do tego planu bez nowej bramki przeglądu.
