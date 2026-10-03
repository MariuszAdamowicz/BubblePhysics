# Clean BubblePhysics Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zbudować od zera referencyjny rdzeń CPU jednej swobodnej bańki o bezmasowym sprężystym konturze oraz osobną aplikację iOS do kontrolowanej walidacji nacisku sztywnym wielokątem.

**Architecture:** Nowy produkt Swift Package `BubblePhysicsCore` nie zależy od dotychczasowych silników i rozdziela model, geometrię kontaktu, solver konturu, dynamikę środka oraz sterowanie sztywnym wielokątem. Osobny target iOS `BubblePhysicsLab` zależy wyłącznie od tego produktu, renderuje dokładną geometrię solvera i udostępnia minimalny interfejs testowy.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, SwiftUI, CoreGraphics; referencyjny solver CPU w `Double`; iOS 16.0+; Xcode 26.6 do budowania aplikacji na iPhone X.

**Spec:** `docs/superpowers/specs/2026-10-03-clean-bubble-physics-core-design.md`

## Global Constraints

- Nowy target nie importuje `BubblePhysics`, `BubblePhysicsReference` ani `BubblePhysicsMetal`.
- Stare targety i ich testy pozostają w repozytorium, lecz nie są kompilowane do `BubblePhysicsLab`.
- Jedyna bańka pierwszej sceny ma wartość `2`, naturalny promień `22 pt` i jest całkowicie swobodna.
- Docelowa skala promienia to `r(v) = 22 * sqrt(v / 2)` bez sztucznego ograniczenia dużych baniek.
- Punkty konturu są bezmasowe; tylko środek bańki ma masę i prędkość.
- Liczba punktów konturu wynika z maksymalnego odstępu łuku i nie ma stałego górnego limitu.
- Po kroku solvera żaden punkt konturu nie może pozostawać wewnątrz wielokąta ani poza komorą w granicach tolerancji.
- Wielokąt jest jedną bryłą z wnętrzem i zewnętrzem, a nie zbiorem niezależnych odcinków.
- Wielokąt sterowany palcem używa serwa z ograniczoną siłą i prędkością; nie teleportuje się.
- Interfejs nie zasłania komory, a każdy element dotykowy ma co najmniej `44 × 44 pt`.
- Kompilacja urządzeniowa używa `/Applications/Xcode-26.6.app`, nie domyślnego Xcode 27 ani nieuruchamialnego Xcode 16.4.
- Metal, wiele baniek, łączenie, dzielenie i benchmark 300 baniek pozostają poza zakresem tego planu.

## Review Focus

- `deltaTime` równe zero, ujemne lub po długiej pauzie nie może wywołać skoku ani wartości niefinitych; Task 6 testuje odrzucenie wartości niedodatnich i ograniczenie do `1/30 s`.
- Wielokąt z mniej niż trzema różnymi wierzchołkami musi zostać odrzucony, a powtarzające się kolejne wierzchołki nie mogą powodować dzielenia przez zero; Task 3 zawiera te testy.
- Równoodległy kontakt z narożnikiem musi wybierać powierzchnię deterministycznie; Task 3 sprawdza stabilny indeks krawędzi.
- Remeshing silnie ściśniętego konturu musi zachować kolejność i orientację punktów bez samoprzecięcia; Task 2 obejmuje tę klasę wejść.
- Przerwanie dotyku poza komorą musi wyzerować cel serwa bez impulsu i bez dalszego samoczynnego ruchu wielokąta; Task 7 testuje stan sterowania widoku.

---

## Mapa plików

Nowy kod powstaje wyłącznie w poniższych lokalizacjach:

