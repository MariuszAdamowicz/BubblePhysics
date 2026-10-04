# Stress Equilibrium Solver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zastąpić bezpośrednie rozsuwanie środków solverem deformacja → naprężenie → równowaga Newton–PCG oraz zweryfikować go w poprawionej scenie `CPU Wiz`.

**Architecture:** Aktywne kontakty lokalnie wyznaczają podział deformacji i nieliniowe naprężenie. Dla ustalonego grafu kontaktów macierzowy operator Gaussa–Newtona i blokowy preconditioner zasilają PCG, a pętla zewnętrzna odświeża kontakty po każdym tłumionym kroku. Osobny CCD niepogrubionego odcinka chroni wyłącznie topologię środka.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, SwiftUI Canvas, iOS 16+, Xcode 26.6.

**Spec:** `docs/superpowers/specs/2026-10-03-stress-equilibrium-solver-design.md`

## Global Constraints

- Zachowaj istniejący przebieg kontaktów i publiczny punkt wejścia `ReferenceEquilibriumSolver.solve`.
- Kontakt najpierw deformuje powierzchnię; nie wolno przesuwać środka bezpośrednio o penetrację powierzchni.
- Operator Newtona pozostaje matrix-free i przechodzi liniowo po aktywnych kontaktach.
- Ochrona środka używa niepogrubionego, skończonego odcinka i nie zastępuje reakcji sprężystej.
- Pełny kontur nie uczestniczy w solverze ani CCD.
- CPU jest wzorcem poprawności; ten plan nie portuje solvera do Metal.
- Aplikacja urządzeniowa buduje się w Release przez `/Applications/Xcode-26.6.app`.

## Review Focus

- Zerowa albo niemal zerowa odległość środków musi dać skończone naprężenie i deterministyczną normalną — test w Task 1.
- Operator musi pozostać dodatnio określony również dla bańki bez kontaktów — test w Task 2.
- Zmiana aktywnego zbioru podczas line search nie może zaakceptować kroku zwiększającego energię — test w Task 3.
- Przejście środka dokładnie przez ruchomy koniec odcinka musi zostać wykryte, ale minięcie końca nie — testy w Task 4.
- Reset sceny po dowolnej liczbie klatek musi odtworzyć identyczne wartości, promienie i położenia — test w Task 5.

---

### Task 1: Nieliniowa deformacja i stan naprężenia kontaktu

**Files:**
- Create: `Sources/BubblePhysicsReference/Solver/ReferenceDeformationLaw.swift`
- Modify: `Sources/BubblePhysicsReference/Model/ReferenceContact.swift`
- Modify: `Sources/BubblePhysicsReference/Model/ReferenceConfiguration.swift`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceContactSet.swift`
- Modify: `Sources/BubblePhysicsReference/Geometry/DiscreteContactGenerator.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceDeformationLawTests.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceContactSetTests.swift`
- Test: `Tests/BubblePhysicsReferenceTests/DiscreteContactGeneratorTests.swift`

**Interfaces:**
- Produces: `ReferenceContactStress(compressionA:compressionB:pressure:effectiveStiffness:)`.
- Produces: `ReferenceDeformationLaw.solve(requiredCompression:radiusA:stiffnessA:radiusB:stiffnessB:nonlinearStiffening:) -> ReferenceContactStress` oraz wariant sztywnego odcinka bez `radiusB`.
- Produces: pola `compressionA`, `compressionB`, `pressure`, `effectiveStiffness` w `ReferenceContact`, zachowywane przez histerezę.

- [ ] **Step 1: Write failing deformation-law tests**

Dodaj testy: zero konfliktu daje zera; kontakt ze sztywnym odcinkiem przypisuje cały ścisk bańce; dwie identyczne bańki dzielą `6` jako `3 + 3`; miększa bańka przejmuje większą część; `pressure` i `effectiveStiffness` rosną pomiędzy ściskiem `1` i `8`; promień `8` ściśnięty o `8` pozostaje skończony. W `DiscreteContactGeneratorTests` dodaj osobny przypadek środków odległych o `1e-8`, wymagający deterministycznej skończonej normalnej, penetracji i stanu naprężenia.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter ReferenceDeformationLawTests`

Expected: FAIL, ponieważ typy prawa deformacji nie istnieją.

