# Reference GPU 300 Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zmierzyć i usunąć główne koszty referencyjnego backendu Metal, zachować zachowanie CPU i doprowadzić `stress-300` do sprawdzalnej bramki `10 ms p95` na fizycznym iPhonie.

**Architecture:** Aplikacja pokazuje CPU reference i benchmark CPU/GPU. Neutralny typ profilu klatki przechodzi z solvera Metal przez istniejącą telemetrię do raportu. Harmonogram nie wysyła nieaktywnych slotów; następnie profil wskazuje, które seryjne przebiegi geometrii i skany kontaktów należy zrównoleglić. Każda zmiana zachowuje atomową publikację i ma osobną bramkę zgodności CPU↔GPU.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Metal Shading Language 2.4, Swift Package Manager, Xcode Release na iOS 16+.

**Spec:** `docs/superpowers/specs/2026-10-06-reference-gpu-300-optimization-design.md`

## Global Constraints

- CPU reference pozostaje wyrocznią, wizualizacją i pełnoklatkowym fallbackiem.
- Zachować sceny `interactive-24` / `stress-300`, seed `2842869`, limity Newtona `4/8/12/16`, 30 warmup + 300 measured, niezmienione limity PCG i parametry fizyki.
- Zachować pełne ID, kolejność kontaktów, prefiks CCD, regułę ostatniego zapisu, guardy, wykrywanie `non-finite`, retry po overflow i fatalny latch Metal.
- Nie zmieniać ustawień podpisu Xcode ani plików użytkownika; historyczne biblioteki i ich testy pozostają w pakiecie. Nie dodawać nowych zależności.
- Sukces wymaga Release na fizycznym iPhonie: `stress-300` pełna klatka `p95 <= 10 ms`, bez fallbacków, `non-finite` i wieloklatkowego pełnego zawarcia, z jakością nie gorszą od CPU baseline dla tej samej sceny i limitu.
- Pomiary diagnostyczne i akceptacyjne są osobnymi przebiegami; nie odejmować od siebie percentyli różnych rozkładów.

## Review Focus

1. Klucz kontaktu koliduje poza aktywowanym prefiksem CCD: wynik nadal wybiera ostatniego kandydata CPU; test w Task 4.
2. Overflow po częściowej pracy GPU: ponowienie startuje z niezmienionego wejścia i nie publikuje scratch; test w Task 4.
3. Zbieżność przed limitem Newtona oraz wczesny koniec CCD: harmonogram nie wysyła zbędnych slotów i zachowuje raport CPU; testy w Task 3.
4. Fatalny błąd podczas nowego układu command bufferów: cała klatka wraca na CPU, a sesja nie wysyła więcej Metal; test w Task 3.
5. Brak lub częściowa próbka profilu przy fallbacku/warmup: raport GPU nie przedstawia jej jako ukończonego pomiaru; test w Task 2.

---

### Task 1: Skupić aplikację na referencyjnym CPU i benchmarku GPU

**Files:**
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/BubblePhysicsBenchApp.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/ReferenceVisualPrototypeView.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/ReferenceBenchmarkView.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`
- Preserve outside app target: `Benchmarks/iOS/BubblePhysicsBench/App/RadialBubblePrototypeView.swift`, `Sources/BubblePhysicsMetal`, `Tests/BubblePhysicsMetalTests`

**Interfaces:** `ReferenceVisualPrototypeView()` usuwa nieużywany `Binding<PrototypeMode>`. Ten widok i `ReferenceBenchmarkView` pozostają jedynymi ekranami aplikacji. Benchmark zachowuje wybór backendu, sceny, jednego limitu lub macierzy, Start/Stop, postęp i kopiowalny tekst.

- [ ] **Krok 1: Zapisz stan wejściowy aplikacji.** Uruchom `rg -n 'Radial|Text\("40"\)|Text\("300"\)|BubblePhysicsMetal' Benchmarks/iOS/BubblePhysicsBench/App Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`; oczekiwane są historyczne ekrany i zależności pakietowe.
- [ ] **Krok 2: Uprość powłokę aplikacji.** Ustaw `ReferenceBenchmarkView` jako ekran domyślny i dodaj przejście do `ReferenceVisualPrototypeView()`. Usuń z niej nieużywany binding `selectedMode`, a z celu aplikacji `PrototypeMode` oraz historyczny `MetalPrototypeView`/koordynator. Usuń zależność aplikacji od `BubblePhysicsMetal` i `RadialBubblePrototypeView.swift` z Xcode Sources; zachowaj plik i produkt pakietu w Git.
- [ ] **Krok 3: Zweryfikuj.** Uruchom unsigned `xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`; oczekiwane `BUILD SUCCEEDED`. Powtórz `rg` dla źródeł kompilowanych przez aplikację i zależności; historyczne ekrany/zależności nie mogą występować.
- [ ] **Krok 4: Zacommituj.** `git add Benchmarks/iOS/BubblePhysicsBench/App/BubblePhysicsBenchApp.swift Benchmarks/iOS/BubblePhysicsBench/App/ReferenceVisualPrototypeView.swift Benchmarks/iOS/BubblePhysicsBench/App/ReferenceBenchmarkView.swift Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj && git commit -m "refactor: focus iOS benchmark on reference physics"`.

### Task 2: Dodać wiarygodny profil etapów GPU

**Files:**
- Create: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkGPUProfile.swift`
- Modify: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkMatrix.swift`
- Modify: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkPresentation.swift`
- Modify: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkReport.swift`
- Modify: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkRunner.swift`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalBackend.swift`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalWorldRunner.swift`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalBenchmarkRunner.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/ReferenceBenchmarkView.swift`
- Test: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalBenchmarkTests.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceBenchmarkPresentationTests.swift`

