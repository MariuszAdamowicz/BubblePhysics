# Plan: BubblePhysics — engine-owned integracja ograniczonego 2KBubbles

**Data:** 2026-10-25

**Status:** Approved

**Artefakt:** `plan`

**Design:** design.md (Approved)

**PRD:** brak — tryb feature

**Manifest assetów:** nie dotyczy

**Strategia:** slices

**Komenda testowa:** `swift test`

**Profil modeli:** `designer` do planu, `scout` do rekonesansu, `reviewer` do niezależnej recenzji

**Wersja pluginu:** 0.1.29

**Sesje agenta:** unknown: UNKNOWN

---

## Program design

**R0 — cel.** BubblePhysics dostarcza trzy niezależne, publiczne granice: semantyczną prezentację bańki, wybór deformowanego konturu oraz semantyczny spawn z fizyczną areną. Gra nie otrzymuje geometrii, renderera ani wyboru backendu.

**R1 — przepływ.** Gra składa WorldTransaction z semantycznymi żądaniami. BubbleWorld stageruje batch, native Metal wylicza fizykę/deformację, renderer koduje tę samą opublikowaną geometrię w tym samym command bufferze, a WorldFrame publikuje receipts, zdarzenia i DriveFeedback. Żądanie hit-testu ma numer, wykonuje się w najbliższym ukończonym kroku i wraca po publikacji tej klatki.

**R2 — potwierdzone seam’y.** Publiczna granica znajduje się w Sources/BubblePhysicsPublic/BubbleWorld.swift i Model/WorldTransaction.swift; BubbleDescriptor w Model/Objects.swift dziś wymaga position. Staging odbywa się w BubblePhysicsRuntime/TransactionStager.swift, wykonanie native w BubblePhysicsNativeMetal, a render w BubblePhysicsMetalRender/BubblePhysicsMetalRender.swift. Sources/BubblePhysicsPublic/Model/WorldConfiguration.swift dokumentuje i waliduje simulationRegion. Testy leżą odpowiednio w BubblePhysicsPublicTests, BubblePhysicsRuntimeTests, BubblePhysicsNativeMetalTests i BubblePhysicsMetalRenderTests; iOS bench w Benchmarks/iOS/BubblePhysicsBench.

**R3 — zachowania.**

| ID | Zachowanie | Kryteria designu |
|---|---|---|
| P-B-001 | wartość i chwyt są elementem silnikowego renderu bańki oraz publikują się atomowo z receipt | G1-AC1, G1-AC2, G1-AC3, G4-AC2 |
| P-B-002 | numerowane zapytanie GPU wybiera deformowany kontur i bezpiecznie zasila player drive | G2-AC1, G2-AC2, G2-AC3, G4-AC1 |
| P-B-003 | semantyczny spawn w ArenaPreset jest deterministyczny i zderza się z fizycznymi granicami | G3-AC1, G3-AC2, G3-AC3, G4-AC3 |

**Strategia testów.** Każdy slice zaczyna od testu publicznego kontraktu oraz testu właściwej warstwy Metal/runtime. Testy renderowania używają caller command buffer; testy normalnej ścieżki asercją brak konturowego readbacku. Dopiero po całości powstaje zapis Release iPhone X; nie jest substytutem testów ani benchmarku biblioteki.

## Slice status

| Slice | Nazwa | Dostarcza | Seams | Zachowania | Status |
|---|---|---|---|---|---|
| 1 | semantyczna prezentacja bańki | wartość i chwyt w silnikowym renderze, publikowane z receipt | public API, staging, native handoff, renderer | P-B-001 | done |
| 2 | wybór deformowanego konturu | wybór dla dragu z opublikowanej geometrii | BubbleWorld, GPU hit-test, player drive | P-B-002 | done |
| 3 | semantyczny spawn i fizyczna arena | deterministyczny spawn z granicami | WorldTransaction, runtime arena, native fizyka | P-B-003 | unplanned |

**Samodzielność slice’ów:** Każdy slice dostarcza samodzielne zachowanie wraz z testami, bez wymogu wdrożenia następnego; po Slice 1 niedostępne pozostają wybór i arena, po Slice 2 — arena, a Slice 3 kończy uzgodniony zakres.

### Slice 1 — semantyczna prezentacja bańki

**Status:** done

**Dlaczego mergeowalny:** rozszerza istniejący kontrakt prezentacji bez zmiany zachowania dawnych BubbleDescriptorów; produkt nadal nie potrzebuje hit-testu ani areny, a renderer jest wyłącznym właścicielem wartości/chwytu.

