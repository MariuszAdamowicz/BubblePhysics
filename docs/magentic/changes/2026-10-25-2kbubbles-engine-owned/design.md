# Design: BubblePhysics — engine-owned integracja ograniczonego 2KBubbles

**Data:** 2026-10-25

**Status:** Draft

**Tryb:** feature

**Profil:** game-vertical-slice

**Wejście:** Dyspozycja CEO: rozszerzyć BubblePhysics tak, aby ograniczona runda 2KBubbles korzystała wyłącznie z silnikowej fizyki, geometrii i renderingu baniek.

**Wersja pluginu:** 0.1.29

**Sesje agenta:** unknown: UNKNOWN

**Źródła:** Dyspozycja CEO z 2026-10-25; design 2KBubbles w /Volumes/Data/mobile_games/projects/2kbubbles-ios/docs/magentic/changes/2026-10-25-2kbubbles-engine-owned/design.md; BubblePhysics origin/main 25b31d5 (badany kontrakt).

---

## TL;DR

BubblePhysics dostaje trzy publiczne powierzchnie: semantykę prezentacji bańki, wybór aktualnego deformowanego konturu oraz semantyczny spawn w nazwanej fizycznej arenie. Produkt poda tylko wartości, żądania rundy i punkty wejścia; nie poda pozycji spawnu, ścian, konturów, pipeline'ów ani danych per-bańka do rysowania. BubbleWorld zachowa publikację wyłącznie ukończonych klatek, a krok i renderer pozostaną w jednym command bufferze. Renderowana wartość i chwyt będą przypisane do ObjectID w silniku, więc zaakceptowany merge będzie widoczny w pierwszej opublikowanej klatce. Hit-test jest silnikowym zapytaniem do opublikowanej geometrii GPU bez normalnej ścieżki readbacku CPU. Arena jawnie tworzy fizyczne granice — simulationRegion nadal jest wyłącznie obszarem pojemności obliczeń. Design nie obejmuje planu, implementacji, assetów ani produktu 2KBubbles.

## Kontekst i problem

- **Stan obecny:** BubbleWorld jest @MainActor, kolejkuje WorldTransaction i publikuje WorldFrame dopiero po ukończeniu kroku. Wariant advance z command bufferem koduje krok i BubblePhysicsMetalRender do bufora wywołującego. debugContourSnapshot kopiuje kontury GPU na CPU.
- **Problem / szansa:** BubbleDescriptor wymaga pozycji; simulationRegion nie jest fizyczną ścianą; gra musiałaby posiadać spawn i ściany. Renderer ma wewnętrzny atlas etykiet, lecz publiczny kontrakt nie daje wartości ani chwytu powiązanych z bańką, a API nie ma hit-testu deformowanego konturu.
- **Dlaczego teraz:** referencyjny design 2KBubbles zidentyfikował ENGINE-GAP-001…003 i zakazuje zastępowania ich warstwą gry.
- **Powiązanie z PRD:** nie dotyczy; tryb feature dla silnika.

## Cele i granice

### Cele

**G1: Semantyczna prezentacja bańki należy do silnika.**

- [ ] **G1-AC1** — publiczna operacja transakcji przyjmuje tylko dodatnią wartość całkowitą i stan aktywnego chwytu istniejącej bańki; BubblePhysicsMetalRender rysuje wartość i chwyt w tym samym silnikowym przebiegu co wypełnienie oraz deformowany kontur. · weryfikacja: test publicznego API i renderingu Metal.
- [ ] **G1-AC2** — po zaakceptowanym merge wartość rezultatu jest widoczna w pierwszej opublikowanej klatce zawierającej jego TransactionReceipt; odrzucona transakcja nie zmienia wartości ani chwytu. · weryfikacja: test publikacji frame/receipt i test obrazu.
- [ ] **G1-AC3** — integrator nie dostarcza shadera, pipeline'u, widoku ani nakładki dla liczby, konturu lub chwytu; standardowa ścieżka nie wywołuje debugContourSnapshot. · weryfikacja: test kontraktu i audit integracji.

**G2: Wybór dla dragu odpowiada faktycznemu deformowanemu konturowi.**

- [ ] **G2-AC1** — BubbleWorld udostępnia asynchroniczne zapytanie wyboru punktu względem ostatniej opublikowanej geometrii deformowanych baniek, zwracające najwyżej jeden stabilny ObjectID albo nil. · weryfikacja: test wnętrza, granicy, zagłębienia deformacji i pustego miejsca.
- [ ] **G2-AC2** — wynik wyboru zasila następną beginPlayerDrive; updatePlayerDrive i endPlayerDrive zachowują DriveFeedback, a brak wyboru nie uruchamia drive. · weryfikacja: test begin/update/end i anulowania.
- [ ] **G2-AC3** — wybór nie wystawia grze pozycji, promienia ani wierzchołków i nie wymaga CPU readbacku normalnej ścieżki. · weryfikacja: contourCPUReadbacks = 0 podczas testu drag.

