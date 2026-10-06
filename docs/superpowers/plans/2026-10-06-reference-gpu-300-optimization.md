# Reference GPU 300 Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rozwijać bibliotekę CPU/Metal dla iOS 16+ i macOS 13+ na Apple Silicon, optymalizować na Macu mini oraz doprowadzić `stress-300` do sprawdzalnej bramki `10 ms p95` na fizycznym iPhonie X bez utraty jakości CPU.

**Architecture:** Mac mini M2 Pro uruchamia ten sam produkcyjny runner Metal i wspólny benchmark przez CLI; iPhone używa aplikacji iOS. Neutralny typ profilu klatki przechodzi z solvera Metal przez telemetrię do identycznego raportu. Harmonogram nie wysyła nieaktywnych slotów; następnie profil wskazuje seryjne przebiegi do zrównoleglenia. Każda zmiana zachowuje atomową publikację i zgodność CPU↔GPU; wynik Maca nie zastępuje bramki iPhone’a X.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, Metal Shading Language 2.4, Swift Package Manager, macOS 13+ na Apple Silicon, Xcode Release na iOS 16+.

**Spec:** `docs/superpowers/specs/2026-10-06-reference-gpu-300-optimization-design.md`

## Global Constraints

- CPU reference pozostaje wyrocznią, wizualizacją i pełnoklatkowym fallbackiem.
- `Package.swift` zachowuje minimum iOS 16 i macOS 13. Produkcyjny Metal działa na obu platformach, gdy urządzenie i shadery są dostępne; brak Metal to jawny fallback, nie próbka GPU.
- Zachować sceny `interactive-24` / `stress-300`, seed `2842869`, limity Newtona `4/8/12/16`, 30 warmup + 300 measured, niezmienione limity PCG i parametry fizyki.
- Zachować pełne ID, kolejność kontaktów, prefiks CCD, regułę ostatniego zapisu, guardy, wykrywanie `non-finite`, retry po overflow i fatalny latch Metal.
- Nie zmieniać ustawień podpisu Xcode ani plików użytkownika; historyczne biblioteki i ich testy pozostają w pakiecie. Nie dodawać nowych zależności.
- Bramka wydajności wymaga Release na fizycznym iPhonie X: `stress-300` pełna klatka `p95 <= 10 ms`, bez fallbacków, `non-finite` i wieloklatkowego pełnego zawarcia, z jakością nie gorszą od CPU baseline dla tej samej sceny i limitu. Nie obiecywać tego czasu na każdym obsługiwanym urządzeniu.
- Mac mini jest szybką pętlą pomiarową; jego percentyle nie zastępują pomiaru iPhone’a. Po zmianach ryzykownych dla sterownika lub semantyki wykonać krótki smoke na iPhonie, a pełną macierz dopiero na końcu.
- Pomiary diagnostyczne i akceptacyjne są osobnymi przebiegami; nie odejmować od siebie percentyli różnych rozkładów.

## Review Focus

1. macOS ma Metal, ale inicjalizacja pipeline’u zawodzi: runner raportuje fallback i CLI nie przedstawia przebiegu jako GPU; test w Task 1.
2. Klucz kontaktu koliduje poza aktywowanym prefiksem CCD: wynik nadal wybiera ostatniego kandydata CPU; test w Task 5.
3. Overflow po częściowej pracy GPU: ponowienie startuje z niezmienionego wejścia i nie publikuje scratch; test w Task 5.
4. Zbieżność przed limitem Newtona lub fatalny błąd: harmonogram pomija tylko nieaktywne sloty, a błąd skutkuje pełnym fallbackiem i blokadą sesji; testy w Task 4.
5. Brak lub częściowa próbka profilu przy fallbacku/warmup: raport GPU nie przedstawia jej jako ukończonego pomiaru; test w Task 3.

---

### Task 1: Uruchomić produkcyjny backend Metal i wspólny benchmark na macOS

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalWorldRunner.swift`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalBenchmarkRunner.swift`
- Create: `Benchmarks/macOS/BubblePhysicsReferenceBench/main.swift`
- Test: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalWorldRunnerTests.swift`
- Test: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalBenchmarkTests.swift`