**Niedostępne po slice:** wybór deformowanego konturu oraz semantyczny spawn/arena.

#### Chunk A — kontrakt i staging

1. Dodać testy publiczne dodatniej BubblePresentation, atomowej aktualizacji i zachowania istniejących konstruktorów, obserwując red.  
   verify: swift test --filter SemanticPresentationTests.testRejectsInvalidValueAndPublishesOnlyAcceptedPresentation
2. Dodać semantyczne typy/operacje oraz staging prezentacji, w tym prezentację rezultatu `mergeBubbles`, tak aby receipt był granicą publikacji.
   verify: swift test --filter SemanticPresentationTests.testRejectsInvalidValueAndPublishesOnlyAcceptedPresentation

#### Chunk B — renderer i publikacja

3. Dodać test Metal, że wartość i chwyt są kodowane z tym samym deformowanym zakresem co bańka, w caller command buffer, bez pipeline’u integratora.  
   verify: swift test --filter SemanticPresentationRenderTests.testValueAndGrabAreEncodedWithDeformedBubbleInCallerCommandBuffer
4. Rozszerzyć native handoff i BubblePhysicsMetalRender o silnikową etykietę oraz stan chwytu; zachować poprzednią klatkę po błędzie renderu.  
   verify: swift test --filter SemanticPresentationRenderTests.testValueAndGrabAreEncodedWithDeformedBubbleInCallerCommandBuffer

### Slice 2 — wybór deformowanego konturu

**Status:** done

**Cel:** P-B-002. Numerowane żądanie wyboru wykonuje point-in-deformed-contour dla konkretnego punktu w najbliższym ukończonym kroku i zwraca jego wynik dopiero po publikacji tej klatki. Gra otrzymuje tylko `ObjectID?`; wynik zasila istniejące begin/update/endPlayerDrive.

#### Chunk A — kontrakt i publikacja

1. Dodać test publicznego żądania wyboru, który przed implementacją nie kompiluje, a potem dowodzi powiązania konkretnego punktu z następną opublikowaną klatką oraz `nil` dla pustego miejsca/usuniętej bańki. Dodać test, że błąd renderu zachowuje poprzednią opublikowaną klatkę i wynik selekcji.  
   verify: swift test --filter DeformedContourSelectionTests.testSelectionSurvivesFailedRenderUntilTheNextPublishedFrame
2. Dodać numerowane żądanie i wynik publikowany przez BubbleWorld bez wystawiania pozycji, promienia, konturu ani wyboru backendu.  
   verify: swift test --filter DeformedContourSelectionTests.testSelectionSurvivesFailedRenderUntilTheNextPublishedFrame

#### Chunk B — native Metal i drag

3. Dodać test native/render handoff dla punktu wewnątrz, granicy, zagłębienia deformacji i nakładania z deterministycznym tie-breakiem oraz test, że wynik selekcji zasila begin/update/endPlayerDrive, `nil` nie rozpoczyna drive, a DriveFeedback pozostaje ciągły. Obserwować red.  
   verify: swift test --filter DeformedContourSelectionTests.testDeformedContourSelectionUsesPublishedGPUGeometryWithoutCPUReadback
4. Zaimplementować GPU point-in-deformed-contour, publikację jego wyniku i integrację z istniejącymi begin/update/endPlayerDrive; asercją zachować `DriveFeedback` oraz zero `contourCPUReadbacks`.  
   verify: swift test --filter DeformedContourSelectionTests.testSelectionFeedsPlayerDriveWithoutContourReadback

### Slice 3 — semantyczny spawn i fizyczna arena

**Status:** unplanned

**Cel:** P-B-003. Implementacja obejmie ArenaPreset, seeded SpawnBubbleRequest, granice runtime i testy deterministyczności/kolizji. Po nim zostanie wykonany pomiar Release iPhone X z 120 klatkami rozgrzewki i 300 mierzonymi.

## Odchylenia od designu

Brak. Design nie zmienia publicznego kontraktu łamiąco; dodaje kompatybilne typy i operacje.

## Replan log

| Data | Slice | Różnica względem pierwotnego planu | Uzasadnienie |
|---|---|---|---|
| 2026-10-26 | 2 | Doprecyzowano punkt publikacji: żądanie ma numer i wynik dla tego samego punktu wraca po najbliższej ukończonej klatce. | Zamknięte uwagi review designu; istniejące seam’y BubbleWorld/native handoff potwierdzają realizację bez CPU readbacku. |

## Odchylenia implementacji