- [ ] **Step 3: Implement local compression allocation**

Użyj energii i pochodnej ze specyfikacji. Dla dwóch baniek znajdź równy nacisk metodą deterministycznej bisekcji na przedziale `0...requiredCompression`; dla odcinka zwróć `compressionA = requiredCompression`. Dodaj do konfiguracji `maximumContactPressure = 1_000_000` i ogranicz wyłącznie wartość używaną numerycznie, nie geometryczną deformację.

- [ ] **Step 4: Preserve stress state across contact-set updates**

Przy zachowaniu kontaktu skopiuj cztery pola naprężenia razem z wiekiem. Nowy kontakt zaczyna od zerowego stanu.

- [ ] **Step 5: Run reference suite**

Run: `swift test --filter BubblePhysicsReferenceTests`

Expected: PASS.

- [ ] **Step 6: Commit**

`git commit -m "feat: model nonlinear contact stress"`

### Task 2: Matrix-free operator i PCG

**Files:**
- Create: `Sources/BubblePhysicsReference/Solver/ReferenceStressSystem.swift`
- Create: `Sources/BubblePhysicsReference/Solver/ReferencePCGSolver.swift`
- Modify: `Sources/BubblePhysicsReference/Model/ReferenceConfiguration.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceStressSystemTests.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferencePCGSolverTests.swift`

**Interfaces:**
- Consumes: `ReferenceContactStress` z Task 1.
- Produces: `ReferenceStressContribution(indexA:indexB:normal:pressure:effectiveStiffness:)`.
- Produces: `ReferenceStressSystem.residual(centers:)`, `applyJacobian(to:)`, `inverseDiagonalPreconditioner()`.
- Produces: `ReferencePCGSolver.solve(rightHandSide:apply:inverseDiagonal:tolerance:iterationLimit:) -> ReferencePCGResult`.

- [ ] **Step 1: Write failing operator and PCG tests**

Sprawdź ręcznie: pojedynczy kontakt daje równe przeciwne reszty; dwa równe przeciwne kontakty dają zerową resztę środka; składnik bezwładności kotwiczy izolowaną bańkę; `dot(v, Jv) > 0` dla niezerowego `v`; operator jest symetryczny z tolerancją `1e-5`; PCG rozwiązuje literalny układ SPD `[[4,1],[1,3]]·x=[1,2]` do `x=[1/11,7/11]`; zerowa prawa strona kończy się bez iteracji.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'Reference(StressSystem|PCGSolver)Tests'`

Expected: FAIL, ponieważ operator i PCG nie istnieją.

- [ ] **Step 3: Implement the stress system**

Indeksuj środki w stabilnej kolejności `ReferenceBubbleID`. Operator dodaje `mass / dt²` na przekątnej oraz kontaktowe bloki `k_eff·n·nᵀ`; kontakt z odcinkiem nie ma `indexB`. Preconditioner jest odwrotnością dwóch diagonalnych składowych każdego bloku z dolnym ograniczeniem `Float.ulpOfOne`.

- [ ] **Step 4: Implement deterministic PCG**

Dodaj do konfiguracji `pcgTolerance = 0.001`, `pcgIterationLimit = 24` oraz `stressTolerance = 0.01`. Zatrzymuj PCG po osiągnięciu względnej normy reszty, zerowej prawej stronie, limicie albo wykryciu wartości niefinitywnej. Wynik raportuje iteracje, normę początkową, końcową i `hasNonFiniteState`.

- [ ] **Step 5: Run reference suite**

Run: `swift test --filter BubblePhysicsReferenceTests`

Expected: PASS.

- [ ] **Step 6: Commit**

`git commit -m "feat: add matrix-free stress PCG"`

### Task 3: Integracja Newton–PCG z aktywnym zbiorem

**Files:**
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceEquilibriumSolver.swift`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceSolverReport.swift`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceWorld.swift`
- Modify: `Sources/BubblePhysicsReference/Geometry/DiscreteContactGenerator.swift`
- Modify: `Sources/BubblePhysicsReference/Geometry/SupportRadius.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceEquilibriumSolverTests.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceWorldTests.swift`