**Interfaces:** Publiczny `ReferenceMetalWorldRunner.init(backend: ReferenceSimulationBackend = .cpu)` tworzy `ReferenceMetalSolver()` na iOS i macOS, a na niedostępnym urządzeniu zachowuje dotychczasowy fallback; wewnętrzny wariant z fabryką executora pozwala przetestować brak pipeline’u. Nowy produkt SwiftPM `BubblePhysicsReferenceBench` uruchamia `ReferenceMetalBenchmarkRunner.measure(configuration:)` i wypisuje `ReferenceBenchmarkMatrixReport.plainText(deviceName:systemVersion:)`; argumenty CLI: `--scene interactive-24|stress-300`, `--backend cpu|metal`, `--limits 4,8,12,16`, `--warmup 30`, `--measured 300`. `deviceName` zawiera identyfikator Maca i nazwę `MTLDevice`; brak GPU nie może wyglądać jak pomiar GPU. Nie tworzyć drugiego algorytmu sceny ani solvera.

- [ ] **Krok 1: Napisz czerwone testy wyboru runtime.** Na macOS z `MTLCreateSystemDefaultDevice() != nil` publiczny runner z `.metal` po jednej klatce `interactive-24` raportuje `backend == .metal` i brak fallbacku; fabryka executora zwracająca `nil` raportuje CPU i przyczynę, nigdy `gpu_measurement=eligible`. Test benchmarku wymaga co najmniej jednej ukończonej mierzonej klatki Metal. Zastąp obecny test wymagający bezwarunkowego CPU na hoście.
- [ ] **Krok 2: Potwierdź czerwone testy.** `swift test --filter ReferenceMetalWorldRunnerTests` i `swift test --filter ReferenceMetalBenchmarkTests`; na Macu mini obecny `unsupportedRuntime` ma zawieść nowe wymaganie.
- [ ] **Krok 3: Włącz wspólny runtime.** Usuń platformowy zakaz macOS w obu runnerach, zachowując jeden `ReferenceMetalSolver`, fallback, fatalny latch i atomową publikację. Dodaj executable target w `Package.swift` z `main.swift` i powyższymi argumentami; nie zmieniaj minimalnych wersji platform.
- [ ] **Krok 4: Sprawdź macOS Release.** Uruchom oba filtry i `swift test`, następnie `swift run -c release BubblePhysicsReferenceBench --scene interactive-24 --backend metal --limits 4 --warmup 0 --measured 1`; oczekuj `metal_frames=1`, `fallbacks=0`, `gpu_measurement=eligible` oraz `device` identyfikującego Mac/GPU. Uruchom CLI z błędną sceną i oczekuj niezerowego kodu wyjścia oraz krótkiej instrukcji użycia.
- [ ] **Krok 5: Sprawdź iOS bez zmiany zachowania.** Uruchom unsigned Release iOS build oraz dotychczasowe testy watchdog; oczekuj sukcesu.
- [ ] **Krok 6: Zacommituj.** `git add Package.swift Sources/BubblePhysicsReferenceMetal Benchmarks/macOS/BubblePhysicsReferenceBench/main.swift Tests/BubblePhysicsReferenceMetalTests && git commit -m "feat: run reference Metal benchmark on Apple Silicon Mac"`.

### Task 2: Skupić aplikację na referencyjnym CPU i benchmarku GPU

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