| ID | Stan | Opis | Wpływ | Decyzja CEO |
|---|---|---|---|---|
| IMP-D-001 | approved | Po end review poprawka testów renderingu nie ma osobnego utrwalonego logu RED: pierwszą próbę zablokowały równoległe instancje SwiftPM, a po zwolnieniu blokady testy były już zmienione. | Ukierunkowane testy oraz pełny suite są zielone; historyczny brak osobnego logu RED pozostaje ujawniony. | CEO przekazał decyzję AI 2026-10-26; zaakceptowano po kontrolowanym green suite. |

## Dowody Slice 1

- `swift test --filter BubblePhysicsPublicTests` — 32 testy, 0 failures; obejmuje `SemanticPresentationTests` i publikację merge/rejection.
- `swift test --filter BubblePhysicsMetalRenderTests` — 15 testów, 0 failures; obejmuje różnicowanie wartości, chwyt i caller command buffer.
- `swift test` — zakończony sukcesem 2026-10-26. Najcięższe testy bazowe: `BenchmarkScenarioTests` 148,022 s i `MetalRadialEnduranceTests` 130,490 s; brak failures.

## Dowody Slice 2

- `swift test --filter DeformedContourSelectionTests` — 5 testów, 0 failures; pokrywa wybór po opublikowanej klatce, granicę i zagłębienie zdeformowanego konturu, deterministyczny tie-break, brak CPU readbacku, odporność na błąd renderu oraz przepływ begin/update/endPlayerDrive.
- `swift test --filter BubblePhysicsPublicTests` — 37 testów, 0 failures.
- `swift test --filter BubblePhysicsMetalRenderTests` — 15 testów, 0 failures.
- `swift test` — zakończony sukcesem 2026-10-26; `BenchmarkScenarioTests` 148,136 s i `MetalRadialEnduranceTests` 128,631 s, bez failures. Te benchmarki są regresyjną kontrolą biblioteki, nie budżetem gry.

## Rejestr review

| Runda | Wynik | Uwagi / zapis |
|---|---|---|
| 1 | ISSUES — naprawione | [Slice 1 / tasks] „verify: swift test --filter BubblePhysicsPublicTests” — cały target nie dowodził dodatniej wartości, atomowości i kompatybilności; zastąpiono go jednym konkretnym testem kontraktu. [Slice 1 / tasks] „verify: swift test --filter BubblePhysicsMetalRenderTests” — cały target nie dowodził wartości/chwytu, wspólnej geometrii i command buffera; zastąpiono go jednym konkretnym testem renderingu. |
| 2 | ISSUES — naprawione | `ISSUES`<br>- [R2 / grounding] "WorldConfiguration dokumentuje, że simulationRegion nie jest ścianą." Wskazana w wejściowym zakresie ścieżka `Sources/BubblePhysicsPublic/WorldConfiguration.swift` nie istnieje, więc plan odwołuje się do nierozwiązalnego seam’u.<br>- [Slice 1 / coverage] "Dodać semantyczne typy/operacje oraz staging prezentacji tak, aby receipt był granicą publikacji." Zadanie nie obejmuje wymaganego przez design przekazania prezentacji w `mergeBubbles`; implementer może dostarczyć wyłącznie osobną aktualizację prezentacji i pominąć widoczność wartości rezultatu merge w klatce z jego receipt.<br>- [Plan shape / template] "**Upstream:** design.md (Approved)" Plan pomija wymagane przez szablon pola `PRD`, `Manifest assetów`, `Komenda testowa` i `Profil modeli` oraz wymagane sekcje statusów slice’ów, odchyleń od designu, replan logu i odchyleń implementacji, więc nie zachowuje wymaganego kształtu artefaktu. |
| 3 | CAP_REACHED — round-1 findings fixed, not re-reviewed | End review Slice 1: trzy blockery (liczba zamiast koloru modulo, publikacja merge/rejection, rozróżnialny test wartości/chwytu) naprawione przez commit `87314ecc4dafe00066f0534609c44beb8b4804e5`; usunięto rozszerzenie splitBubble poza zakresem. |
| 4 | ISSUES — naprawione, bez drugiej rundy zgodnie z plan review | Slice 2 nie pokrywał zachowania wyniku selekcji przy błędzie renderu ani kompletnego sprzężenia z begin/update/endPlayerDrive; dodano jawne testy i weryfikacje dla obu kontraktów. |
| 5 | APPROVED | Niezależny end review Slice 2 po commitach implementacji i testów: kontrakt wyboru, publikacja po ukończonej klatce, pojedynczy command buffer, granica GPU/publicznego API oraz przepływ dragu zgodne z designem i planem. |
