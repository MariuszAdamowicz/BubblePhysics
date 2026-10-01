# Fizyka deformowalnych konturów — plan implementacji

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zastąpić okrągłe przybliżenia kontaktów fizyką nieliniowych sprężyn i rzeczywistych, adaptacyjnych konturów, która wiarygodnie wypełnia przepełnioną planszę na iPhonie X.

**Architecture:** Stan materialny bańki przechowuje pierścień punktów, długości spoczynkowe i trzy rodziny nieliniowych sprężyn. GPU wykonuje predykcję, sprężyny, broad phase AABB, deterministyczne generowanie i redukcję kontaktów konturów, granice, wielokąty oraz rzadszy remeshing w trwałej sesji. Renderer korzysta z tych samych buforów, jawnych granic świata i filtrowanej osi materialnej.

**Tech Stack:** Swift 5.9, Metal compute/render shaders, MetalKit, XCTest, Xcode 26.6, iOS 16+.

**Spec:** `docs/superpowers/specs/2026-10-01-deformable-contour-physics-design.md`

## Global Constraints

- iPhone X i iOS 16 pozostają minimalnym fizycznym celem weryfikacji; buildy urządzenia wykonujemy wyłącznie Xcode 26.6.
- Pole powierzchni nie jest ograniczeniem solvera i nie może mieć minimalnego limitu.
- Minimalne `N` wynosi 8; model nie narzuca maksymalnego `N`.
- Kontakty nie mogą używać promienia wyprowadzonego z `restArea` ani odsuwać wyłącznie środków baniek.
- Overflow powoduje atomowy wzrost pojemności i ponowienie operacji, nigdy częściowe obcięcie danych.
- Nie wolno dodawać cichego fallbacku CPU dla sesji Metal.
- Zachować lokalne ustawienia podpisywania w `BubblePhysicsBench.xcodeproj/project.pbxproj`; nie dodawać ich do commitów.
- Każdy task kończy się testem i osobnym commitem wypchniętym do `MariuszAdamowicz/BubblePhysics`.

## Review Focus

- Zerowe lub niemal zerowe długości sprężyn i odcinków muszą pozostać finite — test w Task 2 i Task 4.
- Kontur wklęsły oraz kontakt wyłącznie przez skrzyżowanie krawędzi nie mogą zostać pominięte — test w Task 4.
- Remeshing przy `N == 8` nie może usunąć punktu, a wielokrotne przekroczenie pojemności nie może częściowo zmienić topologii — test w Task 6.
- Bańka większa od planszy nie może powodować overflow ani utraty kontaktów z małymi bańkami — test w Task 7.
- Zmiana rozdzielczości drawable i orientacji widoku nie może zmieniać współrzędnych świata ani położenia chwytu — test w Task 1 i Task 8.

---

### Task 1: Jawne mapowanie świata na drawable