**Interfaces:** Dodaj `ReferenceBenchmarkGPUFrameProfile: Sendable, Equatable` z polami `commandBufferCount: Int`, `encoderCount: Int`, `stageGPUMilliseconds: [String: Double]`, `hostEncodingMilliseconds: Double`, `hostWaitingMilliseconds: Double`, `hostReadbackMilliseconds: Double`. Dodaj `gpuDiagnosticsEnabled: Bool = false` do `ReferenceBenchmarkMatrixConfiguration`; `ReferenceMetalFrameTelemetry.profile` i `ReferenceBenchmarkGPUFrameTelemetry.profile` są opcjonalne. Runner agreguje wyłącznie ukończone, mierzone profile Metal; stałe klucze etapów to `geometry`, `newton`, `pcg`, `lineSearch`, `ccd`, `guards`, `contours`, `render`.

- [ ] **Krok 1: Napisz testy raportu.** Syntetyczny przebieg z dwoma ukończonymi profilami i jednym fallbackiem CPU raportuje dokładnie dwie próbki, p50/p95/max liczników oraz czasów etapów; profil tylko z warmup jest wykluczony; brak profilu daje `unavailable`; `plainText` CPU pozostaje identyczny bajt po bajcie. Dodaj test prezentacji: tryb diagnostyczny ustawia `gpuDiagnosticsEnabled=true`, zwykły — false.
- [ ] **Krok 2: Potwierdź czerwone testy.** `swift test --filter ReferenceMetalBenchmarkTests` i `swift test --filter ReferenceBenchmarkPresentationTests`; oczekuj błędu kompilacji/testu z powodu brakującego interfejsu profilu.
- [ ] **Krok 3: Dodaj dane i agregację.** Dodaj powyższy typ profilu, flagę konfiguracji oraz wiersze tekstowe `gpu_profile` / `gpu_stage` tylko dla GPU. Użyj `ReferenceTimingSummary(values:)` wyłącznie dla mierzonych, ukończonych klatek Metal; częściowej nieudanej próby nie zapisuj jako ukończonego czasu GPU. Zachowaj kolumny tabeli i tekst CPU.
- [ ] **Krok 4: Instrumentuj solver.** Policz command buffery i compute encodery; przypisz czasy ukończonych command bufferów do etapów. Zmierz monotonicznym zegarem kodowanie hosta, czekanie i finalny readback. Przekaż flagę przez `ReferenceBenchmarkPresentation` → `ReferenceMetalBenchmarkRunner` → `ReferenceMetalWorldRunner` → `ReferenceMetalSolver`; dodaj przełącznik diagnostyki w UI i objaśnij wpływ na pomiar. Szczegółowe próbki zachowuj tylko w trybie diagnostycznym. Dotychczasowy `gpu_completed` działa w obu trybach.
- [ ] **Krok 5: Zweryfikuj.** Uruchom oba filtry, potem `swift test`; oczekuj zera błędów. Uruchom unsigned Release iOS build; oczekuj `BUILD SUCCEEDED`.
- [ ] **Krok 6: Zacommituj.** `git add Sources/BubblePhysicsReference Sources/BubblePhysicsReferenceMetal Benchmarks/iOS/BubblePhysicsBench/App/ReferenceBenchmarkView.swift Tests/BubblePhysicsReferenceTests Tests/BubblePhysicsReferenceMetalTests && git commit -m "feat: profile reference GPU frame stages"`.
- [ ] **Krok 7: Bramka profilu na urządzeniu.** Na fizycznym iPhonie uruchom Release diagnostyczny `interactive-24`, limit 4, 30/300; skopiuj pełny raport bez przepisywania do `docs/benchmarks/reference-gpu-profile-iphone-2026-10-06.txt` i dodaj krótką analizę w `docs/benchmarks/reference-gpu-profile-2026-10-06.md`. Po hang albo fallbacku napraw tę ścieżkę przed analizą czasów etapów. Nie wywodź czasu `stress-300` z `interactive-24`.