### Task 3: Dodać wiarygodny profil etapów GPU

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
- Modify: `Benchmarks/macOS/BubblePhysicsReferenceBench/main.swift`
- Test: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalBenchmarkTests.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceBenchmarkPresentationTests.swift`

**Interfaces:** Dodaj `ReferenceBenchmarkGPUFrameProfile: Sendable, Equatable` z polami `commandBufferCount: Int`, `encoderCount: Int`, `stageGPUMilliseconds: [String: Double]`, `hostEncodingMilliseconds: Double`, `hostWaitingMilliseconds: Double`, `hostReadbackMilliseconds: Double`. Dodaj `gpuDiagnosticsEnabled: Bool = false` do `ReferenceBenchmarkMatrixConfiguration`; `ReferenceMetalFrameTelemetry.profile` i `ReferenceBenchmarkGPUFrameTelemetry.profile` są opcjonalne. Runner agreguje wyłącznie ukończone, mierzone profile Metal; stałe klucze etapów to `geometry`, `newton`, `pcg`, `lineSearch`, `ccd`, `guards`, `contours`, `render`.

- [ ] **Krok 1: Napisz testy raportu.** Syntetyczny przebieg z dwoma ukończonymi profilami i jednym fallbackiem CPU raportuje dokładnie dwie próbki, p50/p95/max liczników oraz czasów etapów; profil tylko z warmup jest wykluczony; brak profilu daje `unavailable`; `plainText` CPU pozostaje identyczny bajt po bajcie. Dodaj test prezentacji: tryb diagnostyczny ustawia `gpuDiagnosticsEnabled=true`, zwykły — false; CLI przyjmuje `--diagnostics` i emituje wiersze profilu tylko w tym trybie.
- [ ] **Krok 2: Potwierdź czerwone testy.** `swift test --filter ReferenceMetalBenchmarkTests` i `swift test --filter ReferenceBenchmarkPresentationTests`; oczekuj błędu kompilacji/testu z powodu brakującego interfejsu profilu.
- [ ] **Krok 3: Dodaj dane i agregację.** Dodaj powyższy typ profilu, flagę konfiguracji oraz wiersze tekstowe `gpu_profile` / `gpu_stage` tylko dla GPU. Użyj `ReferenceTimingSummary(values:)` wyłącznie dla mierzonych, ukończonych klatek Metal; częściowej nieudanej próby nie zapisuj jako ukończonego czasu GPU. Zachowaj kolumny tabeli i tekst CPU.
- [ ] **Krok 4: Instrumentuj solver i oba interfejsy benchmarku.** Policz command buffery i compute encodery; przypisz czasy ukończonych command bufferów do etapów. Zmierz monotonicznym zegarem kodowanie hosta, czekanie i finalny readback. Przekaż flagę przez `ReferenceBenchmarkPresentation`/CLI → `ReferenceMetalBenchmarkRunner` → `ReferenceMetalWorldRunner` → `ReferenceMetalSolver`; dodaj przełącznik w UI i argument `--diagnostics` w CLI, objaśniając wpływ na pomiar. Szczegółowe próbki zachowuj tylko w trybie diagnostycznym. Dotychczasowy `gpu_completed` działa w obu trybach.
- [ ] **Krok 5: Zweryfikuj.** Uruchom oba filtry, potem `swift test`; oczekuj zera błędów. Uruchom unsigned Release iOS build; oczekuj `BUILD SUCCEEDED`.
- [ ] **Krok 6: Zacommituj.** `git add Sources/BubblePhysicsReference Sources/BubblePhysicsReferenceMetal Benchmarks/iOS/BubblePhysicsBench/App/ReferenceBenchmarkView.swift Benchmarks/macOS/BubblePhysicsReferenceBench/main.swift Tests/BubblePhysicsReferenceTests Tests/BubblePhysicsReferenceMetalTests && git commit -m "feat: profile reference GPU frame stages"`.
- [ ] **Krok 7: Zapisz pierwszy profil Maca mini.** Uruchom `swift run -c release BubblePhysicsReferenceBench --scene interactive-24 --backend metal --limits 4 --warmup 30 --measured 300 --diagnostics`; zachowaj dosłowny raport w `docs/benchmarks/reference-gpu-profile-mac-mini-2026-10-06.txt` i analizę etapów w `docs/benchmarks/reference-gpu-profile-2026-10-06.md`. Jeżeli są fallbacki albo hang, napraw tę ścieżkę przed optymalizacją. Wynik Maca nie jest prognozą iPhone’a.
- [ ] **Krok 8: Zacommituj surowy profil osobno od kodu.** `git add docs/benchmarks/reference-gpu-profile-mac-mini-2026-10-06.txt docs/benchmarks/reference-gpu-profile-2026-10-06.md && git commit -m "docs: record baseline reference GPU Mac profile"`.

### Task 4: Ograniczyć pusty harmonogram i synchronizacje

**Files:**
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- Modify only if new control fields are required: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalBufferLayout.swift`, `Sources/BubblePhysicsReferenceMetal/Shaders/ReferencePostSolveKernels.metal-source`
- Test: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalStagedWorldTests.swift`
- Test: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalWatchdogTests.swift`