**Files:**
- Modify: `Sources/BubblePhysicsMetal/Rendering/MetalBubbleRenderer.swift`
- Modify: `Sources/BubblePhysicsMetal/Shaders/RenderKernels.metal`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/BubblePhysicsBenchApp.swift`
- Test: `Tests/BubblePhysicsMetalTests/MetalWorldViewportTests.swift`

**Interfaces:**
- Produces: `MetalWorldViewport(worldBounds:drawableSize:)`, `worldToClip(_:)`, `viewToWorld(_:)`.
- Consumes: `PrototypeSceneFactory.bounds` oraz rozmiar drawable/view.

- [ ] **Step 1: Write failing viewport tests** — sprawdzić narożniki `375×812` dla drawable `1125×2436`, zachowanie proporcji dla innego aspektu oraz odwracalność punktu chwytu.
- [ ] **Step 2: Run RED** — `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter MetalWorldViewportTests`; oczekiwany brak `MetalWorldViewport`.
- [ ] **Step 3: Implement viewport** — renderer otrzymuje `worldBounds`, shader używa transformacji świata zamiast pikseli drawable, a coordinator używa `viewToWorld` dla dotyku.
- [ ] **Step 4: Run GREEN and renderer regression** — uruchomić `MetalWorldViewportTests` i `MetalBubbleRendererTests`.
- [ ] **Step 5: Commit** — `fix: map physics world across full drawable`.

### Task 2: Nieliniowy materiał sprężynowy bez ograniczenia pola

**Files:**
- Create: `Sources/BubblePhysics/SpringMaterial.swift`
- Modify: `Sources/BubblePhysics/WorldConfiguration.swift`
- Modify: `Sources/BubblePhysics/BubbleTopology.swift`
- Modify: `Sources/BubblePhysics/BubbleWorld.swift`
- Modify: `Sources/BubblePhysicsMetal/MetalBufferLayout.swift`
- Modify: `Sources/BubblePhysicsMetal/MetalWorldSnapshot.swift`
- Modify: `Sources/BubblePhysicsMetal/Shaders/BubblePhysicsKernels.metal`
- Test: `Tests/BubblePhysicsTests/SpringMaterialTests.swift`
- Test: `Tests/BubblePhysicsMetalTests/MetalSpringSolverTests.swift`

**Interfaces:**
- Produces: `SpringMaterial(quadraticStiffness:quarticStiffness:drag:)`, `springForce(extension:)`, `MetalSpringConstraint` z rodzajem `.radial/.perimeter/.bending`.
- Consumes: bieżące cząstki i materialne długości spoczynkowe.

- [ ] **Step 1: Write failing material tests** — siła ma być nieparzysta, monotoniczna dla kompresji 10/50/90%, finite przy długości `1e-7`, a swobodna prędkość ma maleć zgodnie z `exp(-drag*dt)`.
- [ ] **Step 2: Run RED** — uruchomić `SpringMaterialTests` i potwierdzić brak typów.
- [ ] **Step 3: Implement CPU material and topology encoding** — zastąpić twarde `DistanceConstraint` trzema rodzinami `MetalSpringConstraint`; usunąć aktywne `AreaConstraint` z kroku solvera, zachowując `restArea` wyłącznie jako metadane gry/diagnostyki.
- [ ] **Step 4: Implement Metal spring pass** — kodować nieliniową siłę/XPBD w osobnym przebiegu bez projekcji pola; zerowa długość używa stabilnego kierunku materialnego albo pomija osobliwy gradient bez NaN.
- [ ] **Step 5: Run GREEN and full CPU regression** — `swift test --filter 'SpringMaterialTests|MetalSpringSolverTests|XPBDTests'`.
- [ ] **Step 6: Commit** — `feat: add nonlinear spring bubble material`.

### Task 3: Deterministyczne rekordy kontaktów konturu

**Files:**
- Create: `Sources/BubblePhysics/Collision/ContourContact.swift`
- Create: `Sources/BubblePhysicsMetal/Shaders/ContourContactKernels.metal`
- Modify: `Package.swift`
- Modify: `Sources/BubblePhysicsMetal/MetalBufferLayout.swift`
- Modify: `Sources/BubblePhysicsMetal/MetalSimulationSession.swift`
- Test: `Tests/BubblePhysicsTests/ContourContactTests.swift`
- Test: `Tests/BubblePhysicsMetalTests/MetalContourContactLayoutTests.swift`

**Interfaces:**
- Produces: `ContourContact(pointIndex:edgeStartIndex:edgeEndIndex:barycentric:normal:penetration:sourceID:)`, liczenie i zapis stałych zakresów cech dla pary.
- Consumes: pary AABB oraz aktualne zakresy punktów.

- [ ] **Step 1: Write failing geometry tests** — punkt wewnątrz konturu, najbliższy odcinek i barycentria, przecięcie dwóch odcinków bez zawartych wierzchołków, kontur wklęsły i osobliwy odcinek.
- [ ] **Step 2: Run RED** — `swift test --filter ContourContactTests`.
- [ ] **Step 3: Implement CPU reference** — czysta geometria stanowi wzorzec dla kernela i nie uczestniczy w runtime iOS.
- [ ] **Step 4: Add Metal records and capacity buffers** — zakres źródła jest stabilny według `(pair, direction, feature)`, a overflow jest wykrywalny przed zastosowaniem korekt.
- [ ] **Step 5: Run GREEN/layout tests** — uruchomić oba zestawy testów.
- [ ] **Step 6: Commit** — `feat: define deterministic contour contacts`.

### Task 4: GPU narrow phase i zachowanie reakcji

**Files:**
- Modify: `Sources/BubblePhysicsMetal/Shaders/ContourContactKernels.metal`
- Modify: `Sources/BubblePhysicsMetal/Shaders/ContactKernels.metal`
- Modify: `Sources/BubblePhysicsMetal/MetalBubbleSolver.swift`
- Modify: `Sources/BubblePhysicsMetal/MetalSimulationSession.swift`
- Test: `Tests/BubblePhysicsMetalTests/MetalContourContactTests.swift`

**Interfaces:**
- Produces: `encodeContourContacts(snapshot:buffers:commandBuffer:)`, telemetry `contourContactCount`.
- Consumes: rekordy i zakresy z Task 3; sort/reduce istniejących korekt cząstek.

- [ ] **Step 1: Write failing GPU tests** — porównać CPU/GPU dla punkt–odcinek, crossing-only i konturu wklęsłego; suma zmian pędu pary ma mieścić się w tolerancji 1%; wynik ma być finite dla odcinka długości `1e-7`.
- [ ] **Step 2: Run RED** — `swift test --filter MetalContourContactTests`.
- [ ] **Step 3: Implement count/write/solve passes** — usunąć `generateAdjacencyCorrections` z aktywnej klatki; korekta trafia do punktu i końców odcinka według mas i barycentrii, następnie jest deterministycznie sortowana i redukowana.
- [ ] **Step 4: Keep current AABB broad phase** — kandydaci wynikają wyłącznie z aktualnych konturów; usunąć użycie `sqrt(restArea/pi)` z aktywnego narrow phase.
- [ ] **Step 5: Run GREEN and contact regression** — `swift test --filter 'MetalContourContactTests|MetalContactSolverTests|MetalBroadPhaseTests'`.
- [ ] **Step 6: Commit** — `feat: solve real contour contacts on GPU`.

### Task 5: Samokolizja, granice i wielokąty w jednym modelu

**Files:**
- Modify: `Sources/BubblePhysicsMetal/Shaders/ContourContactKernels.metal`
- Modify: `Sources/BubblePhysicsMetal/Shaders/PolygonKernels.metal`
- Modify: `Sources/BubblePhysicsMetal/MetalBubbleSolver.swift`
- Test: `Tests/BubblePhysicsMetalTests/MetalUnifiedContactTests.swift`

**Interfaces:**
- Produces: kontakty niesąsiadujących segmentów własnego konturu, statycznych granic i `MetalInteractionPolygon` jako te same korekty cząstek.
- Consumes: reducer kontaktów z Task 4.

- [ ] **Step 1: Write failing tests** — złożony kontur nie przechodzi przez siebie; bańka może zostać wielokrotnie spłaszczona w rogu; zatrzymany/ruchomy/obracany trójkąt daje odpowiednio zerową/liniową/styczną prędkość powierzchniową.
- [ ] **Step 2: Run RED** — `swift test --filter MetalUnifiedContactTests`.
- [ ] **Step 3: Implement unified contacts** — pomijać segmenty sąsiednie w samokolizji; granice są czterema statycznymi odcinkami; ruch wielokąta modyfikuje `previousPosition` zgodnie z prędkością powierzchni.
- [ ] **Step 4: Run GREEN and polygon regression** — uruchomić testy unified, `MetalKinematicTriangleTests` i `PolygonContactTests`.
- [ ] **Step 5: Commit** — `feat: unify contour environment contacts`.

### Task 6: Adaptacyjny remeshing z zachowaniem materiału

**Files:**
- Create: `Sources/BubblePhysics/AdaptiveContourRemesher.swift`
- Create: `Sources/BubblePhysicsMetal/Shaders/RemeshKernels.metal`
- Modify: `Package.swift`
- Modify: `Sources/BubblePhysicsMetal/MetalSimulationSession.swift`
- Modify: `Sources/BubblePhysicsMetal/MetalWorldSnapshot.swift`
- Test: `Tests/BubblePhysicsTests/AdaptiveContourRemesherTests.swift`
- Test: `Tests/BubblePhysicsMetalTests/MetalRemeshingTests.swift`

**Interfaces:**
- Produces: `RemeshPolicy(splitLength:mergeLength:persistenceFrames:cooldownFrames:)`, `RemeshPlan`, GPU mark/prefix/compact/rebuild oraz `capacityGrowthRequired`.
- Consumes: materialne długości i sprężyny z Task 2.

- [ ] **Step 1: Write failing CPU reference tests** — split dzieli długość spoczynkową, merge ją sumuje, nowa prędkość jest interpolowana, `N == 8` nie maleje, progi z histerezą nie oscylują, energia sprężysta zmienia się najwyżej o 2% bez tłumienia.
- [ ] **Step 2: Run RED** — `swift test --filter AdaptiveContourRemesherTests`.
- [ ] **Step 3: Implement CPU planner** — służy jako deterministyczna referencja i generator oczekiwanych wyników.
- [ ] **Step 4: Implement GPU remeshing** — mark, prefix sum, kompaktowanie i odbudowa zakresów; zmiana jest atomowa, a brak pojemności nie modyfikuje aktywnych buforów.
- [ ] **Step 5: Implement persistent growth/retry** — sesja podwaja potrzebne bufory na bezpiecznej granicy klatki, zachowuje stan i ponawia plan; dwa kolejne wzrosty także nie mogą częściowo zmienić topologii.
- [ ] **Step 6: Run GREEN and long remesh test** — `swift test --filter 'AdaptiveContourRemesherTests|MetalRemeshingTests|MetalSimulationSessionTests'`.
- [ ] **Step 7: Commit** — `feat: adapt contour resolution on GPU`.

### Task 7: Sceny wieloskalowe i test przepełnienia

**Files:**
- Modify: `Sources/BubblePhysics/PrototypeScene.swift`
- Modify: `Sources/BubblePhysics/BenchmarkScenario.swift`
- Test: `Tests/BubblePhysicsTests/PrototypeSceneTests.swift`
- Test: `Tests/BubblePhysicsMetalTests/MetalPackedSceneTests.swift`

**Interfaces:**
- Produces: dokładne rozkłady wartości scen 40/300 ze specyfikacji oraz etykiety wartości niezależne od `BubbleID`.
- Consumes: materiał, kontakty i remeshing z Tasks 2–6.

- [ ] **Step 1: Write failing distribution tests** — sprawdzić dokładne liczności wartości, zależność pola `A₂*v/2`, promień spoczynkowy `2048 > 375` i deterministyczne rozmieszczenie.
- [ ] **Step 2: Write failing behavior tests** — wielka bańka styka się z małymi po kompresji, 300 baniek nie gubi kontaktów/nie daje non-finite, a przestrzeń za pełnym cyklem trójkąta maleje zamiast pozostawać trwałą kieszenią.
- [ ] **Step 3: Run RED** — uruchomić `PrototypeSceneTests` i `MetalPackedSceneTests`.
- [ ] **Step 4: Implement scene seeds and labels** — inicjalizacja może rozpoczynać się z nakładaniem; solver ma rozwiązać przepełnienie bez okrągłych skrótów.
- [ ] **Step 5: Run GREEN** — uruchomić oba zestawy co najmniej dwukrotnie dla deterministyczności.
- [ ] **Step 6: Commit** — `feat: add multiscale packed bubble scenes`.

### Task 8: Stabilna oś etykiety i pełna telemetria

**Files:**
- Modify: `Sources/BubblePhysicsMetal/Rendering/BubbleRenderGeometry.swift`
- Modify: `Sources/BubblePhysicsMetal/Rendering/MetalBubbleRenderer.swift`
- Modify: `Sources/BubblePhysicsMetal/Shaders/RenderKernels.metal`
- Modify: `Sources/BubblePhysicsMetal/FrameTelemetry.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/BubblePhysicsBenchApp.swift`
- Test: `Tests/BubblePhysicsMetalTests/BubbleMaterialAxisTests.swift`
- Test: `Tests/BubblePhysicsMetalTests/FrameTelemetryTests.swift`

**Interfaces:**
- Produces: `BubbleMaterialAxis.update(materialSamples:deltaTime:)`, filtrowany kąt/prędkość kątową oraz liczniki faz konturu/remeshingu.
- Consumes: materialne indeksy po remeshingu i telemetryczne liczniki Tasks 4–7.

- [ ] **Step 1: Write failing axis tests** — brak skoku przy `-π/π`, pojedynczy lokalny impuls nie obraca gwałtownie napisu, stały obrót pozostaje widoczny, zmiana `N` zachowuje ciągłość.
- [ ] **Step 2: Write failing telemetry tests** — wszystkie czasy i liczniki są finite, reset sceny zeruje okno, błąd zatrzymuje agregację.
- [ ] **Step 3: Run RED** — uruchomić oba zestawy.
- [ ] **Step 4: Implement GPU label instances and telemetry** — oś jest filtrowana z kilku próbek materialnych; UI pokazuje punkty, segmenty, pary, kontakty, remeshing, p50/p95, overflow i non-finite.
- [ ] **Step 5: Run GREEN** — uruchomić testy osi, renderera i telemetrii.
- [ ] **Step 6: Commit** — `feat: stabilize labels and contour telemetry`.

### Task 9: Weryfikacja końcowa i iPhone X

**Files:**
- Modify: `docs/benchmarks/iphone-x-visual-prototype.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: kompletny solver i aplikację Tasks 1–8.
- Produces: odtwarzalny wynik scen 40/300 i listę obserwacji jakościowych.

- [ ] **Step 1: Run package verification** — `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test`; oczekiwane wszystkie testy PASS.
- [ ] **Step 2: Build iOS Release** — uruchomić Xcode 26.6 `xcodebuild` dla `generic/platform=iOS` z `CODE_SIGNING_ALLOWED=NO`; oczekiwane `BUILD SUCCEEDED`.
- [ ] **Step 3: Run on iPhone X** — sprawdzić pełny ekran i zgodność chwytu po zmianie rozdzielczości; wykonać checklistę sceny 40.
- [ ] **Step 4: Measure packed scene** — zebrać minimum 300 ustabilizowanych klatek sceny 300 i zapisać telemetrię; wielka bańka musi pozostać w kontakcie z małymi bez non-finite i utraconych kontaktów.
- [ ] **Step 5: Record results and issues** — nie stroić w ciemno; każde odstępstwo zapisać z reprodukcją przed kolejną zmianą materiału.
- [ ] **Step 6: Commit** — `docs: record deformable contour device results`.