### Task 3: Ograniczyć pusty harmonogram i synchronizacje

**Files:**
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- Modify only if new control fields are required: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalBufferLayout.swift`, `Sources/BubblePhysicsReferenceMetal/Shaders/ReferencePostSolveKernels.metal-source`
- Test: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalStagedWorldTests.swift`
- Test: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalWatchdogTests.swift`

**Interfaces:** Po zakończeniu etapu odczytuj `ReferenceMetalWorldStage.flow.x` (kolejna faza CCD) i `flow.y` (aktywny Newton). Zachowaj liczniki `ReferenceBenchmarkGPUFrameProfile` z Task 2. Nie zmieniaj limitów Newtona/PCG ani publicznej semantyki świata.

- [ ] **Krok 1: Napisz czerwone testy.** Dla pustego świata wymagaj raportu zgodnego z CPU i mniej niż 20 command bufferów zamiast stałych 242. Dla świata kończącego się przed `maximumEventGroups` wymagaj braku późniejszych etapów `referenceWorld.solve.*`. Po zbieżnym kroku Newtona wymagaj braku dalszych encoderów PCG/line search. Wstrzyknij błąd fatalny po zgrupowanym etapie i wymagaj pełnego fallbacku CPU oraz braku dalszych wysłań Metal.
- [ ] **Krok 2: Potwierdź czerwone testy.** Uruchom `swift test --filter ReferenceMetalStagedWorldTests` i `swift test --filter ReferenceMetalWatchdogTests`; nowe asercje harmonogramu powinny zawieść.
- [ ] **Krok 3: Dodaj minimalne odczyty sterujące.** Po ukończonych granicach CCD/Newtona sprawdź wspólny rekord etapu i nie koduj slotów z nieaktywnym `flow`. Aktywne PCG zostaw w command bufferach o ograniczonym rozmiarze. Grupuj końcowe encodery `finish`, `guards`, `contours` i `render` tylko gdy etykiety błędów etapów pozostają odtwarzalne, a smoke na urządzeniu nie wisi. Nie zastępuj limitów czasowym obcięciem iteracji.
- [ ] **Krok 4: Sprawdź zgodność i bezpieczeństwo.** Uruchom oba filtry oraz `ReferenceMetalWorldRunnerTests`, następnie pełne `swift test` i unsigned Release iOS build. Oczekuj braku błędów i niezmienionych kontraktów fallbacku/overflow.
- [ ] **Krok 5: Zacommituj i porównaj smoke na urządzeniu.** Commit `feat: skip inactive reference GPU stages`. Uruchom diagnostyczny i zwykły `interactive-24`, limit 4, na iPhonie; zachowaj surowe raporty i porównaj pełne p95, ukończone GPU p95, liczniki oraz jakość z Task 2. Kontynuuj tylko bez hang/fallbacku i regresji jakości.

### Task 4: Zrównoleglić budowanie kandydatów i CCD bez zmiany kolejności

**Files:**
- Modify: `Sources/BubblePhysicsReferenceMetal/Shaders/ReferenceGeometryKernels.metal-source`
- Modify: `Sources/BubblePhysicsReferenceMetal/Shaders/ReferencePostSolveKernels.metal-source`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalBufferLayout.swift`
- Test: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalContactPipelineTests.swift`
- Test: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalStagedWorldTests.swift`

