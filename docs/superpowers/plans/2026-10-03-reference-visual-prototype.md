# Reference Visual Prototype Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dodać poprawne kolizje dwustronnych odcinków oraz wizualną scenę `CPU Wiz`, która pozwoli ocenić fizykę solvera referencyjnego na iPhonie X.

**Architecture:** `ReferenceSegment` jawnie rozróżnia jednostronne granice i dwustronne powierzchnie przeszkód. CCD testuje ruch środka względem skończonego odcinka pogrubionego o promień, a solver stosuje zakaz strony wyłącznie do ścian. Testowalna scena i sterownik stałego kroku żyją w `BubblePhysicsReference`; SwiftUI Canvas jest cienką warstwą prezentacji w aplikacji benchmarkowej.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, SwiftUI Canvas, iOS 16+, Xcode 26.6.

**Spec:** `docs/superpowers/specs/2026-10-02-bubble-physics-contact-envelope-design.md`

## Global Constraints

- Komunikacja i dokumentacja pozostają po polsku.
- CPU jest deterministycznym wzorcem poprawności; ten etap nie portuje kodu do Metal.
- Symulacja wizualna używa stałego kroku `1/60 s` i najwyżej 3 kroków nadrabiających na odświeżenie.
- Ściany planszy są jednostronne, a krawędzie trójkąta dwustronne.
- Pełny kontur służy wyłącznie renderowaniu i nie uczestniczy w CCD ani solverze.
- Aplikacja urządzeniowa buduje się i uruchamia w konfiguracji Release przez Xcode 26.6.

## Review Focus

- Zmiana strony prostej poza końcem odcinka nie może generować fałszywej kolizji — test w Task 2.
- Szybki ruch dwustronnego odcinka przez środek musi dać TOI — test w Task 2.
- Normalna przy dokładnym pokryciu środka z `Q` musi pozostać deterministyczna i skończona — test w Task 1.
- Trzy krawędzie jednego trójkąta nie mogą narzucać sprzecznych półpłaszczyzn — test integracyjny w Task 3.
- Długi odstęp między klatkami nie może uruchomić nieograniczonej liczby kroków — test harmonogramu w Task 3.

---

### Task 1: Jawny tryb kolizji odcinka

**Files:**
- Modify: `Sources/BubblePhysicsReference/Model/ReferenceSegment.swift`
- Modify: `Sources/BubblePhysicsReference/Geometry/DiscreteContactGenerator.swift`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceWorld.swift`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceEquilibriumSolver.swift`
- Test: `Tests/BubblePhysicsReferenceTests/DiscreteContactGeneratorTests.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceWorldTests.swift`

**Interfaces:**
- Produces: `ReferenceSegmentCollisionMode.oneSided(allowedSide: Float)` i `.twoSided`.
- Produces: `ReferenceSegment.collisionMode` oraz generowanie kontaktu bez zewnętrznego argumentu `allowedSide`.

- [ ] **Step 1: Write failing tests for collision-mode semantics**

Dodaj testy, że kontakt jednostronny zachowuje wskazaną normalną, kontakt dwustronny wybiera normalną `Q -> center`, a dokładne pokrycie daje skończoną deterministyczną normalną.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter DiscreteContactGeneratorTests`
Expected: FAIL, ponieważ `ReferenceSegmentCollisionMode` i nowe API jeszcze nie istnieją.

- [ ] **Step 3: Implement the model and migrate world/solver callers**

Dodaj enum i pole do `ReferenceSegment`; konstruktory przyjmują `collisionMode`. Usuń mapę `segmentAllowedSides` ze świata. Kontakt przechowuje `allowedSide` tylko dla trybu jednostronnego, a solver odświeża kandydatów na podstawie trybu segmentu.

- [ ] **Step 4: Run focused and reference suites**

Run: `swift test --filter BubblePhysicsReferenceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

`git commit -m "feat: distinguish one-sided and two-sided segments"`

### Task 2: CCD dwustronnego skończonego odcinka

**Files:**
- Modify: `Sources/BubblePhysicsReference/CCD/BubbleSegmentTOI.swift`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceWorld.swift`
- Test: `Tests/BubblePhysicsReferenceTests/BubbleSegmentTOITests.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceWorldTests.swift`

**Interfaces:**
- Consumes: `ReferenceSegment.collisionMode` z Task 1.
- Produces: `ReferenceCCD.bubbleSegment(_:_:configuration:) -> ReferenceSegmentTOIResult`.

- [ ] **Step 1: Write failing trajectory tests**

Dodaj ręcznie wyliczone przypadki: przejście przez środkową część kapsuły daje TOI, uderzenie w koniec daje TOI, obejście końca ze zmianą znaku strony daje `.none`, a jednostronna ściana nadal zgłasza korektę zabronionej strony.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter BubbleSegmentTOITests`
Expected: FAIL dla obejścia końca lub nowego API bez `allowedSide`.