**G3: Spawn i arena są semantyczne oraz fizyczne.**

- [ ] **G3-AC1** — prośba o spawn przyjmuje BubbleValue, identyfikator/preset areny i deterministyczny seed; gra nie przekazuje pozycji, prędkości ani ścian. · weryfikacja: test API bez współrzędnych w request.
- [ ] **G3-AC2** — ta sama arena i seed dają tę samą sekwencję wyników spawnu/identyfikatorów, a pozycję wybiera silnik. · weryfikacja: test deterministyczności dwóch światów.
- [ ] **G3-AC3** — arena tworzy silnikowe, statyczne granice kolizji; bańka nie przechodzi przez nie przy BubbleDrivePolicy, a simulationRegion nie jest ścianą. · weryfikacja: test czterech ścian i modelu.

**G4: Kontrakt zachowuje publikację i jedną pełną klatkę GPU.**

- [ ] **G4-AC1** — transakcja semantyki, spawn, hit-test opublikowanej klatki i render zachowują model @MainActor: zapytanie nie widzi kroku w toku, a błąd renderu zachowuje poprzednią klatkę. · weryfikacja: test publikacji i render failure.
- [ ] **G4-AC2** — wariant advance z command bufferem pozostaje jednym command bufferem dla fizyki i renderu; API integratora nie ujawnia CPU/GPU. · weryfikacja: rozszerzony test command buffer.
- [ ] **G4-AC3** — po implementacji raport Release na fizycznym iPhonie X mierzy p95 i maksimum CPU od wejścia do zakodowania, GPU command buffera oraz pełną klatkę od wejścia do prezentacji, dla spawnów, dragu, merge i gęstej areny. · weryfikacja: 120 klatek rozgrzewki + 300 mierzonych; 15,1783 ms p95 biblioteki nie jest budżetem gry.

### Poza zakresem

- Plan, implementacja, assety, release i modyfikacja 2KBubbles, referencji historycznej lub zamrożonego worktree.
- Split, monetyzacja, backend, kampania, zapis rundy, logika pełnej gry i produktowy HUD per-bańka.
- Uogólniony system tekstu, arbitralne shadery gry lub publiczny wybór backendu.

## Podejście i granice odpowiedzialności

Nowe publiczne typy są wejściem semantycznym; wykonanie wybiera tylko BubbleWorld/native Metal. BubblePresentation zawiera value: Int i isGrabbed: Bool, jest atomową operacją setBubblePresentation, a mergeBubbles przyjmuje rezultat z prezentacją. Wartość jest dodatnia; nie jest teksturą, pozycją ani stylem gry. Renderer używa własnego atlasu i instancji zakotwiczonej w centrum/masce deformowanej bańki. Chwyt jest parametrem silnikowego materiału/obrysu, nie geometrią UI.

selectBubble(at:) async -> ObjectID? korzysta z opublikowanego handoffu: native Metal koduje point-in-deformed-contour na GPU i publikuje mały wynik identyfikatora razem z ukończoną klatką. Zapytanie zwraca ostatni wynik opublikowany, nigdy kandydata w toku. Przy nakładaniu wygrywa ostatnia bańka w deterministycznym porządku renderowania. To nie jest debugContourSnapshot, promień ani analiza AABB gry.

ArenaPreset definiuje nazwę, wymiary, statyczne granice i politykę deterministycznego spawnu. WorldConfiguration otrzymuje opcjonalny preset, a fabryka świata instaluje niewidoczne, statyczne granice w runtime. SpawnBubbleRequest(value:arena:seed:) jest operacją świata i zwraca identyfikator przez receipt. Nie usuwa istniejącego BubbleDescriptor: zachowuje kompatybilność dla obecnych klientów, ale 2KBubbles korzysta wyłącznie z nowej ścieżki.

## Manifest komponentów

| Ścieżka / komponent | Nowy / zmieniany | Jedna odpowiedzialność | Zależności / kontrakt |
|---|---|---|---|
| BubblePhysicsPublic/Model/Presentation.swift | nowy | BubblePresentation, walidacja wartości | brak danych geometrii |
| BubblePhysicsPublic/Model/Arena.swift | nowy | ArenaPreset, SpawnBubbleRequest, seed | bez współrzędnych gry |
| WorldTransaction.swift | zmieniany | operacje prezentacji i spawn | kolejność, receipt, atomowość |
| BubbleWorld.swift | zmieniany | publikacja, selectBubble, arena | @MainActor, ukończone klatki |
| BubblePhysicsRuntime | zmieniany | staging, granice, seed | nie zmienia simulationRegion |
| BubblePhysicsNativeMetal | zmieniany | GPU hit-test i prezentacja | wynik z handoffem |
| BubblePhysicsMetalRender | zmieniany | maskowany tekst/chwyt z konturem | bez pipeline'u produktu |
| testy publiczne/native/render | zmieniane | dowód API, renderu, hit-testu, areny | zero normalnych readbacków |
| benchmark iOS | zmieniany później | telemetria Release urządzenia | nie benchmark biblioteki |