**Interfaces:**
- Consumes: `ReferenceStressSystem` i `ReferencePCGSolver` z Task 2.
- Produces: dotychczasowe `ReferenceEquilibriumSolver.solve(...) -> ReferenceSolverReport`, lecz bez `projectOut` i `separatePair`.
- Produces: rozszerzony raport `pcgIterationCount`, `initialResidualNorm`, `finalResidualNorm`, `maximumRelativeDeformation`, `lineSearchFailureCount`.

- [ ] **Step 1: Replace positional-correction expectations with failing stress-equilibrium tests**

Testy muszą wykazać: pojedynczy nacisk tworzy deformację przed ruchem środka; dwa symetryczne naciski deformują bez przesunięcia środka większego niż `0.01`; lżejsza bańka przesuwa się dalej przy tym samym naprężeniu; trzy bańki przekazują nacisk do końca łańcucha; deformacja niemal do promienia pozostaje skończona; brak kontaktów zachowuje przewidywane położenie; line search nie zwiększa energii; zmiana kontaktów w kroku nie pozostawia nieaktualnego naprężenia; przypadek coincident centers jest deterministyczny.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter ReferenceEquilibriumSolverTests`

Expected: FAIL na oczekiwaniach deformacji i raportu, ponieważ działa stary solver korekt pozycji.

- [ ] **Step 3: Build stress contributions and directional deformations**

Dla każdego kontaktu oblicz dokładny ścisk z aktualnych `supportRadius`, wywołaj prawo deformacji, zapisz pola kontaktu i odtwórz `directionalDeformations` baniek z aktywnego zbioru. Deformacja kontaktu bańka–bańka ma kierunek do drugiej bańki; deformacja odcinka kierunek od środka ku `Q`.

- [ ] **Step 4: Replace sequential projection with damped Newton–PCG**

W każdej iteracji zewnętrznej zbuduj `ReferenceStressSystem`, rozwiąż krok PCG i wybierz `λ` z sekwencji `1, 1/2, 1/4, 1/8, 1/16, 1/32`; zaakceptuj pierwszy skończony krok zmniejszający energię. Po kroku odśwież kandydatów i aktywny zbiór. Zakończ po stabilizacji kontaktów, `finalResidualNorm <= stressTolerance` i małym kroku albo po `solverIterations`.

- [ ] **Step 5: Update velocity exactly once**

W `ReferenceWorld` usuń dodawanie `solverVelocityChange`. Ustal `velocity = (center - previousCenter) / dt`, a następnie zastosuj tłumienie. Tarcie pozostaw do Task 4.

- [ ] **Step 6: Run reference suite**

Run: `swift test --filter BubblePhysicsReferenceTests`

Expected: PASS bez `non-finite`.

- [ ] **Step 7: Commit**

`git commit -m "feat: solve bubble stress equilibrium"`

### Task 4: Ochrona środka oraz ograniczone tarcie

**Files:**
- Create: `Sources/BubblePhysicsReference/CCD/CenterSegmentTOI.swift`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceWorld.swift`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceEquilibriumSolver.swift`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceWorldStepReport.swift`
- Test: `Tests/BubblePhysicsReferenceTests/CenterSegmentTOITests.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceWorldTests.swift`

**Interfaces:**
- Produces: `ReferenceCenterSegmentTOI.firstIntersection(bubble:segment:tolerance:) -> TimeOfImpactResult`.
- Produces: `centerGuardCount` w raporcie świata.

- [ ] **Step 1: Write failing unthickened-trajectory tests**