**Interfaces:** Wytwarzaj kanoniczne indeksy kandydatów w kolejności par baniek, następnie w kolejności odcinków z podkolejnością baniek. Równoległe kernele zapisują ważność/TOI kandydata do ograniczonego scratch; deterministyczna kompaktacja i porządkowanie grup odtwarzają sekwencję CPU. Ten sam potok zastępuje seryjny skan par w `wScan` po aktywnym interwale. Overflow zgłasza dokładną wymaganą pojemność przed publikacją.

- [ ] **Krok 1: Napisz deterministyczne czerwone testy.** Porównaj ID kandydatów/kontaktów, porządek TOI i grupy zdarzeń z CPU dla 24 i migawki 300 baniek. Uwzględnij remisy czasu, kolizję klucza z ostatnim zapisem poza aktywnym prefiksem CCD i overflow przy pojemności jeden, po którym ten sam input udaje się po retry. Wymagaj etapów produkcyjnych `referenceWorld.pairFlags` i `referenceWorld.stableCompact`, aby test zawiódł na starym seryjnym potoku.
- [ ] **Krok 2: Potwierdź czerwone testy.** Uruchom `swift test --filter ReferenceMetalContactPipelineTests` i `swift test --filter ReferenceMetalStagedWorldTests`; przed implementacją powinno brakować nowych etapów.
- [ ] **Krok 3: Dodaj ograniczoną równoległą enumerację i stabilną redukcję.** Zachowaj kanoniczny indeks pary przed kompaktacją. Testuj niezależne pary równolegle; stabilne prefiksy i deterministyczny porządek mają zbudować zdarzenia. Zastąp analogiczny gorący odcinek `wScan`, włącznie z semantyką istniejących kontaktów i remisów czasowych. Małe skalarne sterowanie zdarzeniami może pozostać, lecz nie seryjna praca po parach.
- [ ] **Krok 4: Zweryfikuj.** Uruchom oba filtry, pełne `swift test`, unsigned Release iOS build i smoke 24 baniek na urządzeniu. Zapisz profil etapów i pierwszy rozbieżny krok CPU↔GPU, jeśli wystąpi; rozbieżność blokuje kolejne zadanie.
- [ ] **Krok 5: Zacommituj.** `git add Sources/BubblePhysicsReferenceMetal Tests/BubblePhysicsReferenceMetalTests && git commit -m "perf: parallelize reference GPU candidates and CCD"`.

### Task 5: Lokalny indeks kontaktów dla Newtona i odświeżania

**Files:**
- Modify: `Sources/BubblePhysicsReferenceMetal/Shaders/ReferenceNewtonPCGKernels.metal-source`
- Modify: `Sources/BubblePhysicsReferenceMetal/Shaders/ReferencePostSolveKernels.metal-source`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalBufferLayout.swift`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- Test: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalDynamicSystemTests.swift`
- Test: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalPCGTests.swift`
- Test: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalWorldRunnerTests.swift`

**Interfaces:** Wytwarzaj deterministyczne offsety/indeksy kontaktów dla każdej bańki i aktywnego wycinka kontaktów. `referenceBuildResidual`, `referenceApplyJacobian` i `referenceBuildInverseDiagonal` konsumują lokalne kontakty w kolejności globalnej listy CPU; `wRefresh` zapisuje nowy wycinek i odbudowuje indeks przed użyciem. Nie pomijaj ani nie deduplikuj kontaktu, jeśli nie robi tego CPU.

- [ ] **Krok 1: Napisz czerwone testy operatorów.** Porównaj resztę, `J·v`, odwrotną diagonalę i wynik PCG z CPU dla rzadkiego grafu 300 baniek, gęstego łańcucha, samych kontaktów bańka–odcinek i zduplikowanych stabilnych kluczy. Wymagaj etapu produkcyjnego `referenceBuildContactAdjacency`, nieobecnego w starym potoku. Dla krótkich testów świata wymagaj dotychczasowych tolerancji reszty 2% / penetracji `0.05`; ID kontaktów mają być dokładne.
- [ ] **Krok 2: Potwierdź czerwone testy.** Uruchom filtry `ReferenceMetalDynamicSystemTests`, `ReferenceMetalPCGTests` i `ReferenceMetalWorldRunnerTests`; test nowego indeksu powinien zawieść przed implementacją.
- [ ] **Krok 3: Zbuduj uporządkowane sąsiedztwo i użyj go.** Konstruuj offsety/indeksy deterministycznie po każdym odświeżeniu kontaktów. W operatorach dla bańki przetwarzaj tylko incydentne kontakty, zachowując kolejność sumowania CPU. Seryjne przejście kontaktów `wRefresh` zastąp pracą per kontakt i stabilną kompaktacją, zachowując reguły cyklu życia, wieku i overflow.
- [ ] **Krok 4: Zweryfikuj.** Uruchom trzy filtry, pełne `swift test`, unsigned Release iOS build i krótkie porównanie trajektorii CPU↔GPU. Na urządzeniu porównaj diagnostyczne czasy etapów z Task 4; wyjaśnij spowolnienie lub regresję jakości przed dalszą pracą.
- [ ] **Krok 5: Zacommituj.** `git add Sources/BubblePhysicsReferenceMetal Tests/BubblePhysicsReferenceMetalTests && git commit -m "perf: index reference GPU contacts per bubble"`.

