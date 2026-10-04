# Event-Aware Implicit Contact Solver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Naprawić istniejący `BubblePhysicsReference`, aby Newton rozwiązywał dynamiczny układ sprężyn kontaktowych z wykrywaniem początku kontaktów wewnątrz klatki.

**Architecture:** Zachowujemy model świata, broad phase, CCD, PCG, scenę i telemetrię. Zastępujemy statyczny `ReferenceStressSystem` dynamicznym residualem niejawnego punktu środkowego, a `ReferenceEquilibriumSolver` staje się iteracyjnym solverem aktywnej sieci kontaktów; kontur jest generowany po kroku z rozwiązanych ścisków.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, CPU `Float`, rzadki matrix-free Newton–PCG, istniejący host SwiftUI iOS, Xcode 26.6.

**Spec:** `docs/superpowers/specs/2026-10-03-event-aware-implicit-contact-solver-design.md`

## Global Constraints

- Zmieniamy `BubblePhysicsReference`; nie podłączamy szkicu `BubblePhysicsCore` do aplikacji.
- Jedyną zwykłą siłą normalną jest sprężyna kontaktowa `F = max(0, K*d - gamma*vNormal) * n`.
- Newton rozwiązuje stan dynamiczny `C1`, `v1`; nie minimalizuje statycznej mapy deformacji.
- Środki nie są bezpośrednio rozsuwane poza awaryjną ochroną topologiczną CCD.
- Punkty konturu nie są stopniami swobody solvera.
- Nowe kontakty aktywujemy w wyznaczonym czasie TOI; niemal równoczesne zdarzenia grupujemy.
- Nie planujemy końca kontaktu dla gęstej sieci; usuwamy go przy zerowym ścisku i ruchu rozdzielającym.
- Maksimum: 4 iteracje Newtona, 16 iteracji PCG i 8 grup zdarzeń na klatkę w konfiguracji początkowej.
- Build iOS używa `/Applications/Xcode-26.6.app`.

## Review Focus

- Kontakt z zerową odległością środków używa deterministycznej normalnej i nie generuje `NaN`; Task 1.
- Tłumik nie może wytworzyć przyciągania przy rozdzielaniu; Task 1.
- Dwa zdarzenia o prawie identycznym TOI muszą wejść do tej samej grupy niezależnie od kolejności wejścia; Task 3.
- Kontakt powstały dokładnie na końcu klatki nie może zostać zgubiony ani rozwiązany przez ujemny czas; Task 3.
- Nieudany Newton/PCG musi zwrócić skończony stan i telemetrię limitu zamiast częściowo zastosowanego kroku; Task 4.

---

### Task 1: Prawo sprężyny kontaktowej

**Files:**
- Create: `Sources/BubblePhysicsReference/Solver/ReferenceContactSpring.swift`
- Create: `Tests/BubblePhysicsReferenceTests/ReferenceContactSpringTests.swift`
- Modify: `Sources/BubblePhysicsReference/Model/ReferenceConfiguration.swift`

**Interfaces:**
- Consumes: `ReferenceVector2`, masa, promień, punkt `Q` i prędkości uczestników.
- Produces: `ReferenceContactSpringState.evaluate(...) -> ReferenceContactSpringSample` oraz parametry `contactStiffness`, `contactDamping`.

- [ ] **Step 1: Napisać testy RED**

Testy: brak ścisku daje siłę zero; ścisk `2` przy `K=10` daje siłę normalną `20`; siła jest przeciwnie równa dla dwóch baniek; tłumienie zwiększa reakcję przy zbliżaniu, ale wynik nigdy nie przyciąga przy rozdzielaniu; zerowy dystans daje deterministyczną skończoną normalną.

- [ ] **Step 2: Uruchomić RED**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ReferenceContactSpringTests`

Expected: FAIL, brak typu.

- [ ] **Step 3: Zaimplementować minimalne API**

```swift
public struct ReferenceContactSpringSample: Sendable, Equatable {
    public var compression: Float
    public var normal: ReferenceVector2
    public var forceOnA: ReferenceVector2
    public var tangentStiffness: Float
}