Dodaj przypadki: nieruchomy odcinek przecięty przez ruchomy środek; poruszający się odcinek przecinający nieruchomy środek; obracający się odcinek; trafienie dokładnie w poruszający się koniec; zmiana strony poza końcem daje `.none`; tor styczny bez przecięcia daje `.none`; ściana jednostronna nadal zachowuje półpłaszczyznę.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter CenterSegmentTOITests`

Expected: FAIL, ponieważ nowy test CCD środka nie istnieje.

- [ ] **Step 3: Implement exact center/segment intersection**

Dla liniowo interpolowanych `P(t)`, `A(t)`, `B(t)` rozwiąż kwadratowe równanie `cross(P(t)-A(t), B(t)-A(t)) = 0`. Zachowaj najmniejszy pierwiastek `t ∈ [0,1]`, dla którego parametr rzutu na odcinek należy do `[0,1]`. Obsłuż degenerację do równania liniowego i deterministycznie odrzuć ruch styczny bez zmiany strony.

- [ ] **Step 4: Apply only the minimal guard correction**

Po rozwiązaniu sprężystym sprawdź wszystkie segmenty świata, niezależnie od bieżącego kontaktu powierzchniowego. Przy przecięciu cofnij środek do `t - positionTolerance`, zwiększ `centerGuardCount`, lecz nie twórz z tej korekty dodatkowej deformacji ani prędkości. Dla ścian jednostronnych zachowaj kontrolę półpłaszczyzny.

- [ ] **Step 5: Bound tangential transfer and rotation**

Moment styczny ogranicz przez `surfaceFriction * pressure * dt`; zmianę prędkości kątowej podziel przez `0.5 * mass * targetRadius²`. Przy `surfaceFriction = 0` test oczekuje niezmienionej prędkości kątowej, a przy tarciu — skończonego obrotu bez przekroczenia ruchu powierzchni segmentu.

- [ ] **Step 6: Run reference suite**

Run: `swift test --filter BubblePhysicsReferenceTests`

Expected: PASS.

- [ ] **Step 7: Commit**

`git commit -m "feat: guard bubble centers against segments"`

### Task 5: Poprawiona scena `CPU Wiz` i telemetria

**Files:**
- Modify: `Sources/BubblePhysicsReference/Visual/ReferenceVisualScene.swift`
- Modify: `Sources/BubblePhysicsReference/Visual/ReferenceVisualRunner.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/ReferenceVisualPrototypeView.swift`
- Modify: `docs/benchmarks/iphone-x-reference-solver.md`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceVisualSceneTests.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceVisualRunnerTests.swift`

**Interfaces:**
- Consumes: rozszerzone raporty z Task 3 i Task 4.
- Produces: `ReferenceVisualScene.valuesByBubbleID: [ReferenceBubbleID: Int]` i to samo pole w `ReferenceVisualSnapshot`.
- Produces: deterministyczną scenę bez środka bańki wewnątrz początkowego trójkąta.

- [ ] **Step 1: Write failing value, placement and reset tests**

Użyj wartości `[2,4,8,16,32,64,128,256,512,1024,2048]` oraz promieni `[8,11,16,22,30,39,49,58,66,72,75]`. Każde powtórzenie wartości ma identyczny promień, a większa wartość nigdy nie ma mniejszego promienia. Sprawdź 40 baniek, brak środka wewnątrz trójkąta, brak początkowej penetracji większej niż `2`, deterministyczny reset i niezmienne mapowanie etykiet po 180 klatkach.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter ReferenceVisual`

Expected: FAIL, ponieważ etykiety nadal wynikają z `id`, a początkowa siatka przecina trójkąt.

- [ ] **Step 3: Implement deterministic packed placement**

Rozmieść 40 baniek największa-pierwsza deterministycznym przeszukaniem punktów planszy co `4` jednostki, z odstępem `2` i odrzuceniem punktów wewnątrz trójkąta powiększonego o promień. Jeśli pełny promień nie mieści się bez penetracji `2`, zmniejsz liczbę powtórzeń największych wartości, ale zachowaj co najmniej jedną bańkę każdej z 11 wartości i łącznie 40 obiektów.

- [ ] **Step 4: Render mapped values and expanded telemetry**

Renderer pobiera tekst wyłącznie z `snapshot.valuesByBubbleID`. Panel pokazuje iteracje zewnętrzne/PCG, normę naprężeń początkową/końcową, maksymalną deformację względną, penetrację, `centerGuardCount`, nieudane line search oraz `non-finite`.

- [ ] **Step 5: Verify package and Release iOS build**

Run: `swift test --filter BubblePhysicsReferenceTests`

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

Expected: oba polecenia kończą się sukcesem.

- [ ] **Step 6: Install and evaluate on iPhone X**

Uruchom Release w Xcode 26.6. CEO ocenia kolejno: zgodność numeru z rozmiarem, deformację przed ruchem środka, brak gwałtownego wirowania, opróżnienie wnętrza trójkąta, wypełnianie przestrzeni za przeszkodą i liczniki zbieżności.

- [ ] **Step 7: Commit and push**

`git commit -m "feat: validate stress equilibrium visually"`

`git push`