- `Sources/BubblePhysicsCore/Math/Vector2.swift` — typ wektora i bezpieczne operacje.
- `Sources/BubblePhysicsCore/Model/Bubble.swift` — środek masy, kontur i skala wartości.
- `Sources/BubblePhysicsCore/Model/RigidPolygon.swift` — pojedyncza bryła sztywna i transformacje.
- `Sources/BubblePhysicsCore/Model/Chamber.swift` — widoczne jednostronne granice.
- `Sources/BubblePhysicsCore/Contour/ContourSampler.swift` — tworzenie i przepróbkowanie konturu.
- `Sources/BubblePhysicsCore/Geometry/PolygonGeometry.swift` — wnętrze, najbliższy punkt i stabilne normalne.
- `Sources/BubblePhysicsCore/Geometry/SweptPolygon.swift` — ciągła ochrona topologii środka.
- `Sources/BubblePhysicsCore/Solver/ContourSolver.swift` — więzy sprężyste i nieprzenikanie.
- `Sources/BubblePhysicsCore/Solver/WorldStepper.swift` — pełna kolejność pojedynczej klatki.
- `Sources/BubblePhysicsCore/Interaction/PolygonServo.swift` — ograniczony napęd palcem.
- `Sources/BubblePhysicsCore/Diagnostics/StepDiagnostics.swift` — obserwowalne metryki i walidacja stanu.
- `Sources/BubblePhysicsCore/Prototype/LabSceneConfiguration.swift` — deterministyczna scena początkowa i stan dotyku laboratorium.
- `Tests/BubblePhysicsCoreTests/*Tests.swift` — deterministyczne testy jednostkowe i integracyjne.
- `Benchmarks/iOS/BubblePhysicsLab/project.yml` oraz wygenerowany `.xcodeproj` — osobny host iOS.
- `Benchmarks/iOS/BubblePhysicsLab/App/*` — SwiftUI, adapter symulacji, renderer i sterowanie dotykiem.

## Task 1: Niezależny target i podstawowy model

**Files:**
- Modify: `Package.swift`
- Create: `Sources/BubblePhysicsCore/Math/Vector2.swift`
- Create: `Sources/BubblePhysicsCore/Model/Bubble.swift`
- Create: `Sources/BubblePhysicsCore/Model/RigidPolygon.swift`
- Create: `Sources/BubblePhysicsCore/Model/Chamber.swift`
- Create: `Tests/BubblePhysicsCoreTests/BubbleModelTests.swift`

**Interfaces:**
- Consumes: tylko standardową bibliotekę Swift.
- Produces: `BPVector`, `Bubble`, `ContourPoint`, `RigidPolygon`, `Chamber`, `BubbleScale.radius(forValue:)` oraz target `BubblePhysicsCoreTests`.

- [ ] **Step 1: Dodać testy modelu, które nie kompilują się bez nowego targetu**

Testy `testValueTwoHasTwentyTwoPointRadius`, `testScaleIsMonotonic`, `testBubbleStartsAsFiniteOrderedCircle` i `testChamberContainsInteriorPoint` mają sprawdzać odpowiednio promień `22`, rosnącą skalę dla `2...2048`, skończone punkty początkowego konturu oraz dozwolone wnętrze komory.

- [ ] **Step 2: Uruchomić RED**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter BubblePhysicsCoreTests`

Expected: FAIL, ponieważ produkt i typy jeszcze nie istnieją.

- [ ] **Step 3: Dodać produkt, target i minimalne modele**

W `Package.swift` dodać produkt i target `BubblePhysicsCore` bez zależności oraz test target o tej samej nazwie z sufiksem `Tests`.

Zdefiniować dokładnie:

```swift
public struct BPVector: Equatable, Sendable {
    public var x: Double
    public var y: Double
}

public enum BubbleScale {
    public static func radius(forValue value: Double) -> Double
}

public struct ContourPoint: Equatable, Sendable {
    public var position: BPVector
}

public struct Bubble: Equatable, Sendable {
    public var center: BPVector
    public var velocity: BPVector
    public var mass: Double
    public var naturalRadius: Double
    public var contour: [ContourPoint]
}

public struct RigidPolygon: Equatable, Sendable {
    public var localVertices: [BPVector]
    public var position: BPVector
    public var angle: Double
    public var linearVelocity: BPVector
    public var angularVelocity: Double
}

