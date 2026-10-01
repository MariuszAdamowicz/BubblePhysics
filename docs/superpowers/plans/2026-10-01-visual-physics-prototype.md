# Visual Physics Prototype Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zbudować działający na iPhonie X wizualny prototyp deformowalnych baniek z chwytem, diagnostyką i poruszającym się kinematycznym trójkątem.

**Architecture:** Trwała `MetalSimulationSession` utrzymuje stan fizyki w buforach GPU, koduje pełny krok oraz udostępnia te same bufory rendererowi. `MetalBubbleRenderer` renderuje zdeformowane wachlarze, obrysy, etykiety i diagnostykę w `MTKView`, a SwiftUI pozostaje powłoką sterowania. Wybór bańki, chwyt i ruch trójkąta są wejściami sesji, a nie osobnymi kopiami świata CPU.

**Tech Stack:** Swift 5.9, Metal/MetalKit, SwiftUI, XCTest, Swift Package Manager, Xcode 26.6, iOS 16.

**Spec:** `docs/superpowers/specs/2026-10-01-visual-physics-prototype-design.md`

## Global Constraints

- Minimalny system to iOS 16; weryfikacja urządzenia odbywa się na iPhonie X z iOS 16.7.16.
- Build iOS musi używać `/Applications/Xcode-26.6.app`, nie `/Applications/Xcode.app`.
- Nie dodawać biblioteki 2D ani zewnętrznej zależności renderującej.
- Adaptacyjne `N` nie ma stałego górnego limitu; kod używa zakresów buforów.
- Geometria renderowana korzysta z buforów GPU sesji bez odczytu wszystkich pozycji do CPU co klatkę.
- W jednej klatce fizyka i renderowanie zachowują kolejność określoną w specyfikacji.
- Overflow, błąd Metal lub non-finite zatrzymuje sesję bez cichego fallbacku na CPU.
- Nie dodawać zmian podpisywania ani danych użytkownika Xcode do commitów.

## Review Focus

- Zmiana sceny 40/300 podczas aktywnego dotyku ma anulować chwyt i utworzyć spójne bufory nowej sesji.
- Adaptacyjne `N` większe od typowego przypadku musi generować pełny wachlarz i obrys bez wyjścia poza bufor.
- Dotyk poza bańkami ma pozostawić poprzednio zwolniony chwyt, bez wyboru przypadkowego identyfikatora.
- Pauza trójkąta ma wyzerować przekazywaną prędkość, nie tylko zatrzymać zmianę pozycji.
- Utrata drawable lub przejście aplikacji w tło ma pominąć klatkę bez uszkodzenia stanu sesji.

---

### Task 1: Deterministyczne sceny i ruch trójkąta

**Files:**
- Create: `Sources/BubblePhysics/PrototypeScene.swift`
- Test: `Tests/BubblePhysicsTests/PrototypeSceneTests.swift`

**Interfaces:**
- Produces: `PrototypeSceneSize`, `PrototypeSceneFactory.make(_:) -> BubbleWorld`, `KinematicTriangleMotion.sample(time:isPaused:) -> KinematicTriangleState`.
- Consumes: istniejące `BubbleWorld`, `RigidPolygon`, `Vector2` i `AABB`.

- [ ] **Step 1: Write the failing tests**

  Dodać testy: scena inspekcyjna ma 40 baniek, scena obciążeniowa 300; dwukrotne utworzenie wariantu daje identyczny snapshot; próbki trasy dla `t` i `t + period` są zgodne; próbka w pauzie ma zerową prędkość liniową i kątową.

- [ ] **Step 2: Run tests to verify RED**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter PrototypeSceneTests`
  Expected: FAIL, ponieważ interfejsy sceny nie istnieją.

- [ ] **Step 3: Implement the scene model**

  Zaimplementować oba deterministyczne układy w granicach ekranu i trójkąt poruszający się po ciągłej elipsie ze stałą prędkością kątową. `KinematicTriangleState` zawiera pozycję, kąt, prędkość liniową i kątową.

- [ ] **Step 4: Run tests to verify GREEN**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter PrototypeSceneTests`
  Expected: PASS.

- [ ] **Step 5: Commit**

  `git commit -m "feat: add deterministic visual prototype scenes"`

### Task 2: Geometria renderowania i orientacja etykiet

**Files:**
- Create: `Sources/BubblePhysicsMetal/Rendering/BubbleRenderGeometry.swift`
- Test: `Tests/BubblePhysicsMetalTests/BubbleRenderGeometryTests.swift`

