# Plan: BubblePhysics — engine-owned integracja ograniczonego 2KBubbles

**Data:** 2026-10-25

**Status:** Approved

**Strategia:** slices

**Wersja pluginu:** 0.1.29

**Sesje agenta:** unknown: UNKNOWN

**Upstream:** design.md (Approved)

---

## Program design

**R0 — cel.** BubblePhysics dostarcza trzy niezależne, publiczne granice: semantyczną prezentację bańki, wybór deformowanego konturu oraz semantyczny spawn z fizyczną areną. Gra nie otrzymuje geometrii, renderera ani wyboru backendu.

**R1 — przepływ.** Gra składa WorldTransaction z semantycznymi żądaniami. BubbleWorld stageruje batch, native Metal wylicza fizykę/deformację, renderer koduje tę samą opublikowaną geometrię w tym samym command bufferze, a WorldFrame publikuje receipts, zdarzenia i DriveFeedback. Żądanie hit-testu ma numer, wykonuje się w najbliższym ukończonym kroku i wraca po publikacji tej klatki.

**R2 — potwierdzone seam’y.** Publiczna granica znajduje się w Sources/BubblePhysicsPublic/BubbleWorld.swift i Model/WorldTransaction.swift; BubbleDescriptor w Model/Objects.swift dziś wymaga position. Staging odbywa się w BubblePhysicsRuntime/TransactionStager.swift, wykonanie native w BubblePhysicsNativeMetal, a render w BubblePhysicsMetalRender/BubblePhysicsMetalRender.swift. WorldConfiguration dokumentuje, że simulationRegion nie jest ścianą. Testy leżą odpowiednio w BubblePhysicsPublicTests, BubblePhysicsRuntimeTests, BubblePhysicsNativeMetalTests i BubblePhysicsMetalRenderTests; iOS bench w Benchmarks/iOS/BubblePhysicsBench.

**R3 — zachowania.**

| ID | Zachowanie | Kryteria designu |
|---|---|---|
| P-B-001 | wartość i chwyt są elementem silnikowego renderu bańki oraz publikują się atomowo z receipt | G1-AC1, G1-AC2, G1-AC3, G4-AC2 |
| P-B-002 | numerowane zapytanie GPU wybiera deformowany kontur i bezpiecznie zasila player drive | G2-AC1, G2-AC2, G2-AC3, G4-AC1 |
| P-B-003 | semantyczny spawn w ArenaPreset jest deterministyczny i zderza się z fizycznymi granicami | G3-AC1, G3-AC2, G3-AC3, G4-AC3 |

**Strategia testów.** Każdy slice zaczyna od testu publicznego kontraktu oraz testu właściwej warstwy Metal/runtime. Testy renderowania używają caller command buffer; testy normalnej ścieżki asercją brak konturowego readbacku. Dopiero po całości powstaje zapis Release iPhone X; nie jest substytutem testów ani benchmarku biblioteki.

## Slice’y

### Slice 1 — semantyczna prezentacja bańki

**Status:** todo

**Dlaczego mergeowalny:** rozszerza istniejący kontrakt prezentacji bez zmiany zachowania dawnych BubbleDescriptorów; produkt nadal nie potrzebuje hit-testu ani areny, a renderer jest wyłącznym właścicielem wartości/chwytu.

**Niedostępne po slice:** wybór deformowanego konturu oraz semantyczny spawn/arena.

#### Chunk A — kontrakt i staging

1. Dodać testy publiczne dodatniej BubblePresentation, atomowej aktualizacji i zachowania istniejących konstruktorów, obserwując red.  
   verify: swift test --filter SemanticPresentationTests.testRejectsInvalidValueAndPublishesOnlyAcceptedPresentation
2. Dodać semantyczne typy/operacje oraz staging prezentacji tak, aby receipt był granicą publikacji.  
   verify: swift test --filter SemanticPresentationTests.testRejectsInvalidValueAndPublishesOnlyAcceptedPresentation

#### Chunk B — renderer i publikacja

3. Dodać test Metal, że wartość i chwyt są kodowane z tym samym deformowanym zakresem co bańka, w caller command buffer, bez pipeline’u integratora.  
   verify: swift test --filter SemanticPresentationRenderTests.testValueAndGrabAreEncodedWithDeformedBubbleInCallerCommandBuffer
4. Rozszerzyć native handoff i BubblePhysicsMetalRender o silnikową etykietę oraz stan chwytu; zachować poprzednią klatkę po błędzie renderu.  
   verify: swift test --filter SemanticPresentationRenderTests.testValueAndGrabAreEncodedWithDeformedBubbleInCallerCommandBuffer

### Slice 2 — wybór deformowanego konturu

**Status:** unplanned

**Cel:** P-B-002. Implementacja obejmie numerowane żądanie selekcji, wynik GPU opublikowany z następną ukończoną klatką, deterministyczny tie-break i testy begin/update/endPlayerDrive bez readbacku CPU.

### Slice 3 — semantyczny spawn i fizyczna arena

**Status:** unplanned

**Cel:** P-B-003. Implementacja obejmie ArenaPreset, seeded SpawnBubbleRequest, granice runtime i testy deterministyczności/kolizji. Po nim zostanie wykonany pomiar Release iPhone X z 120 klatkami rozgrzewki i 300 mierzonymi.

## Odchylenia

Brak. Design nie zmienia publicznego kontraktu łamiąco; dodaje kompatybilne typy i operacje.

## Rejestr review

| Runda | Wynik | Uwagi / zapis |
|---|---|---|
| 1 | ISSUES — naprawione | [Slice 1 / tasks] „verify: swift test --filter BubblePhysicsPublicTests” — cały target nie dowodził dodatniej wartości, atomowości i kompatybilności; zastąpiono go jednym konkretnym testem kontraktu. [Slice 1 / tasks] „verify: swift test --filter BubblePhysicsMetalRenderTests” — cały target nie dowodził wartości/chwytu, wspólnej geometrii i command buffera; zastąpiono go jednym konkretnym testem renderingu. |