public struct Chamber: Equatable, Sendable {
    public var minimum: BPVector
    public var maximum: BPVector
}
```

`BPVector` ma udostępniać `length`, `lengthSquared`, `dot`, `cross`, `normalized(or:)` oraz operatory potrzebne późniejszym taskom. Wszystkie normalizacje zerowego wektora używają jawnego kierunku zastępczego.

- [ ] **Step 4: Uruchomić GREEN**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter BubbleModelTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/BubblePhysicsCore Tests/BubblePhysicsCoreTests/BubbleModelTests.swift
git commit -m "feat: add clean bubble physics core model"
```

## Task 2: Adaptacyjny zamknięty kontur

**Files:**
- Create: `Sources/BubblePhysicsCore/Contour/ContourSampler.swift`
- Create: `Tests/BubblePhysicsCoreTests/ContourSamplerTests.swift`

**Interfaces:**
- Consumes: `BPVector`, `Bubble`, `ContourPoint` z Task 1.
- Produces: `ContourSampler.pointCount(radius:maxArcSpacing:)`, `makeCircle(center:radius:maxArcSpacing:)` i `resampleClosedContour(_:targetCount:)`.

- [ ] **Step 1: Napisać testy adaptacyjnego próbkowania**

Testy mają potwierdzić: `N = max(8, ceil(2πr / spacing))`; brak stałego górnego limitu dla bardzo dużego `r`; prawidłową orientację przeciwną do ruchu wskazówek zegara; zachowanie środka i ciągłości po przepróbkowaniu; brak samoprzecięcia po przepróbkowaniu silnie spłaszczonego, lecz prostego konturu.

- [ ] **Step 2: Uruchomić RED**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ContourSamplerTests`

Expected: FAIL z powodu braku `ContourSampler`.

- [ ] **Step 3: Zaimplementować próbkowanie po długości łuku**

```swift
public enum ContourSampler {
    public static func pointCount(radius: Double, maxArcSpacing: Double) -> Int
    public static func makeCircle(center: BPVector, radius: Double, maxArcSpacing: Double) -> [ContourPoint]
    public static func resampleClosedContour(_ points: [ContourPoint], targetCount: Int) -> [ContourPoint]
}
```

Przepróbkowanie idzie po skumulowanej długości zamkniętej polilinii, zachowuje kolejność i odwraca wynik tylko wtedy, gdy wejście miało poprawną orientację CCW, a wynik ją utracił wskutek błędu numerycznego.

- [ ] **Step 4: Uruchomić GREEN**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ContourSamplerTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsCore/Contour Tests/BubblePhysicsCoreTests/ContourSamplerTests.swift
git commit -m "feat: add adaptive closed contour sampling"
```

## Task 3: Geometria pojedynczego wielokąta i komory

**Files:**
- Create: `Sources/BubblePhysicsCore/Geometry/PolygonGeometry.swift`
- Create: `Tests/BubblePhysicsCoreTests/PolygonGeometryTests.swift`

**Interfaces:**
- Consumes: `BPVector`, `RigidPolygon`, `Chamber` z Task 1.
- Produces: `PolygonBoundaryHit`, walidowany konstruktor wielokąta, transformację wierzchołków, test wnętrza i najbliższy punkt powierzchni.

- [ ] **Step 1: Napisać testy wnętrza, narożników i danych zdegenerowanych**

Testy obejmują punkt wewnątrz i na zewnątrz obróconego trójkąta, najbliższy punkt na krawędzi, najbliższy wierzchołek, stabilny wybór mniejszego indeksu krawędzi przy remisie, odrzucenie mniej niż trzech różnych wierzchołków oraz bezpieczną obsługę powtórzonego kolejnego wierzchołka.

- [ ] **Step 2: Uruchomić RED**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter PolygonGeometryTests`

Expected: FAIL z powodu braku geometrii.

- [ ] **Step 3: Zaimplementować jednolity opis powierzchni**

```swift
public enum PolygonValidationError: Error, Equatable { case insufficientDistinctVertices }