public enum ReferenceContactSpringState {
    public static func evaluate(
        centerA: ReferenceVector2, velocityA: ReferenceVector2, radiusA: Float,
        centerB: ReferenceVector2?, velocityB: ReferenceVector2,
        pointQ: ReferenceVector2?, normalFallback: ReferenceVector2,
        contactDistance: Float, stiffness: Float, damping: Float
    ) -> ReferenceContactSpringSample
}
```

Dla bańka–bańka `contactDistance = rA + rB`; dla powierzchni `pointQ` jest punktem zaczepienia i `contactDistance = rA`. Normalna siły na A jest skierowana od B/Q do A.

- [ ] **Step 4: GREEN i commit**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ReferenceContactSpringTests`

Expected: PASS.

```bash
git add Sources/BubblePhysicsReference/Solver/ReferenceContactSpring.swift Sources/BubblePhysicsReference/Model/ReferenceConfiguration.swift Tests/BubblePhysicsReferenceTests/ReferenceContactSpringTests.swift
git commit -m "feat: model dynamic contact springs"
```

### Task 2: Dynamiczny układ niejawnego punktu środkowego

**Files:**
- Create: `Sources/BubblePhysicsReference/Solver/ReferenceDynamicSystem.swift`
- Create: `Tests/BubblePhysicsReferenceTests/ReferenceDynamicSystemTests.swift`
- Delete after replacement: `Sources/BubblePhysicsReference/Solver/ReferenceStressSystem.swift`
- Delete after replacement: `Tests/BubblePhysicsReferenceTests/ReferenceStressSystemTests.swift`

**Interfaces:**
- Consumes: próbki z Task 1, pozycje i prędkości początku przedziału.
- Produces: residual pozycji końcowych, matrix-free Jacobian, preconditioner i odtworzenie `v1`.

- [ ] **Step 1: Napisać testy RED równań ruchu**

Testy: brak sił zachowuje stałą prędkość; globalny opór zmniejsza prędkość bez zmiany kierunku; pojedyncza sprężyna przyspiesza zgodnie z `F/m`; równe przeciwne sprężyny dają zerowe przyspieszenie; residual dokładnego przypadku jednowymiarowego jest bliski zero; Jacobian–wektor zgadza się z różnicą skończoną do `1e-3`.

- [ ] **Step 2: Uruchomić RED**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ReferenceDynamicSystemTests`

Expected: FAIL, brak systemu.

- [ ] **Step 3: Zaimplementować system**

```swift
public struct ReferenceDynamicContact: Sendable, Equatable {
    public var indexA: Int
    public var indexB: Int?
    public var pointQ: ReferenceVector2?
    public var contactDistance: Float
    public var normalFallback: ReferenceVector2
}

public struct ReferenceDynamicSystem: Sendable {
    public init(
        startCenters: [ReferenceVector2], startVelocities: [ReferenceVector2],
        masses: [Float], radii: [Float], contacts: [ReferenceDynamicContact],
        timeStep: Float, stiffness: Float, contactDamping: Float, globalDrag: Float
    )
    public func velocities(forEndCenters: [ReferenceVector2]) -> [ReferenceVector2]
    public func residual(endCenters: [ReferenceVector2]) -> [ReferenceVector2]
    public func applyJacobian(at endCenters: [ReferenceVector2], to vector: [ReferenceVector2]) -> [ReferenceVector2]
    public func inverseDiagonalPreconditioner(at endCenters: [ReferenceVector2]) -> [ReferenceVector2]
}
```

Residual implementuje dokładnie niejawny punkt środkowy. Jacobian może użyć analitycznych bloków normalnych; test różnicy skończonej jest kontraktem.

- [ ] **Step 4: GREEN, usunięcie starego systemu i commit**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ReferenceDynamicSystemTests`

Expected: PASS.

```bash
git add Sources/BubblePhysicsReference/Solver Tests/BubblePhysicsReferenceTests
git commit -m "feat: solve midpoint contact dynamics"
```

