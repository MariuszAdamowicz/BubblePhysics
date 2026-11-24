# Bugfix: Świat 4.0.0 pada na iPhonie X (A11) w ścieżce jednej dyspozycji

**Date:** 2026-11-24
**Artifact:** bugfix
**Status:** Approved
**Template version:** default/0.5.5

**Plugin version:** 0.7.11
**Agent Sessions:** claude-code: ed790b7a-d3c1-4840-b257-729e8d0c33bd

## Root cause analysis

**Objaw.** Ponowny benchmark na iPhonie X (iOS 16.7.16, Apple A11 GPU), raport `docs/benchmarks/v4.0.0-iphone-x.md` @058f5a8, mierzony kod 9109cde. W każdej z czterech scen (resting-crowd, band-to-wall, head-on-128, shot-into-crowd) raport podaje: `measured=0`, `failed_frames=4`, `execution_path=none`, `single_group_width=0`, `safety=fail`. Raport nie wskazuje przyczyny.

**Gdzie pada.** Pierwsza klatka (indeks 0) każdej serii. Pętla serii `runSeries` dolicza 1 do `failedFrames`, gdy `command.status != .completed` albo ustawiono `lastAdvanceIssue` (`Sources/BubblePhysicsMetalRenderBenchmark/PublicWorldStressBenchmark.swift:580`), i jeszcze 1, gdy brakuje telemetrii (`:598`). Potem przerywa serię (`:639`). Dwie serie × 2 = 4, dlatego `measured=0` i `execution_path=none`: żadna klatka nie dotarła do pomiaru. Świat zapisuje `failureReason` i `failureDetail` (`Sources/BubblePhysicsPublic/Diagnostics.swift:97`, `:99`), ale raport benchmarku ich nie drukuje (`PublicWorldStressBenchmark.swift:115-140`).

**Przyczyna.** Jądro jednej grupy `nativeSubstepLoopSingleGroup` (`Sources/BubblePhysicsNativeMetal/Shaders/NativeForceKernels.metal-source:1175`) dostaje 38 buforów przez strukturę wskaźników `NativeBroadphaseBuffers` (`NativeForceKernels.metal-source:948-989`). Host wypełnia ją surowymi adresami `buffers.map(\.gpuAddress)` i przekazuje przez `setBytes` (`Sources/BubblePhysicsNativeMetal/NativeMetalSubstepLoop.swift:141`, `:151`). Taki argument buffer z ręcznie wpisanymi adresami działa tylko na argument buffers tier 2 (rodzina Apple6, A13+). A11 należy do Apple4 i ma tier 1. Tam argument buffer koduje się przez `MTLArgumentEncoder`, a jego wpisy liczą się do limitu tablicy argumentów funkcji, czyli 31 buforów. Jądro potrzebuje 38 buforów plus bufor parametrów. Na A11 nie zmieści się więc w żadnej postaci argument buffera.