**Interfaces:** Po zakończeniu etapu odczytuj `ReferenceMetalWorldStage.flow.x` (kolejna faza CCD) i `flow.y` (aktywny Newton). Zachowaj liczniki `ReferenceBenchmarkGPUFrameProfile` z Task 3. Nie zmieniaj limitów Newtona/PCG ani publicznej semantyki świata.

- [ ] **Krok 1: Napisz czerwone testy.** Dla pustego świata wymagaj raportu zgodnego z CPU i mniej niż 20 command bufferów zamiast stałych 242. Dla świata kończącego się przed `maximumEventGroups` wymagaj braku późniejszych etapów `referenceWorld.solve.*`. Po zbieżnym kroku Newtona wymagaj braku dalszych encoderów PCG/line search. Wstrzyknij błąd fatalny po zgrupowanym etapie i wymagaj pełnego fallbacku CPU oraz braku dalszych wysłań Metal.
- [ ] **Krok 2: Potwierdź czerwone testy.** Uruchom `swift test --filter ReferenceMetalStagedWorldTests` i `swift test --filter ReferenceMetalWatchdogTests`; nowe asercje harmonogramu powinny zawieść.
- [ ] **Krok 3: Dodaj minimalne odczyty sterujące.** Po ukończonych granicach CCD/Newtona sprawdź wspólny rekord etapu i nie koduj slotów z nieaktywnym `flow`. Aktywne PCG zostaw w command bufferach o ograniczonym rozmiarze. Grupuj końcowe encodery `finish`, `guards`, `contours` i `render` tylko gdy etykiety błędów etapów pozostają odtwarzalne, a smoke na urządzeniu nie wisi. Nie zastępuj limitów czasowym obcięciem iteracji.
- [ ] **Krok 4: Sprawdź zgodność i bezpieczeństwo.** Uruchom oba filtry oraz `ReferenceMetalWorldRunnerTests`, następnie pełne `swift test` i unsigned Release iOS build. Oczekuj braku błędów i niezmienionych kontraktów fallbacku/overflow.
- [ ] **Krok 5: Zacommituj i porównaj na Macu.** Commit `feat: skip inactive reference GPU stages`. Uruchom diagnostyczny i zwykły `interactive-24`, limit 4, na Macu mini; zachowaj surowe raporty i porównaj pełne p95, ukończone GPU p95, liczniki oraz jakość z Task 3. Ponieważ zmienia się układ wysłań, wykonaj też krótki smoke Release na iPhonie X (`interactive-24`, limit 4, kilka klatek); hang/fallback lub regresja jakości blokuje dalszą pracę.

### Task 5: Zrównoleglić budowanie kandydatów i CCD bez zmiany kolejności

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
- [ ] **Krok 4: Zweryfikuj.** Uruchom oba filtry, pełne `swift test`, unsigned Release iOS build i porównanie Mac Release `interactive-24` oraz krótkie `stress-300` (limit 4). Zapisz profil etapów i pierwszy rozbieżny krok CPU↔GPU, jeśli wystąpi; rozbieżność blokuje kolejne zadanie. Zmiana potoku CCD wymaga krótkiego smoke na iPhonie X przed dalszą pracą.
- [ ] **Krok 5: Zacommituj.** `git add Sources/BubblePhysicsReferenceMetal Tests/BubblePhysicsReferenceMetalTests && git commit -m "perf: parallelize reference GPU candidates and CCD"`.

### Task 6: Lokalny indeks kontaktów dla Newtona i odświeżania

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
- [ ] **Krok 4: Zweryfikuj.** Uruchom trzy filtry, pełne `swift test`, unsigned Release iOS build i krótkie porównanie trajektorii CPU↔GPU. Na Macu mini porównaj diagnostyczne czasy etapów z Task 5; wyjaśnij spowolnienie lub regresję jakości przed dalszą pracą. Po zmianie operatorów wykonaj krótki smoke na iPhonie X, bez pełnej macierzy.
- [ ] **Krok 5: Zacommituj.** `git add Sources/BubblePhysicsReferenceMetal Tests/BubblePhysicsReferenceMetalTests && git commit -m "perf: index reference GPU contacts per bubble"`.