### Task 3: Grupowanie zdarzeń kontaktowych w klatce

**Files:**
- Create: `Sources/BubblePhysicsReference/CCD/ReferenceContactEvent.swift`
- Create: `Tests/BubblePhysicsReferenceTests/ReferenceContactEventTests.swift`
- Modify: `Sources/BubblePhysicsReference/Model/ReferenceConfiguration.swift`

**Interfaces:**
- Consumes: istniejące `BubbleBubbleTOI`, `BubbleSegmentTOI`, kandydatów broad phase.
- Produces: posortowane `ReferenceContactEventGroup` i resztę czasu przedziału.

- [ ] **Step 1: Napisać testy RED kalendarza**

Testy: wybór najwcześniejszego TOI; grupowanie zdarzeń w tolerancji `1e-5 s`; deterministyczna kolejność ID; kontakt dokładnie przy `dt` jest zwracany; ujemne/nie-skończone czasy są odrzucane; maksimum 8 grup ustawia flagę limitu.

- [ ] **Step 2: Uruchomić RED**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ReferenceContactEventTests`

Expected: FAIL.

- [ ] **Step 3: Zaimplementować model zdarzeń**

```swift
public struct ReferenceContactEvent: Sendable, Equatable, Comparable {
    public var time: Float
    public var contactID: ReferenceContactID
}

public struct ReferenceContactEventGroup: Sendable, Equatable {
    public var time: Float
    public var events: [ReferenceContactEvent]
}

public enum ReferenceContactEventQueue {
    public static func groups(
        events: [ReferenceContactEvent], frameDuration: Float,
        simultaneousTolerance: Float, limit: Int
    ) -> (groups: [ReferenceContactEventGroup], didReachLimit: Bool)
}
```

- [ ] **Step 4: GREEN i commit**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ReferenceContactEventTests`

Expected: PASS.

```bash
git add Sources/BubblePhysicsReference/CCD/ReferenceContactEvent.swift Sources/BubblePhysicsReference/Model/ReferenceConfiguration.swift Tests/BubblePhysicsReferenceTests/ReferenceContactEventTests.swift
git commit -m "feat: group contact events within frames"
```

### Task 4: Zastąpienie statycznego solvera Newtona

**Files:**
- Rewrite: `Sources/BubblePhysicsReference/Solver/ReferenceEquilibriumSolver.swift`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceSolverReport.swift`
- Rewrite: `Tests/BubblePhysicsReferenceTests/ReferenceEquilibriumSolverTests.swift`
- Modify: `Tests/BubblePhysicsReferenceTests/ReferencePCGSolverTests.swift`

**Interfaces:**
- Consumes: `ReferenceDynamicSystem`, `ReferencePCGSolver`, aktywny `ReferenceContactSet`.
- Produces: końcowe centra i prędkości oraz raport Newton/PCG bez bezpośredniego rozsuwania.

- [ ] **Step 1: Napisać testy RED zachowania solvera**

Testy: niezrównoważony kontakt zmienia prędkość zgodnie z siłą; równoważne kontakty nie przesuwają środka; trzy bańki rozwiązują sprzężoną reakcję; wynik jednego `dt` zbliża się do dwóch `dt/2`; wymuszony limit Newtona zwraca skończony stan i flagę; brak kontaktów zachowuje ruch swobodny.

- [ ] **Step 2: Uruchomić RED przeciw staremu solverowi**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ReferenceEquilibriumSolverTests`

Expected: FAIL nowych asercji dynamicznych.

- [ ] **Step 3: Zaimplementować Newton–PCG dla stanu końcowego**

`solve(...)` otrzymuje dodatkowo `timeStep`, zachowuje stan początkowy, buduje `ReferenceDynamicSystem`, wykonuje maksymalnie 4 iteracje Newtona i maksymalnie 16 PCG, a po akceptacji zapisuje jednocześnie centra i prędkości. Line search akceptuje krok zmniejszający normę residualu, nie statyczną energię deformacji.