**Interfaces:**
- Produces: `BubbleRenderGeometry.build(ranges:) -> BubbleRenderGeometryBuffers`, `BubbleMaterialAxis.pose(range:particles:) -> BubbleLabelPose`.
- Consumes: `MetalBubbleRange` i `MetalParticle`.

- [ ] **Step 1: Write the failing tests**

  Sprawdzić indeksy trójkątów i odcinków dla `N = 3`, typowego `N` oraz dużego `N`; każdy indeks musi należeć do zakresu bańki. Sprawdzić ciągłość kąta materialnej osi przy przejściu przez `-π/π` i brak wpływu promieniowej deformacji na skalę etykiety.

- [ ] **Step 2: Run tests to verify RED**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter BubbleRenderGeometryTests`
  Expected: FAIL z brakiem nowych typów.

- [ ] **Step 3: Implement geometry builders**

  Budować jeden ciąg indeksów wypełnień, obrysów i punktów diagnostycznych z dokładnych `boundaryStart/boundaryCount`. Materialna oś używa pierwszego stabilnego punktu brzegowego i rozwija kąt względem poprzedniej klatki.

- [ ] **Step 4: Run tests to verify GREEN**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter BubbleRenderGeometryTests`
  Expected: PASS.

- [ ] **Step 5: Commit**

  `git commit -m "feat: add adaptive bubble render geometry"`

### Task 3: Trwała sesja GPU

**Files:**
- Create: `Sources/BubblePhysicsMetal/MetalSimulationSession.swift`
- Modify: `Sources/BubblePhysicsMetal/MetalBubbleSolver.swift`
- Modify: `Sources/BubblePhysicsMetal/MetalSimulationEngine.swift`
- Test: `Tests/BubblePhysicsMetalTests/MetalSimulationSessionTests.swift`

**Interfaces:**
- Produces: `MetalSimulationSession.init(snapshot:device:)`, `encodeFrame(input:commandBuffer:) throws -> MetalFrameResources`, `reset(snapshot:) throws`, `status: MetalSessionStatus`.
- `MetalFrameResources` udostępnia tylko do odczytu bufory cząstek i zakresów, liczności, telemetrię oraz transformację trójkąta.
- Consumes: scenę z Task 1 i istniejące kernelle pełnego kroku Metal.

- [ ] **Step 1: Write the failing tests**

  Testy mają potwierdzić ponowne użycie tożsamości bufora cząstek między klatkami, zmianę bufora dopiero po resecie wymagającym większej pojemności, anulowanie chwytu przy resecie oraz zatrzymanie `status` po wymuszonym overflow/non-finite.

- [ ] **Step 2: Run tests to verify RED**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter MetalSimulationSessionTests`
  Expected: FAIL z brakiem `MetalSimulationSession`.

- [ ] **Step 3: Extract persistent allocation from `MetalBubbleSolver`**

  Przenieść bufory zależne od pojemności do sesji. `encodeFrame` koduje predykcję, broad phase, sąsiedztwo, kontakty, kształt, granice i interakcje do przekazanego `MTLCommandBuffer` bez `commit` ani oczekiwania pośrodku.

- [ ] **Step 4: Preserve compatibility**

  Istniejące publiczne metody solvera pozostają cienkimi adapterami tworzącymi krótkotrwałą sesję na potrzeby testów i benchmarków. `MetalSimulationEngine` korzysta z `solveFrame`, nie ze starej sekwencji shape/contact/interaction.

- [ ] **Step 5: Run session and existing Metal tests**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter MetalSimulationSessionTests && DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter BubblePhysicsMetalTests`
  Expected: PASS.

- [ ] **Step 6: Commit**

  `git commit -m "refactor: add persistent Metal simulation session"`

### Task 4: GPU picking i spokojny chwyt

**Files:**
- Create: `Sources/BubblePhysicsMetal/Shaders/InteractionKernels.metal`
- Create: `Sources/BubblePhysicsMetal/Interaction/MetalGrabController.swift`
- Modify: `Package.swift`
- Modify: `Sources/BubblePhysicsMetal/MetalSimulationSession.swift`
- Test: `Tests/BubblePhysicsMetalTests/MetalGrabControllerTests.swift`

**Interfaces:**
- Produces: `MetalGrabController.begin(at:)`, `move(to:timestamp:)`, `end()`, `encode(into:resources:)`.
- Consumes: współrzędne świata, bufory sesji i istniejący model `MetalGrab`.