public struct PolygonBoundaryHit: Equatable, Sendable {
    public var point: BPVector
    public var outwardNormal: BPVector
    public var edgeIndex: Int
    public var distanceSquared: Double
}

public extension RigidPolygon {
    init(validating vertices: [BPVector], position: BPVector, angle: Double) throws
    var worldVertices: [BPVector] { get }
    func contains(_ point: BPVector) -> Bool
    func closestBoundary(to point: BPVector) -> PolygonBoundaryHit
}

public extension Chamber {
    func contains(_ point: BPVector, tolerance: Double) -> Bool
    func closestViolation(to point: BPVector) -> PolygonBoundaryHit?
}
```

Normalne są skierowane na zewnątrz wielokąta i do wnętrza komory. Zerowe krawędzie są pomijane, a tie-break używa indeksu krawędzi.

- [ ] **Step 4: Uruchomić GREEN**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter PolygonGeometryTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsCore/Geometry/PolygonGeometry.swift Tests/BubblePhysicsCoreTests/PolygonGeometryTests.swift
git commit -m "feat: add rigid polygon contact geometry"
```

## Task 4: Solver bezmasowego sprężystego konturu

**Files:**
- Create: `Sources/BubblePhysicsCore/Solver/ContourSolver.swift`
- Create: `Tests/BubblePhysicsCoreTests/ContourSolverTests.swift`

**Interfaces:**
- Consumes: modele z Task 1, sampler z Task 2, geometria z Task 3.
- Produces: `ContourSolverConfiguration`, `ContourSolveInput`, `ContourSolveResult` i `ContourSolver.solve(_:)`.

- [ ] **Step 1: Napisać testy naturalnego kształtu i lokalnych nacisków**

Testy mają sprawdzać: zbieżność zaburzonego swobodnego konturu do okręgu; monotoniczny spadek błędu po usunięciu przeszkody; szerokie gładkie spłaszczenie pod krawędzią; brak zerowego promienia i samoprzecięcia pod narożnikiem; brak punktów wewnątrz wielokąta i poza komorą; skończone wyniki przy niemal całkowitym ściśnięciu.

- [ ] **Step 2: Uruchomić RED**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ContourSolverTests`

Expected: FAIL z powodu braku solvera.

- [ ] **Step 3: Zaimplementować konfigurację i wynik solvera**

```swift
public struct ContourSolverConfiguration: Equatable, Sendable {
    public var radialStiffness: Double
    public var radialHardening: Double
    public var neighborStiffness: Double
    public var curvatureStiffness: Double
    public var projectionTolerance: Double
    public var maximumIterations: Int
}

public struct ContourSolveInput: Sendable {
    public var center: BPVector
    public var naturalRadius: Double
    public var contour: [ContourPoint]
    public var chamber: Chamber
    public var polygon: RigidPolygon
}

public struct ContourSolveResult: Sendable {
    public var contour: [ContourPoint]
    public var centerReaction: BPVector
    public var polygonReaction: BPVector
    public var activeContactCount: Int
    public var iterations: Int
    public var maximumPenetration: Double
    public var circleError: Double
    public var hasSelfIntersection: Bool
    public var isFinite: Bool
}

public struct ContourSolver: Sendable {
    public var configuration: ContourSolverConfiguration
    public func solve(_ input: ContourSolveInput) -> ContourSolveResult
}
```

Każda iteracja wykonuje w stałej kolejności projekcję sprężyn radialnych, sąsiednich, krzywizny, komory i wielokąta. Nieliniowe usztywnienie radialne rośnie monotonicznie z względnym ściskiem. Reakcja środka jest sumą przeciwnych korekt radialnych przeskalowanych sztywnością; reakcja wielokąta jest przeciwną sumą jego projekcji kontaktowych.

- [ ] **Step 4: Uruchomić GREEN**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ContourSolverTests`