Aktywny kontakt jest aktualizowany po każdym kroku Newtona. Kontakt znika tylko przy `compression <= contactTolerance` oraz dodatniej prędkości rozdzielającej.

- [ ] **Step 4: GREEN i commit**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter 'ReferenceEquilibriumSolverTests|ReferencePCGSolverTests'`

Expected: PASS.

```bash
git add Sources/BubblePhysicsReference/Solver Tests/BubblePhysicsReferenceTests/ReferenceEquilibriumSolverTests.swift Tests/BubblePhysicsReferenceTests/ReferencePCGSolverTests.swift
git commit -m "fix: integrate contact spring dynamics with Newton"
```

### Task 5: Zdarzeniowy przebieg `ReferenceWorld.step`

**Files:**
- Rewrite: `Sources/BubblePhysicsReference/Solver/ReferenceWorld.swift`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceWorldStepReport.swift`
- Rewrite: `Tests/BubblePhysicsReferenceTests/ReferenceWorldTests.swift`
- Modify: `Tests/BubblePhysicsReferenceTests/BubbleBubbleTOITests.swift`
- Modify: `Tests/BubblePhysicsReferenceTests/BubbleSegmentTOITests.swift`

**Interfaces:**
- Consumes: grupy zdarzeń Task 3 i solver Task 4.
- Produces: kompletny krok klatki z podziałem wyłącznie przy nowych kontaktach.

- [ ] **Step 1: Napisać testy RED przebiegu klatki**

Testy: kontakt po połowie klatki wpływa tylko na pozostały czas; równoczesne dwa kontakty aktywują się razem; trzeci kontakt zmienia wynik trwającej pary; kontakt na końcu klatki jest zachowany do następnej; limit zdarzeń jest raportowany; wolny ruch nie wykonuje zbędnych podziałów; szybki segment nie przenika środka.

- [ ] **Step 2: Uruchomić RED**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ReferenceWorldTests`

Expected: FAIL nowych scenariuszy.

- [ ] **Step 3: Zaimplementować pętlę pozostałego czasu**

`step()` utrzymuje `remainingTime`, oblicza swept kandydatów i najwcześniejszą grupę, integruje aktywny układ do grupy, aktywuje zdarzenia i powtarza. Po ósmej grupie integruje pozostały czas konserwatywnie. `applyCenterGuards()` działa dopiero po dynamicznym kroku i jest raportowany osobno.

Usunąć rekonstrukcję prędkości `(center - previousCenter)/dt`; prędkość pochodzi bezpośrednio z integratora Task 4.

- [ ] **Step 4: GREEN i commit**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter 'ReferenceWorldTests|BubbleBubbleTOITests|BubbleSegmentTOITests'`

Expected: PASS.

```bash
git add Sources/BubblePhysicsReference/Solver/ReferenceWorld.swift Sources/BubblePhysicsReference/Solver/ReferenceWorldStepReport.swift Tests/BubblePhysicsReferenceTests
git commit -m "feat: integrate world across contact events"
```

### Task 6: Kontur wyłącznie z rozwiązanych kontaktów

**Files:**
- Modify: `Sources/BubblePhysicsReference/Geometry/ContourGenerator.swift`
- Modify: `Sources/BubblePhysicsReference/Geometry/DirectionalDeformation.swift`
- Modify: `Sources/BubblePhysicsReference/Model/ReferenceBubble.swift`
- Rewrite: `Tests/BubblePhysicsReferenceTests/ContourGeneratorTests.swift`
- Delete: `Sources/BubblePhysicsReference/Solver/ReferenceDeformationLaw.swift`
- Delete: `Tests/BubblePhysicsReferenceTests/ReferenceDeformationLawTests.swift`

**Interfaces:**
- Consumes: końcowe kontakty, ich `Q`, normalne i ściski.
- Produces: gładki prosty kontur oraz naturalny okrąg przy braku kontaktów.

- [ ] **Step 1: Napisać testy RED konturu**