- [ ] **Step 1: Write the failing tests**

  Przetestować wybór najwyżej renderowanej zachodzącej bańki, brak wyboru poza bańkami, najbliższy punkt brzegu, filtrowanie skoku celu, limit korekty oraz anulowanie po `end/reset`.

- [ ] **Step 2: Run tests to verify RED**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter MetalGrabControllerTests`
  Expected: FAIL.

- [ ] **Step 3: Implement picking and target filtering**

  Picking uruchamia kernel redukujący kandydatów do jednego identyfikatora i indeksu punktu zaczepienia. CPU odczytuje wyłącznie mały wynik wyboru przy rozpoczęciu dotyku. Kolejne ruchy aktualizują stały bufor celu po filtracji i ograniczeniu prędkości.

- [ ] **Step 4: Integrate grab constraint into session frame**

  Zakodować ograniczenie przed kontaktami i usunąć je natychmiast po `end`. Brak aktywnego chwytu nie koduje pustego przebiegu.

- [ ] **Step 5: Run tests to verify GREEN**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter MetalGrabControllerTests`
  Expected: PASS.

- [ ] **Step 6: Commit**

  `git commit -m "feat: add GPU bubble picking and resistant grab"`

### Task 5: Renderer Metal i atlas etykiet

**Files:**
- Create: `Sources/BubblePhysicsMetal/Rendering/MetalBubbleRenderer.swift`
- Create: `Sources/BubblePhysicsMetal/Rendering/BubbleLabelAtlas.swift`
- Create: `Sources/BubblePhysicsMetal/Shaders/RenderKernels.metal`
- Modify: `Package.swift`
- Test: `Tests/BubblePhysicsMetalTests/MetalBubbleRendererTests.swift`

**Interfaces:**
- Produces: `MetalBubbleRenderer.init(device:pixelFormat:)`, `rebuildSceneResources(ranges:labels:)`, `encode(frame:diagnostics:renderPass:drawableSize:commandBuffer:)`.
- Produces: `BubbleLabelAtlas.build(labels:device:)` przygotowujący wszystkie tekstury poza pętlą klatki.
- Consumes: `MetalFrameResources` z Task 3 i geometrię z Task 2.

- [ ] **Step 1: Write the failing tests**

  Przetestować rozmiary buforów dla 40/300, stabilne kolory z identyfikatora, kompletność atlasu etykiet, brak przebudowy atlasu przy niezmienionej scenie oraz bezpieczne pominięcie renderowania bez render pass/drawable.

- [ ] **Step 2: Run tests to verify RED**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter MetalBubbleRendererTests`
  Expected: FAIL.

- [ ] **Step 3: Implement fill, outline and diagnostics pipelines**

  Vertex shader pobiera pozycje bezpośrednio z bufora cząstek sesji. Fragment shader tworzy półprzezroczyste wypełnienie i gradient; osobne pipeline'y rysują brzeg, punkty i osie diagnostyczne. Rozmiar drawable jest mapowany na te same granice świata co fizyka.

- [ ] **Step 4: Implement labels**

  Zbudować atlas wszystkich wartości sceny podczas resetu i renderować quady o stałej skali, obrócone przez `BubbleLabelPose`.

- [ ] **Step 5: Run tests to verify GREEN**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter MetalBubbleRendererTests`
  Expected: PASS.

- [ ] **Step 6: Commit**

  `git commit -m "feat: render deformable bubbles with Metal"`

### Task 6: Integracja kinematycznego trójkąta

**Files:**
- Modify: `Sources/BubblePhysicsMetal/MetalSimulationSession.swift`
- Modify: `Sources/BubblePhysicsMetal/Shaders/PolygonKernels.metal`
- Modify: `Sources/BubblePhysicsMetal/Rendering/MetalBubbleRenderer.swift`
- Test: `Tests/BubblePhysicsMetalTests/MetalKinematicTriangleTests.swift`

**Interfaces:**
- Consumes: `KinematicTriangleState` z Task 1 jako część wejścia klatki.
- Produces: kolizję, transfer prędkości powierzchniowej oraz dane renderowania/diagnostyki trójkąta.

- [ ] **Step 1: Write the failing tests**

  Sprawdzić, że zatrzymany trójkąt wypycha bańkę bez nadawania prędkości, ruch liniowy przekazuje kierunkową prędkość, obrót przekazuje składową styczną, a długi przebieg nie tworzy non-finite.