Expected: PASS dla wszystkich przypadków, bez luzowania asercji penetracji i skończoności.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsCore/Solver/ContourSolver.swift Tests/BubblePhysicsCoreTests/ContourSolverTests.swift
git commit -m "feat: solve massless elastic bubble contour"
```

## Task 5: Serwo wielokąta i ciągła ochrona środka

**Files:**
- Create: `Sources/BubblePhysicsCore/Interaction/PolygonServo.swift`
- Create: `Sources/BubblePhysicsCore/Geometry/SweptPolygon.swift`
- Create: `Tests/BubblePhysicsCoreTests/PolygonServoTests.swift`
- Create: `Tests/BubblePhysicsCoreTests/SweptPolygonTests.swift`

**Interfaces:**
- Consumes: `BPVector`, `RigidPolygon` i geometria z Task 3.
- Produces: `PolygonServo`, `PolygonServoConfiguration`, `SweptPolygon.firstCenterCrossing(...)` oraz `CenterCrossing`.

- [ ] **Step 1: Napisać testy ograniczonego napędu**

Sprawdzić, że wielokąt nie osiąga odległego celu w jednej klatce, nie przekracza `maximumSpeed`, reaguje wolniej na przeciwną siłę i po usunięciu celu wygasza prędkość bez dodatkowego impulsu.

- [ ] **Step 2: Napisać testy ciągłego przecięcia całej bryły**

Sprawdzić: przecięcie środka przez przesuwaną krawędź; przecięcie przez obracający się narożnik; legalne ominięcie narożnika; brak fałszywego trafienia dla nieruchomej rozłącznej geometrii; zwrot najwcześniejszego czasu w `[0, 1]`.

- [ ] **Step 3: Uruchomić RED**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter 'PolygonServoTests|SweptPolygonTests'`

Expected: FAIL z powodu brakujących typów.

- [ ] **Step 4: Zaimplementować serwo**

```swift
public struct PolygonServoConfiguration: Equatable, Sendable {
    public var positionGain: Double
    public var velocityDamping: Double
    public var maximumForce: Double
    public var maximumSpeed: Double
}

public struct PolygonServo: Sendable {
    public var configuration: PolygonServoConfiguration
    public func step(polygon: RigidPolygon, target: BPVector?, reaction: BPVector, deltaTime: Double) -> RigidPolygon
}
```

Cel `nil` oznacza brak napędu pozycyjnego i pozostawia tylko tłumienie prędkości.

- [ ] **Step 5: Zaimplementować swept test**

```swift
public struct CenterCrossing: Equatable, Sendable {
    public var time: Double
    public var point: BPVector
    public var outwardNormal: BPVector
}

public enum SweptPolygon {
    public static func firstCenterCrossing(
        centerStart: BPVector,
        centerEnd: BPVector,
        polygonStart: RigidPolygon,
        polygonEnd: RigidPolygon
    ) -> CenterCrossing?
}
```

Ruch transformacji jest próbkowany konserwatywnie i doprecyzowany bisekcją do tolerancji czasu `1e-5`; wynik dotyczy pierwszej zmiany topologicznej całego wielokąta, nie strony nieskończonej prostej.

- [ ] **Step 6: Uruchomić GREEN**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter 'PolygonServoTests|SweptPolygonTests'`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/BubblePhysicsCore/Interaction Sources/BubblePhysicsCore/Geometry/SweptPolygon.swift Tests/BubblePhysicsCoreTests/PolygonServoTests.swift Tests/BubblePhysicsCoreTests/SweptPolygonTests.swift
git commit -m "feat: add resisted polygon servo and center CCD"
```

## Task 6: Pełny krok świata i diagnostyka

**Files:**
- Create: `Sources/BubblePhysicsCore/Diagnostics/StepDiagnostics.swift`
- Create: `Sources/BubblePhysicsCore/Solver/WorldStepper.swift`
- Create: `Tests/BubblePhysicsCoreTests/WorldStepperTests.swift`