Testy: brak kontaktów daje dokładny okrąg; płaska krawędź tworzy szerokie spłaszczenie; narożnik wpływa na kilka próbek bez promienia zero; przeciwne kontakty nie sumują „dziury”; po usunięciu kontaktu następny kontur jest okręgiem; żaden punkt nie leży wewnątrz trójkąta.

- [ ] **Step 2: Uruchomić RED**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ContourGeneratorTests`

Expected: FAIL nowych asercji.

- [ ] **Step 3: Zaimplementować wspólną obwiednię ograniczeń**

Generator przyjmuje rozwiązane kontakty bez trwałej pamięci `directionalDeformations`. Dla każdego kąta wybiera najbardziej ograniczający kontakt, następnie wykonuje cykliczne wygładzenie zachowujące punkty kontaktu po dozwolonej stronie. Nie sumuje niezależnie głębokości nakładających się wgnieceń.

- [ ] **Step 4: GREEN i commit**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ContourGeneratorTests`

Expected: PASS.

```bash
git add Sources/BubblePhysicsReference/Geometry Sources/BubblePhysicsReference/Model/ReferenceBubble.swift Sources/BubblePhysicsReference/Solver Tests/BubblePhysicsReferenceTests
git commit -m "fix: derive bubble contours from solved contacts"
```

### Task 7: Walidacja wizualna, telemetria i regresja

**Files:**
- Modify: `Sources/BubblePhysicsReference/Visual/ReferenceVisualScene.swift`
- Modify: `Sources/BubblePhysicsReference/Visual/ReferenceVisualRunner.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/ReferenceVisualPrototypeView.swift`
- Modify: `Tests/BubblePhysicsReferenceTests/ReferenceVisualSceneTests.swift`
- Modify: `Tests/BubblePhysicsReferenceTests/ReferenceVisualRunnerTests.swift`
- Create: `Tests/BubblePhysicsReferenceTests/ReferenceDynamicAcceptanceTests.swift`
- Modify: `docs/benchmarks/iphone-x-reference-solver.md`

**Interfaces:**
- Consumes: poprawiony świat i kontury.
- Produces: kontrolowaną scenę urządzeniową i końcową bramkę automatyczną.

- [ ] **Step 1: Napisać testy akceptacyjne RED**

Sceny: pojedynczy nacisk; przeciwne naciski; łańcuch trzech baniek; narożnik; ścisk przy ścianie; szybki ruch wielokąta. Każda wymaga skończonych wartości, braku końcowej penetracji środka, oczekiwanego kierunku prędkości i deterministycznego wyniku. Test podziału czasu wymaga, aby błąd `dt` względem `dt/2` był większy niż błąd `dt/2` względem `dt/4`.

- [ ] **Step 2: Uruchomić RED**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter ReferenceDynamicAcceptanceTests`

Expected: FAIL do czasu spięcia sceny i telemetrii.

- [ ] **Step 3: Uprościć scenę i rozszerzyć dane**

Scena ma widoczne granice, małą liczbę baniek oraz wielokąt sterowany palcem. Panel pokazuje: Newton, PCG, grupy zdarzeń, limit zdarzeń, maksymalny ścisk, normę residualu, center guards i `non-finite`. Nie zasłania planszy.

- [ ] **Step 4: Uruchomić pełne testy targetu referencyjnego**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter BubblePhysicsReferenceTests`

Expected: wszystkie testy targetu PASS.

- [ ] **Step 5: Zbudować host iOS**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit i push**

```bash
git add Sources/BubblePhysicsReference Benchmarks/iOS/BubblePhysicsBench Tests/BubblePhysicsReferenceTests docs/benchmarks/iphone-x-reference-solver.md
git commit -m "test: validate dynamic contact solver visually"
git push origin HEAD
```

## Końcowa bramka urządzeniowa

Po automatycznej weryfikacji użytkownik uruchamia scenę na iPhonie X. Sprawdza
pojedynczy nacisk, nacisk z dwóch stron, łańcuch, narożnik, ścianę i szybki ruch.
Dopiero wynik wizualny zatwierdza model; benchmark 300 baniek następuje później.