## Stan, dane i przepływy

- Semantyka prezentacji, spawn i merge są staged z resztą transakcji. Dopiero zaakceptowany batch aktualizuje stan i render state; receipt jest granicą widoczności wartości po merge.
- Render handoff przechowuje ObjectID → BubblePresentation. Label i chwyt używają tego samego zakresu deformowanej geometrii co wypełnienie, bez własnej pozycji lub czasu.
- Zapytanie wyboru używa snapshotu oznaczonego stepIndex. nil jest poprawne dla pustego miejsca, braku klatki i usuniętej bańki.
- Seed jest stanem areny/requestu. Gdy brak legalnego miejsca, transakcja zostaje odrzucona, bez fallbacku współrzędnych gry.

## Błędy, przerwania i odzyskiwanie

| Sytuacja | Oczekiwane zachowanie | Dowód |
|---|---|---|
| niepoprawna wartość, arena nieznana, brak miejsca | rejection bez częściowego spawnu/publikacji | test walidacji i receipt |
| punkt nie wybiera bańki | nil; brak beginPlayerDrive | test pustego punktu |
| usunięcie między wyborem a begin | objectNotFound, bez crasha | test kolejki |
| błąd renderu/command buffer | poprzedni frame i wynik wyboru zostają opublikowane | test render failure |
| anulowanie dotyku / tło | integrator wysyła endPlayerDrive; chwyt znika po receipt | test cancel |

## Platforma i doświadczenie

- iOS/Metal: krok świata i render pozostają w jednym command bufferze; zwykła ścieżka nie czyta konturu na CPU.
- Wartość i chwyt są widoczne wyłącznie jako część bańki. HUD może przekazać dostępny stan rundy, ale nie powiela danych per-bańka. Nie tworzy się assetów.
- Raport iPhone X podaje liczbę obiektów, contourCPUReadbacks, fallbacki, błędy command bufferów, non-finite i overflow zdarzeń. Wszystkie liczniki bezpieczeństwa muszą wynosić zero; brak danych lub p95 pełnej klatki ponad 16,67 ms wymaga decyzji CEO.

## Testowanie i weryfikacja

1. Model/API: walidacja wartości, chwytu i areny, zachowanie starych konstruktorów oraz brak backendu w API.
2. Publikacja: wartość rezultatu merge i chwyt występują w klatce z receipt; rejection i render failure zachowują poprzedni stan.
3. Metal: wartość/chwyt są zakotwiczone i maskowane deformowanym konturem, brak pipeline'u produktu, a krok+render są w tym samym command bufferze.
4. Hit-test: wnętrze, granica, zagłębienie, pustka, nakładanie z tie-breakiem i usunięcie; drag zapisuje DriveFeedback i zero readbacków.
5. Arena: cztery fizyczne granice, niezmieniona semantyka simulationRegion, powtarzalny seed i atomowe odrzucenie pełnej areny.
6. Po implementacji: Release iPhone X, 120+300 klatek dla czterech scenariuszy; CPU/GPU/pełna klatka p95 i maksimum, bez ekstrapolacji z benchmarku biblioteki.

## Decyzje

| ID | Decyzja | Opcje | Wybór i uzasadnienie | Źródło | Wpływ | Konsekwencje |
|---|---|---|---|---|---|---|
| DES-D-001 | render semantyki | overlay gry; silnik | silnik: CEO zakazuje renderingu per-bańka przez produkt, renderer ma deformowaną geometrię | użytkownik + kod renderera | G1 | rozszerzenie renderera i testów |
| DES-D-002 | hit-test | promień/CPU; GPU query | GPU opublikowanej geometrii: prawdziwy kontur bez zwykłego readbacku | użytkownik + debugContourSnapshot | G2 | asynchroniczna publikacja |
| DES-D-003 | spawn/arena | współrzędne gry; semantyka silnika | semantic request + ArenaPreset; simulationRegion nie zmienia znaczenia | użytkownik + WorldConfiguration | G3 | kompatybilna nowa ścieżka |
| DES-D-004 | kompatybilność | zastąpienie API; dodanie API | dodać typy/operacje, zachować BubbleDescriptor, WorldTransaction, DriveFeedback | auto (publiczne API) | G1–G4 | brak zmiany łamiącej v1 |

## Fakty i założenia

- **Fakt:** advance z command bufferem publikuje po ukończeniu command buffera; to niezmiennik.
- **Fakt:** simulationRegion jest „nigdy fizyczną ścianą”; granice areny są osobnymi obiektami silnika.
- **Założenie do potwierdzenia implementacją:** GPU point query można zakodować bez odczytu wierzchołków CPU; brak możliwości oznacza powrót do designu, nie fallback gry.
- **Niezmiennik:** normalna integracja nie używa debugContourSnapshot ani nie kopiuje stanu bańki.

## Rejestr review

| Runda | Wynik | Uwagi / zapis |
|---|---|---|
| 1 | oczekuje | niezależny review po commicie artefaktu |