**Interfaces:**
- Consumes: wszystkie interfejsy Tasks 1–5.
- Produces: `BubbleWorldState`, `WorldStepInput`, `WorldStepConfiguration`, `StepDiagnostics` i mutujące `WorldStepper.step(state:input:)`.

- [ ] **Step 1: Napisać integracyjne testy kolejności klatki**

Testy obejmują: ścisk przy ścianie przesuwa środek w stronę redukcji energii; uwolniony ruch maleje przez opór; reakcja bańki spowalnia serwo; szybki wielokąt nie przenosi środka do swojego wnętrza; po każdym kroku kontur pozostaje poza wielokątem i w komorze; identyczny reset i wejścia dają identyczny wynik; `deltaTime <= 0` nie zmienia stanu; `deltaTime > 1/30` jest ograniczone do `1/30`; wszystkie metryki są skończone.

- [ ] **Step 2: Uruchomić RED**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter WorldStepperTests`

Expected: FAIL z powodu braku integratora.

- [ ] **Step 3: Zaimplementować stan, wejście i telemetrię**

```swift
public struct BubbleWorldState: Equatable, Sendable {
    public var bubble: Bubble
    public var polygon: RigidPolygon
    public var chamber: Chamber
}

public struct WorldStepInput: Equatable, Sendable {
    public var polygonTarget: BPVector?
    public var deltaTime: Double
}

public struct WorldStepConfiguration: Equatable, Sendable {
    public var linearDrag: Double
    public var maximumDeltaTime: Double
    public var maxArcSpacing: Double
    public var centerResponseScale: Double
    public var topologySlop: Double
    public var contour: ContourSolverConfiguration
    public var servo: PolygonServoConfiguration
}

public struct StepDiagnostics: Equatable, Sendable {
    public var contourPointCount: Int
    public var activeContactCount: Int
    public var solverIterations: Int
    public var maximumPenetration: Double
    public var circleError: Double
    public var centerReactionMagnitude: Double
    public var topologyCorrectionCount: Int
    public var reachedIterationLimit: Bool
    public var hasSelfIntersection: Bool
    public var isFinite: Bool
}
```

- [ ] **Step 4: Zaimplementować dokładną sekwencję `WorldStepper.step`**

```swift
public struct WorldStepper: Sendable {
    public var configuration: WorldStepConfiguration
    public var contourSolver: ContourSolver
    public mutating func step(state: inout BubbleWorldState, input: WorldStepInput) -> StepDiagnostics
}
```

Metoda realizuje 13 kroków ze specyfikacji: przewiduje serwo i środek, adaptuje `N`, rozwiązuje kontur, przenosi reakcję na środek, rozwiązuje kontur ponownie, stosuje ochronę topologii, przekazuje reakcję wielokątowi i tworzy diagnostykę. Korekta CCD umieszcza środek przy trafieniu plus `topologySlop`, ale nie dodaje impulsu sprężystego drugi raz.

- [ ] **Step 5: Uruchomić GREEN i pełną regresję pakietu**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter WorldStepperTests`

Expected: PASS.

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test`

Expected: wszystkie stare i nowe testy PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/BubblePhysicsCore/Diagnostics Sources/BubblePhysicsCore/Solver/WorldStepper.swift Tests/BubblePhysicsCoreTests/WorldStepperTests.swift
git commit -m "feat: integrate clean single bubble world step"
```

## Task 7: Czysty host BubblePhysicsLab

**Files:**
- Create: `Benchmarks/iOS/BubblePhysicsLab/project.yml`
- Create: `Benchmarks/iOS/BubblePhysicsLab/App/BubblePhysicsLabApp.swift`
- Create: `Benchmarks/iOS/BubblePhysicsLab/App/LabSimulationModel.swift`
- Create: `Benchmarks/iOS/BubblePhysicsLab/App/LabSceneView.swift`
- Create: `Benchmarks/iOS/BubblePhysicsLab/App/LabDiagnosticsView.swift`
- Create: `Benchmarks/iOS/BubblePhysicsLab/BubblePhysicsLab.xcodeproj/project.pbxproj` (wygenerowany z `project.yml`)
- Create: `Sources/BubblePhysicsCore/Prototype/LabSceneConfiguration.swift`
- Create: `Tests/BubblePhysicsCoreTests/LabSceneConfigurationTests.swift`