**Dowody:**
- Pomiar kodu 8ef9d87 (wycinek 2, bez jądra jednej grupy) przeszedł na tym samym iPhonie X: `measured=300`, `failed_frames=0`, `safety=pass` (wersja raportu sprzed @058f5a8 w historii Git). Pomiar 9109cde (po wycinku 3) pada.
- W 8ef9d87 nie ma `gpuAddress` (`git grep -n gpuAddress 8ef9d87 -- Sources` nic nie zwraca). Tablicę adresów dodał wycinek 3 (odchylenie 42 w `docs/sdlc/changes/2026-11-23-engine-4-0-0/plan.md:827`).
- Wybór ścieżki nie sprawdza możliwości GPU, tylko liczbę baniek ≤ 1024 (`NativeMetalSubstepLoop.swift:181`; próg w `Sources/BubblePhysicsNativeMetal/NativeForceRecords.swift:79`). Każda scena benchmarku ma ≤ 1024 baniek, więc na A11 zawsze idzie jedna dyspozycja. W `Sources` nie ma ani `argumentBuffersSupport`, ani `supportsFamily`.
- Potoki, także `nativeSubstepLoopSingleGroup`, kompilują się przy tworzeniu świata (`Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift:335`, wołane z `Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift:140`). Świat powstał i doszedł do klatek, więc błąd jest w wykonaniu, a nie w kompilacji.
- Dokumentacja Apple:
  - [MTLArgumentBuffersTier](https://developer.apple.com/documentation/metal/mtlargumentbufferstier.md): na tier 2 wolno wpisać `gpuAddress` wprost, tier 1 wymaga `MTLArgumentEncoder`.
  - [Improving CPU performance by using argument buffers](https://developer.apple.com/tutorials/data/documentation/metal/improving-cpu-performance-by-using-argument-buffers.md): na tier 1 zasoby z argument buffera i zasoby wiązane osobno liczą się razem do limitu na funkcję.
  - [Metal capabilities](https://developer.apple.com/metal/capabilities/): tier 2 od Apple6.
  - [Metal Feature Set Tables](https://DEVELOPER.APPLE.COM/metal/Metal-Feature-Set-Tables.pdf): A11 to Apple4, limit 31 wpisów tablicy buforów na funkcję.

**Not verified:** w sesji nie było podłączonego iPhone'a (`xcrun devicectl list devices` → „No devices found.”), a Mac ma tier 2, więc błędu nie da się odtworzyć lokalnie. Diagnoza opiera się na kodzie, historii pomiarów i dokumentacji Apple.

**Otwarte warunki wstępne** (każdy może podważyć diagnozę):
- Faktyczny `failureReason` na urządzeniu. Oczekiwany to `commandExecutionFailed` (bufor poleceń zakończony błędem). Inny powód, np. `substepLimitExceeded` albo `nonFiniteValues`, oznaczałby inną przyczynę.
- Czy na A11 `pipeline.maxTotalThreadsPerThreadgroup` jądra jednej grupy i pamięć grupy 16 384 B (`NativeForceRecords.swift:81`) plus pamięć statyczna potoku mieszczą się w limitach urządzenia. Apple4 ma 32 KB pamięci grupy, a jądro iteruje po bańkach krokiem `width` (`NativeForceKernels.metal-source:1215`), więc węższa grupa nie powinna przeszkadzać.

**Wykluczone:**
- Budżet czasu i kandydatki projektu (CD-D-28): klatka nie dochodzi do pomiaru.
- Błąd kompilacji potoku: świat powstał.
- Ścieżka wielu dyspozycji: działała na A11 w 8ef9d87, a sceny ≤ 1024 baniek jej nie używają.
- Przekroczenie pamięci grupy: 16 384 B < 32 KB na Apple4.

## Fix design

### Why & what

Jądro jednej grupy ma działać na A11 (argument buffers tier 1) bez struktury wskaźników. Ścieżka jednej dyspozycji zostaje na iPhonie X, bo to ona ma zmieścić klatkę w budżecie. Benchmark ma drukować przyczynę upadku świata.

- [ ] Test odtwarzający: refleksja potoku `nativeSubstepLoopSingleGroup` nie zawiera argumentu ze wskaźnikami, a jądro wiąże ≤ 31 buforów. Dziś pada (jeden argument z 38 wskaźnikami), po poprawce przechodzi. · `verify: swift test --filter NativeMetalShaderABITests/testSingleGroupKernelFitsTier1ArgumentTable`
- [ ] Jądro jednej grupy liczy krok identycznie jak dotąd: testy bliźniaka, pętli jednej dyspozycji i kolizji kubełków przechodzą bez zmiany oczekiwań. · `verify: swift test --filter "ExecutionPathTwinTests|SingleDispatchLoopTests|InGroupGridCollisionTests|ExecutionPathThresholdTests"`
- [ ] Urządzenie, którego pamięć grupy nie mieści jądra jednej grupy, dostaje ścieżkę wielu dyspozycji zamiast upadku świata. · `verify: swift test --filter ExecutionPathThresholdTests` (przypadek z wstrzykniętym brakiem możliwości → `multipleDispatches`)
- [ ] Raport benchmarku ma linię `failure_reason=` z powodem upadku świata albo `none`. · `verify: swift test --filter StressSubstepReportTests`
- [ ] Na iPhonie X świat nie pada: `failed_frames=0`, `execution_path=singleDispatch`, `safety=pass` we wszystkich czterech scenach. · `verify: ręczny benchmark iOS na iPhonie X (zadanie 41 planu 4.0.0)`

### How - Program design

**Mniej wiązań przez scalenie małych buforów.** Jądro dostaje bufory zwykłymi slotami `[[buffer(n)]]`, a parametry jak dotąd przez `setBytes`. Żeby zejść z 38 do ≤ 30 slotów, dwie grupy małych buforów stają się jednym `MTLBuffer` z przesunięciami wyrównanymi do 256 B.

- **Blok sterowania kroku** w `NativeMetalPersistentState`: `contactControl`, `dispatchStatistics`, `candidateOverflow`, `substepControl`, `substepDispatch`, `substepSteps`, `contactAssertion`. Siedem buforów → 1. Dziś są tworzone osobno (`NativeMetalSolver.swift:170`, `:188`, `:190`, `:212-215`).
- **Rekordy sił** w `NativeMetalForceBuffers` (`NativeForceRecords.swift:117-140`): `control`, `fields`, `fieldVertices`, `fieldObjectIDs`, `bands`, `motors`. Sześć → 1, wgrywane jednym `upload`.

Razem 38 − 11 = 27 buforów plus parametry, czyli 28 wiązań. Mieści się w 31.

Dotychczasowe właściwości (`state.substepControl`, `forces.bands` itd.) stają się wycinkami (bufor + przesunięcie). Wszystkie miejsca wiązania (`bind` w `NativeMetalSubstepLoop.swift:9-13` oraz wiązania w `NativeMetalSolver.swift` i `NativeMetalChainKernels.swift`) przekazują przesunięcie do `setBuffer(_:offset:index:)`. Tak samo `contents()` przy odczycie na CPU (`NativeMetalSubstepLoop.swift:213`, `:244`, `NativeMetalSolver.swift:230`) i bufor pośredniej dyspozycji `substepDispatch` (`indirectBufferOffset`). Inne jądra nie zmieniają sygnatur.

**Shader.** W `NativeForceKernels.metal-source` jądro `nativeSubstepLoopSingleGroup` przyjmuje bufory jako argumenty `[[buffer(n)]]`. Na wejściu składa z nich lokalną strukturę `NativeBroadphaseBuffers` w przestrzeni `thread`; wskaźniki z bloku sterowania i z rekordów sił wylicza z bazy i przesunięć podanych w `NativeSingleGroupParameters`. Funkcje urządzenia (`:1008`, `:1038`, `:1145`, `:1153`, `:1161`) przyjmują `thread const NativeBroadphaseBuffers &` zamiast `constant …&`. Ich ciała się nie zmieniają.

**Host.** `encodeSingleDispatch` (`NativeMetalSubstepLoop.swift:126-158`) zamiast tablicy `gpuAddress` i `useResource` wiąże bufory wprost i dopisuje przesunięcia do `NativeMetalSingleGroupParameters` (rozmiar i sonda ABI się zmieniają). Nazwa i wartość `broadphaseBufferCount` (`NativeForceRecords.swift:83`) przechodzą na liczbę slotów jądra.

**Zabezpieczenie wyboru ścieżki.** `NativeMetalSubstepLoop.executionPath` (`NativeMetalSubstepLoop.swift:180-182`) dostaje parametr `supportsSingleDispatch`. Solver liczy go raz przy inicjalizacji (`NativeMetalSolver.swift:335`) jako `device.maxThreadgroupMemoryLength >= singleGroupMemoryLength + pipeline.staticThreadgroupMemoryLength`. Przy `false` idzie `multipleDispatches`. Po poprawce jądro nie używa argument buffers, więc sprawdzanie tieru nie ma czego chronić. Prawdziwym, zależnym od sprzętu warunkiem jądra pozostaje pamięć grupy (BF-D-3).

**Benchmark.** `PublicWorldStressReport` dostaje pole `failureReason` (pierwszy `world.diagnostics.failureReason` serii, zapisany w `runSeries` przy przerwaniu, `PublicWorldStressBenchmark.swift:639`). Wypisuje je w linii `failure_reason=` po `fallback_frames=…; failed_frames=…`, a przy `substepLimitExceeded` i `contactViolation` dokłada `failure_detail=` z `failureDetail`.

### Plan

1. Czerwony test w `Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`: `testSingleGroupKernelFitsTier1ArgumentTable`. Tworzy potok `nativeSubstepLoopSingleGroup` z `MTLPipelineOption.bindingInfo` i sprawdza, że żadne wiązanie bufora nie ma typu struktury z polem `.pointer` oraz że liczba wiązań buforów ≤ 31. · `verify: swift test --filter NativeMetalShaderABITests/testSingleGroupKernelFitsTier1ArgumentTable` → FAIL (struktura z 38 wskaźnikami)
2. Blok sterowania kroku: jeden bufor z wycinkami dla 7 małych buforów w `NativeMetalPersistentState` (`NativeMetalSolver.swift`). Przesunięcia w każdym `setBuffer`, `contents()` i `indirectBufferOffset` w `NativeMetalSolver.swift`, `NativeMetalSubstepLoop.swift`, `NativeMetalChainKernels.swift`. · `verify: swift test --filter "BubblePhysicsNativeMetalTests|SubstepSeamTests|SubstepTelemetryTests"` → 0 fail
3. Rekordy sił: jeden bufor z wycinkami w `NativeMetalForceBuffers` (`NativeForceRecords.swift`) i przesunięcia w miejscach wiązania. · `verify: swift test --filter "BubblePhysicsNativeMetalTests|BubblePhysicsRuntimeTests"` → 0 fail
4. Shader i host jądra jednej grupy: sloty `[[buffer(n)]]`, lokalna `NativeBroadphaseBuffers` w `thread`, przesunięcia w `NativeSingleGroupParameters` (`NativeForceKernels.metal-source`). `encodeSingleDispatch` bez `gpuAddress` i `useResource`. Sonda ABI `testSingleGroupKernelStructsMatchShaderLayouts` dostosowana. · `verify: swift test --filter "NativeMetalShaderABITests|ExecutionPathTwinTests|SingleDispatchLoopTests|InGroupGridCollisionTests"` → 0 fail, test z zadania 1 PASS
5. Czerwony, potem zielony przypadek w `Tests/BubblePhysicsRuntimeTests/ExecutionPathThresholdTests.swift`: `executionPath(bubbleCount: 300, forceMultipleDispatches: false, supportsSingleDispatch: false)` → `multipleDispatches`. Wdrożenie parametru i obliczenia z pamięci grupy w `NativeMetalSubstepLoop.swift` i `NativeMetalSolver.swift`. · `verify: swift test --filter ExecutionPathThresholdTests` → PASS
6. Czerwony, potem zielony test w `Tests/BubblePhysicsMetalRenderTests/StressSubstepReportTests.swift`: raport ma linię `failure_reason=none` dla udanego przebiegu i `failure_reason=commandExecutionFailed` dla raportu z takim powodem. Pole i zapis w `PublicWorldStressBenchmark.swift`. Aktualizacja oczekiwań kluczy w `CapacityMeasurementTests.swift` i `PerfGuardTests.swift`, jeśli porównują pełny tekst. · `verify: swift test --filter "StressSubstepReportTests|CapacityMeasurementTests|PerfGuardTests"` → PASS
7. Pełny zestaw i buildy iOS. · `verify: swift test` → 0 fail (ok. 13 min); `xcodebuild` Showcase i aplikacji benchmarku iOS → BUILD SUCCEEDED
8. Człowiek: ponowny benchmark na iPhonie X (zadanie 41 planu `docs/sdlc/changes/2026-11-23-engine-4-0-0/plan.md`) i raport w `docs/benchmarks/v4.0.0-iphone-x.md`. · `verify: wszystkie 4 sceny failed_frames=0, execution_path=singleDispatch, failure_reason=none, safety=pass`

### Decisions

| ID | Title | Context | Options | Choice | Rationale | Source | Consequences |
|----|-------|---------|---------|--------|-----------|--------|--------------|
| BF-D-1 | Sposób naprawy dla A11 | Jądro jednej grupy nie działa na argument buffers tier 1, a ścieżka wielu dyspozycji nie mieściła iPhone'a X w budżecie (head-on-128 p95 21,5 ms, shot-into-crowd 58,8 ms w raporcie z kodu 8ef9d87) | (a) bramka tier 2 i wiele dyspozycji na A11; (b) jądro jednej grupy zgodne z tier 1 (≤ 31 wiązań) plus zabezpieczenie i druk przyczyny; (c) najpierw instrumentacja na urządzeniu, decyzja po wyniku | (b) | (a) naprawia awarię, ale wraca do ścieżki, która nie mieści się w budżecie, więc wydanie i tak by nie przeszło. (c) opóźnia poprawkę o obieg z urządzeniem, a diagnozę i tak sprawdzi zadanie 8 | user | Zachowuje cel wycinka 3 na A11. Diagnoza nadal niezweryfikowana na urządzeniu, potwierdzi ją zadanie 8 |
| BF-D-2 | Jak zejść do ≤ 31 wiązań | Tier 1 liczy wpisy argument buffera do limitu 31 buforów funkcji, więc żaden argument buffer nie mieści 38 buforów | (a) `MTLArgumentEncoder` z 38 wpisami; (b) dwa argument buffery; (c) scalenie małych buforów w dwa bufory z przesunięciami i zwykłe sloty; (d) kopiowanie małych buforów blitem do wspólnego bufora przed dyspozycją i z powrotem po niej | (c): blok sterowania kroku (7 → 1) i rekordy sił (6 → 1), razem 28 wiązań | (a) i (b) nadal liczą 38 buforów do limitu. (d) to dwa dodatkowe kodery na klatkę, a na A11 każda dyspozycja kosztuje 20–50 µs. (c) nie zmienia sygnatur innych jąder, tylko przesunięcia przy wiązaniu | auto (refleksja kodu: `NativeMetalSolver.swift:170-215`, `NativeForceRecords.swift:117-140`, limit z Metal Feature Set Tables) | Właściwości buforów stają się wycinkami z przesunięciem, a każde miejsce wiązania musi je przekazać. Zostają 3 wolne sloty na przyszłe bufory jądra |
| BF-D-3 | Zabezpieczenie wyboru ścieżki | W grillingu ustalono zabezpieczenie oparte na tierze argument buffers; po zmianie z BF-D-2 jądro nie używa argument buffers | (a) bramka `argumentBuffersSupport == .tier2`; (b) bramka pamięci grupy: `maxThreadgroupMemoryLength ≥ singleGroupMemoryLength + staticThreadgroupMemoryLength`; (c) bez bramki | (b), z parametrem `supportsSingleDispatch` do wstrzyknięcia w testach | (a) wysłałaby A11 na wiele dyspozycji i zniweczyła BF-D-1. Pamięć grupy to jedyny pozostały warunek jądra zależny od sprzętu; szerokość grupy obsługują pętle krokiem `width` (`NativeForceKernels.metal-source:1215`) | auto (BF-D-1 i BF-D-2) | Urządzenie z mniejszą pamięcią grupy dostaje ścieżkę wielu dyspozycji zamiast upadku. Odchodzi od literalnego „sprawdzaj tier” z grillingu |
| BF-D-4 | Przyczyna upadku w raporcie | Raport z 058f5a8 nie mówił, czemu świat padł, co utrudniło diagnozę | (a) linia `failure_reason=` (i `failure_detail=` przy powodach z detalem); (b) tylko log w konsoli; (c) bez zmian | (a) | Raport to jedyny dowód przekazywany z urządzenia; konsola Xcode nie trafia do repo | auto (raport `docs/benchmarks/v4.0.0-iphone-x.md`) | Nowy klucz raportu; testy porównujące pełny tekst do aktualizacji (zadanie 6) |

## Implementation deviations

| #   | Task | Type (change/gap) | Description | Date |
| --- | ---- | ----------------- | ----------- | ---- |
|     |      |                   |             |      |