### Task 6: Urządzeniowa bramka 24/300 i wynik końcowy

**Files:**
- Create: `docs/benchmarks/reference-gpu-optimized-iphone-2026-10-06.txt`
- Create: `docs/benchmarks/reference-gpu-optimized-2026-10-06.md`
- Modify if needed: `README.md`

**Interfaces:** Korzystaj z niezmienionego `ReferenceBenchmarkMatrixReport.plainText`; wiersze profilu GPU pojawiają się tylko w trybie diagnostycznym. Surowy tekst urządzenia pozostaje dosłowny; analiza porównuje go z bazą CPU i poprzednim smoke GPU.

- [ ] **Krok 1: Zweryfikuj lokalne artefakty.** Uruchom `swift test`, `git diff --check` i unsigned Release iOS build; oczekuj zielonego wyniku. Sprawdź, że aplikacja pokazuje tylko wizualizację CPU i benchmark CPU/GPU, nadal obsługując Start/Stop/kopiowanie.
- [ ] **Krok 2: Przeprowadź bramkę na fizycznym urządzeniu.** Uruchom `interactive-24` i `stress-300`, każdą scenę z pełną macierzą `4/8/12/16`, 30 warmup + 300 measured, Release, ten sam iPhone i seed. Skopiuj oba raporty tekstowe bez ręcznego przepisywania. Jeśli smoke 24 baniek nadal wisi albo rażąco przekracza budżet, zatrzymaj się przed kosztowną macierzą `stress-300` i wyraźnie zapisz to ograniczenie.
- [ ] **Krok 3: Przeanalizuj bez automatycznej akceptacji.** Porównaj p50/p95/max pełnej klatki, czasy etapów ukończonego GPU, penetrację p95/max, reszty p95/max, niezbieżne komponenty, zawarcia, non-finite i liczbę fallbacków przy każdym limicie. Uznaj bramkę `10 ms p95` / jakości tylko, jeśli wszystkie warunki wspierają dane z fizycznego urządzenia; inaczej wskaż zmierzone pozostałe wąskie gardło i pierwszą rozbieżność dla kolejnej iteracji.
- [ ] **Krok 4: Zacommituj rzeczywisty raport.** Zacommituj surowe dane i analizę oddzielnie od kodu: `git add docs/benchmarks/reference-gpu-optimized-iphone-2026-10-06.txt docs/benchmarks/reference-gpu-optimized-2026-10-06.md README.md && git commit -m "docs: report optimized reference GPU device result"` (pomiń `README.md`, jeśli bez zmian).

## Execution Notes

- Pierwszy profil urządzeniowy z Task 2 jest bramką pomiarową. Jeśli dane etapów przeczą założonym gorącym ścieżkom, popraw Tasks 4–5 przed ich implementacją; nie optymalizuj niezmierzonej fazy siłą rozpędu.
- Każde zadanie ma osobną bramkę przeglądu. Nieudana zgodność CPU↔GPU, hang lub fallback wymaga naprawy przed kontynuacją. Wcześniejsze surowe raporty pozostają niezmiennymi punktami odniesienia.
- Do kopiowania raportów może być potrzebny fizyczny iPhone lub działanie CEO. Brak danych z urządzenia należy zgłosić; czas macOS ich nie zastępuje.
- Nie dodawaj do commita `Benchmarks/iOS/BubblePhysicsBench/.DS_Store` ani należących do użytkownika ustawień podpisu Xcode. Nie scalaj do `main` bez decyzji CEO.