**Interfaces:**
- Consumes: wyłącznie produkt `BubblePhysicsCore` i `WorldStepper` z Task 6.
- Produces: uruchamialny target iOS `BubblePhysicsLab`, deterministyczny stan początkowy oraz sterowanie dotykiem wielokąta.

- [ ] **Step 1: Dodać test konfiguracji sceny niezależny od SwiftUI**

W rdzeniu zdefiniować `LabSceneConfiguration.makeInitialState(viewSize:)`. Test potwierdza bańkę `2` o promieniu `22`, całkowicie widoczną komorę z marginesem, wielokąt poza bańką, brak początkowej penetracji oraz deterministyczny reset.

- [ ] **Step 2: Uruchomić RED**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter LabSceneConfigurationTests`

Expected: FAIL z powodu braku fabryki sceny.

- [ ] **Step 3: Zaimplementować fabrykę sceny i model aplikacji**

```swift
public enum LabSceneConfiguration {
    public static func makeInitialState(viewSize: BPVector) throws -> BubbleWorldState
}
```

`LabSimulationModel` posiada jeden `WorldStepper`, bieżący stan, ostatnią diagnostykę, `LabTouchState` i metody `reset()`, `setPolygonTarget(_:)`, `clearPolygonTarget()` oraz `step(atTimestamp:)`. Pierwsza klatka tylko zapamiętuje czas; kolejne przekazują różnicę do rdzenia.

```swift
public struct LabTouchState: Equatable, Sendable {
    public private(set) var polygonTarget: BPVector?
    public mutating func beginOrMove(to point: BPVector)
    public mutating func endOrCancel()
}
```

- [ ] **Step 4: Zbudować minimalny interfejs i renderer**

`LabSceneView` używa `Canvas` i rysuje w tej kolejności: tło, cztery granice komory, naturalny okrąg (opcjonalnie), wypełniony zamknięty kontur, środek (opcjonalnie), sztywny wielokąt. Gesture przekazuje pozycję palca tylko podczas aktywnego dotyku; zakończenie lub anulowanie zawsze wywołuje `clearPolygonTarget()`.

Górny pasek poza komorą zawiera tylko `Reset`, `Dane`, `Środek` i `Okrąg`, każdy z ramką dotyku co najmniej `44 × 44 pt`. `Dane` otwiera arkusz SwiftUI (`sheet`), nigdy nakładkę nad symulacją.

- [ ] **Step 5: Wygenerować osobny projekt Xcode**

`project.yml` ma deployment target `16.0`, bundle id `com.mariuszadamowicz.BubblePhysicsLab` i zależność tylko od produktu `BubblePhysicsCore` z pakietu `../../..`.

Run: `cd Benchmarks/iOS/BubblePhysicsLab && xcodegen generate`

Expected: powstaje `BubblePhysicsLab.xcodeproj` ze schematem `BubblePhysicsLab`.

- [ ] **Step 6: Sprawdzić przerwanie dotyku i GREEN konfiguracji**

Dodać w `LabSceneConfigurationTests.swift` test `LabTouchState`, który potwierdza, że `beginOrMove(to:)` ustawia cel, a `endOrCancel()` ustawia go na `nil`. `LabSimulationModel` ma przekazywać do `WorldStepper` wyłącznie wartość `touchState.polygonTarget`, więc zakończenie gestu nie tworzy osobnego impulsu.

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter LabSceneConfigurationTests`

Expected: PASS.