- [ ] **Step 2: Run tests to verify RED**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter MetalKinematicTriangleTests`
  Expected: FAIL.

- [ ] **Step 3: Integrate polygon pass into the persistent frame**

  Aktualizować mały bufor transformacji trójkąta raz na klatkę i kodować kontakt wielokąta wewnątrz iteracji ograniczeń. Renderer korzysta z tych samych wierzchołków i transformacji.

- [ ] **Step 4: Run tests to verify GREEN**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter MetalKinematicTriangleTests`
  Expected: PASS.

- [ ] **Step 5: Commit**

  `git commit -m "feat: add animated kinematic triangle"`

### Task 7: Aplikacja MTKView, sterowanie i telemetria

**Files:**
- Replace: `Benchmarks/iOS/BubblePhysicsBench/App/BubblePhysicsBenchApp.swift`
- Create: `Benchmarks/iOS/BubblePhysicsBench/App/PrototypeViewModel.swift`
- Create: `Benchmarks/iOS/BubblePhysicsBench/App/MetalPrototypeView.swift`
- Create: `Benchmarks/iOS/BubblePhysicsBench/App/MetalPrototypeCoordinator.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/project.yml`
- Test: `Tests/BubblePhysicsMetalTests/FrameTelemetryTests.swift`

**Interfaces:**
- `MetalPrototypeCoordinator` implementuje `MTKViewDelegate`, koduje sesję i renderer do jednego command buffera oraz przekazuje dotyk do kontrolera chwytu.
- `PrototypeViewModel` publikuje wyłącznie stan sterowania, zagregowaną telemetrię i błąd sesji.

- [ ] **Step 1: Write the failing telemetry tests**

  Testować okno p50/p95, reset statystyk po zmianie sceny, zatrzymanie agregacji po błędzie i brak non-finite w prezentowanych wartościach.

- [ ] **Step 2: Run tests to verify RED**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test --filter FrameTelemetryTests`
  Expected: FAIL.

- [ ] **Step 3: Implement SwiftUI shell and MTKView coordinator**

  Dodać przełącznik `40/300`, pauzę, reset, diagnostykę i pauzę trójkąta. Obsłużyć początek/ruch/koniec dotyku w widoku Metal. Brak drawable pomija klatkę; wejście w tło pauzuje aktualizację bez niszczenia sesji.

- [ ] **Step 4: Implement throttled telemetry and visible failures**

  Publikować FPS, p50/p95, liczności i flagi najwyżej kilka razy na sekundę. Po błędzie zachować ostatni obraz, zatrzymać kroki i pokazać komunikat bez fallbacku CPU.

- [ ] **Step 5: Run package tests**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test`
  Expected: wszystkie testy PASS.

- [ ] **Step 6: Build the iOS app with Xcode 26.6**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer /Applications/Xcode-26.6.app/Contents/Developer/usr/bin/xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -configuration Release -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

  `git commit -m "feat: add interactive Metal physics prototype"`

### Task 8: Weryfikacja urządzenia i dokumentacja wyniku

**Files:**
- Modify: `README.md`
- Create: `docs/benchmarks/iphone-x-visual-prototype.md`

**Interfaces:**
- Consumes: gotową aplikację z Task 7.
- Produces: odtwarzalną instrukcję uruchomienia i tabelę wyników obu scen.

- [ ] **Step 1: Run final automated verification**

  Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer swift test`
  Expected: wszystkie testy PASS.

- [ ] **Step 2: Build and install with Xcode 26.6**

  Uruchomić aplikację na iPhonie X. Nie używać Xcode 27.

- [ ] **Step 3: Perform the inspection-scene checklist**

  Zweryfikować chwyt wolny i gwałtowny, opór w skupisku, deformację, powrót po puszczeniu, obrót etykiet, ruch/pauzę trójkąta oraz tryb diagnostyczny. Zapisać obserwowane nieprawidłowości bez strojenia ich w ciemno.

- [ ] **Step 4: Measure both scenes**

  Zebrać co najmniej 300 klatek po stabilizacji dla 40 i 300 baniek. Zapisać FPS, p50/p95, cząstki, kandydatów, kontakty, overflow i non-finite.

- [ ] **Step 5: Document and commit verified results**

  Uzupełnić instrukcję i wyniki, następnie `git commit -m "docs: record iPhone X visual prototype results"`.