### Task 7: Urządzeniowa bramka 24/300 i wynik końcowy

**Files:**
- Create: `docs/benchmarks/reference-gpu-optimized-iphone-2026-10-06.txt`
- Create: `docs/benchmarks/reference-gpu-optimized-2026-10-06.md`
- Modify: `README.md`

**Interfaces:** Korzystaj z `ReferenceBenchmarkMatrixReport.plainText` wspólnego dla macOS/iOS; wiersze profilu GPU pojawiają się tylko w trybie diagnostycznym. Surowy tekst urządzenia pozostaje dosłowny; analiza porównuje go z bazą CPU, poprzednim smoke GPU i kierunkiem zmiany na Macu bez utożsamiania czasów platform.

- [ ] **Krok 1: Zweryfikuj kompatybilność i lokalne artefakty.** Uruchom `swift test`, `git diff --check`, CLI Mac Release dla obu scen oraz unsigned Release iOS build; oczekuj zielonego wyniku. Sprawdź `Package.swift` dla iOS 16/macOS 13, Mac `metal_frames > 0` bez fallbacku, a w aplikacji tylko wizualizację CPU i benchmark CPU/GPU ze Start/Stop/kopiowaniem. Wynik jednego Maca i iPhone’a X nie jest dowodem pomiarowym dla każdego modelu.
- [ ] **Krok 2: Przeprowadź bramkę na fizycznym urządzeniu.** Uruchom `interactive-24` i `stress-300`, każdą scenę z pełną macierzą `4/8/12/16`, 30 warmup + 300 measured, Release, ten sam iPhone i seed. Skopiuj oba raporty tekstowe bez ręcznego przepisywania. Jeśli smoke 24 baniek nadal wisi albo rażąco przekracza budżet, zatrzymaj się przed kosztowną macierzą `stress-300` i wyraźnie zapisz to ograniczenie.
- [ ] **Krok 3: Przeanalizuj bez automatycznej akceptacji.** Porównaj p50/p95/max pełnej klatki, czasy etapów ukończonego GPU, penetrację p95/max, reszty p95/max, niezbieżne komponenty, zawarcia, non-finite i liczbę fallbacków przy każdym limicie. Uznaj bramkę `10 ms p95` / jakości tylko, jeśli wszystkie warunki wspierają dane z fizycznego urządzenia; inaczej wskaż zmierzone pozostałe wąskie gardło i pierwszą rozbieżność dla kolejnej iteracji.
- [ ] **Krok 4: Udokumentuj użycie biblioteki.** W `README.md` podaj minima iOS 16/macOS 13, CPU fallback, sposób uruchomienia wspólnego CLI na Apple Silicon i granicę interpretacji wyników Mac/iPhone; nie deklaruj pomiarów na nieprzetestowanych modelach.
- [ ] **Krok 5: Zacommituj rzeczywisty raport.** Zacommituj surowe dane i analizę oddzielnie od kodu: `git add docs/benchmarks/reference-gpu-optimized-iphone-2026-10-06.txt docs/benchmarks/reference-gpu-optimized-2026-10-06.md README.md && git commit -m "docs: report optimized reference GPU device result"`.

## Execution Notes

- Pierwszy profil Maca mini z Task 3 jest bramką pomiarową. Jeśli dane etapów przeczą założonym gorącym ścieżkom, popraw Tasks 5–6 przed ich implementacją; nie optymalizuj niezmierzonej fazy siłą rozpędu.
- Każde zadanie ma osobną bramkę przeglądu. Nieudana zgodność CPU↔GPU, hang lub fallback wymaga naprawy przed kontynuacją. Wcześniejsze surowe raporty pozostają niezmiennymi punktami odniesienia.
- Do końcowych raportów może być potrzebny fizyczny iPhone X lub działanie CEO. Brak danych z urządzenia należy zgłosić; czas macOS ich nie zastępuje. Codzienna pętla optymalizacji działa na Macu mini M2 Pro.
- Nie dodawaj do commita `Benchmarks/iOS/BubblePhysicsBench/.DS_Store` ani należących do użytkownika ustawień podpisu Xcode. Nie scalaj do `main` bez decyzji CEO.