- [ ] **Step 7: Zbudować aplikację bez podpisywania**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsLab/BubblePhysicsLab.xcodeproj -scheme BubblePhysicsLab -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
git add Sources/BubblePhysicsCore Tests/BubblePhysicsCoreTests/LabSceneConfigurationTests.swift Benchmarks/iOS/BubblePhysicsLab
git commit -m "feat: add focused iOS bubble physics lab"
```

## Task 8: Walidacja scenariuszy i dokument uruchomieniowy

**Files:**
- Create: `Tests/BubblePhysicsCoreTests/AcceptanceScenarioTests.swift`
- Create: `docs/benchmarks/iphone-x-clean-bubble-lab.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: kompletny `BubblePhysicsCore` i `BubblePhysicsLab`.
- Produces: automatyczną bramkę akceptacyjną oraz jednoznaczną instrukcję ręcznego testu na iPhonie X.

- [ ] **Step 1: Napisać pięć deterministycznych scenariuszy akceptacyjnych**

`AcceptanceScenarioTests` odtwarza: powrót do okręgu, nacisk płaską krawędzią, nacisk narożnikiem, ścisk przy ścianie i szybki ruch wielokąta. Wszystkie sceny używają kroku `1/60 s`. Po każdym kroku wymagają `isFinite == true`, `hasSelfIntersection == false` i `maximumPenetration <= 1e-4 pt`. Powrót do okręgu po 120 swobodnych krokach wymaga `circleError <= 0.25 pt`. Powolny nacisk nie może użyć ochrony topologii; szybki ruch może jej użyć, lecz środek i kontur kończą poza wielokątem. Ścisk przy ścianie musi przesunąć środek o co najmniej `0.5 pt` w kierunku przeciwnym do nacisku w ciągu 30 kroków.

- [ ] **Step 2: Uruchomić scenariusze jako bramkę integracyjną**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter AcceptanceScenarioTests`

Expected: PASS. Każdy FAIL jest defektem tasku będącego właścicielem naruszonego zachowania.

- [ ] **Step 3: W razie niepowodzenia poprawić zachowanie przez test właścicielski**

Najpierw dodać najmniejszy test reprodukujący do `ContourSolverTests`, `PolygonServoTests`, `SweptPolygonTests` albo `WorldStepperTests`. Następnie zmienić wyłącznie odpowiadający moduł lub jego domyślną konfigurację i uruchomić ponownie test właścicielski oraz `AcceptanceScenarioTests`. Nie stroić renderera ani sceny w celu ukrycia defektu rdzenia.

- [ ] **Step 4: Uruchomić pełną weryfikację**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test`

Expected: wszystkie testy PASS.

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsLab/BubblePhysicsLab.xcodeproj -scheme BubblePhysicsLab -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Zapisać instrukcję ręcznej walidacji**

Dokument ma wskazać Xcode 26.6, projekt `BubblePhysicsLab.xcodeproj`, fizyczny iPhone X z iOS 16.7.16 oraz kolejność pięciu testów ze specyfikacji. Dla każdego testu opisać oczekiwany obraz i metryki dyskwalifikujące: punkt wewnątrz wielokąta, trwała deformacja, samoprzecięcie, `non-finite`, dobicie do limitu iteracji lub interwencja topologiczna przy powolnym nacisku.

- [ ] **Step 6: Zaktualizować README**

Na początku README oznaczyć `BubblePhysicsCore` jako aktualny model poprawności, a poprzednie targety jako historię eksperymentów. Podać bezpośrednią ścieżkę do nowego projektu i dokumentu walidacji.

- [ ] **Step 7: Commit i push**

```bash
git add Tests/BubblePhysicsCoreTests/AcceptanceScenarioTests.swift docs/benchmarks/iphone-x-clean-bubble-lab.md README.md
git commit -m "test: validate clean bubble physics lab"
git push origin HEAD
```

## Końcowa bramka

Po Task 8 kod jest gotowy do uruchomienia przez użytkownika na iPhonie X, ale nie uznajemy modelu za zaakceptowany wyłącznie na podstawie testów automatycznych. Użytkownik wykonuje pięć ręcznych scenariuszy. Dopiero jego ocena wyglądu i zachowania pozwala przejść do specyfikacji drugiej bańki i kontaktu bańka–bańka.