- [ ] **Step 3: Implement collision-mode-aware CCD**

Dla translacji zachowaj analityczny test kapsuły. Dla obrotu zachowaj conservative advancement. `requiresSideCorrection` obliczaj wyłącznie dla `.oneSided`; sama zmiana strony `.twoSided` nie jest zdarzeniem.

- [ ] **Step 4: Run focused and reference suites**

Run: `swift test --filter BubblePhysicsReferenceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

`git commit -m "feat: add two-sided segment CCD"`

### Task 3: Deterministyczna scena wizualna i stały krok

**Files:**
- Create: `Sources/BubblePhysicsReference/Visual/ReferenceVisualScene.swift`
- Create: `Sources/BubblePhysicsReference/Visual/ReferenceVisualRunner.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceVisualSceneTests.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceVisualRunnerTests.swift`

**Interfaces:**
- Produces: `ReferenceVisualSceneFactory.make() throws -> ReferenceVisualScene` z 40 bańkami, czterema ścianami i trzema krawędziami trójkąta.
- Produces: `ReferenceVisualRunner.advance(to:) -> ReferenceVisualSnapshot` oraz `reset()`.
- Snapshot zawiera bańki, kontury, trzy wierzchołki trójkąta i ostatni `ReferenceWorldStepReport`.

- [ ] **Step 1: Write failing scene and schedule tests**

Sprawdź literalnie liczbę i tryby segmentów, zróżnicowanie promieni, wspólny `ownerID`, maksymalnie 3 kroki po długiej przerwie oraz brak przejścia trójkąta przez środek w reprezentatywnej sekwencji.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter ReferenceVisual`
Expected: FAIL, ponieważ typy wizualnej sceny nie istnieją.

- [ ] **Step 3: Implement scene, triangle sampler and runner**

Użyj planszy `375 x 700`, deterministycznego rozkładu promieni i położeń oraz okresowego ruchu translacyjno-obrotowego. Przed każdym krokiem zaktualizuj trzy segmenty tym samym stanem bryły.

- [ ] **Step 4: Run focused and reference suites**

Run: `swift test --filter BubblePhysicsReferenceTests`
Expected: PASS bez `non-finite`.

- [ ] **Step 5: Commit**

`git commit -m "feat: add reference visual diagnostic scene"`

### Task 4: SwiftUI Canvas `CPU Wiz`

**Files:**
- Create: `Benchmarks/iOS/BubblePhysicsBench/App/ReferenceVisualPrototypeView.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/BubblePhysicsBenchApp.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`
- Modify: `docs/benchmarks/iphone-x-reference-solver.md`

**Interfaces:**
- Consumes: `ReferenceVisualRunner` i `ReferenceVisualSnapshot` z Task 3.
- Produces: tryb aplikacji `CPU Wiz` z pauzą, resetem, punktami diagnostycznymi i telemetrią.

- [ ] **Step 1: Add the view against the tested runner**

Canvas skaluje świat jednolicie do dostępnego obszaru, wypełnia gładkie zamknięte kontury, obraca etykiety według `bubble.rotation` i rysuje trójkąt ponad bańkami. `TimelineView(.animation)` wyłącznie wyzwala `advance(to:)`.

- [ ] **Step 2: Integrate controls without changing legacy modes**

Dodaj `PrototypeMode.referenceVisual`; dotychczasowe `CPU`, `Radial`, `40` i `300` pozostają dostępne. Kontrolki pauzy, resetu i punktów działają w nowym trybie.

- [ ] **Step 3: Verify package, project and iOS build**

Run: `swift test --filter BubblePhysicsReferenceTests`

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

Expected: oba polecenia kończą się sukcesem.

- [ ] **Step 4: Install/run Release and perform device handoff**

Uruchom przez współdzielony schemat Release w Xcode 26.6. CEO ocenia ruch, brak tunnelingu, odkształcenia, powrót konturu i wypełnianie przestrzeni.

- [ ] **Step 5: Commit and push**

`git commit -m "feat: visualize reference bubble physics"`

`git push`
