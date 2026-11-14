# Change Design: Ściskanie zamiast odrzucenia kroku w tłoku baniek (v2.2.0)

**Date:** 2026-11-14
**Artifact:** change-design
**Status:** Draft
**Template version:** default/0.3.2
**References:** `../2KBubbles-iOS/docs/benchmarks/stage-0-physics-gate.md`, sekcja „Specyfikacja zmiany silnika” (stan 2026-11-14); dane `../2KBubbles-iOS/docs/benchmarks/stage-0/` (`crowd-growth.json`, `crowd-growth-free-spawn.json`, `grab-scan.json`)

**Plugin version:** 0.7.10
**Agent Sessions:** claude-code: 65849c84-3e5c-4a2f-8227-dee99104ae9e

---

<!-- hint: Keep the `**Artifact:** change-design` line — /plan and /implement use it to recognize this as a change-design artifact (requirements + design in one file) and skip the prd.md requirement. -->

> *Section audience —* 🔍 reviewer (understand the change without implementing it) · 🛠 author (implement the change). Sections without an icon serve both.

## Summary 🔍

Gra 2KBubbles zatrzymała się na silniku v2.1.0. W gęstym tłoku silnik odrzuca kroki z powodem `solverGuard`, a po pięciu odrzuceniach z rzędu gra ogłasza awarię planszy. Tak kończy się 36 z 36 pomiarów wzrostu w tłoku. Do tego duże bańki prawie się nie uginają, a małe są miażdżone.

Wersja 2.2.0 zmienia to zachowanie:
- Układ baniek, który da się postawić poprawnie, rozwiązuje się zawsze ściśnięciem konturów i ograniczonymi siłami. Bańka w bańce, wynik scalenia w zajętym miejscu i prawie wspólny środek nie odrzucają kroku.
- Zły punkt podany przez grę (ten sam środek co inna bańka, wnętrze bryły sztywnej, punkt poza regionem) odrzuca tylko transakcję, z nazwaną przyczyną. Zły punkt wyniku scalenia silnik poprawia sam.
- Krok może jeszcze odrzucić tylko przekroczenie przez środek ściany albo bryły w trakcie symulacji. Przyczynę tego odrzucenia widać w diagnostyce, a pary „bańka w bańce” widać w osobnym liczniku.

Rdzeniem zmiany jest miękki kontakt XPBD (Extended Position Based Dynamics) między bańkami. Jego podatność opisuje materiał w dwóch wymiarach: jak podatność zależy od promienia nominalnego bańki i jak sztywnieje albo mięknie bańka pod ściśnięciem. Wgniecenie konturu pary dzieli się w proporcji podatności obu baniek. Domyślna podatność wynosi 0, więc zostaje dzisiejszy twardy kontakt i dzisiejszy kontur.

## Background & problem 🔍

Raport etapu 0 gry 2KBubbles (`stage-0-physics-gate.md`) pokazuje trzy zachowania v2.1.0, które blokują grę:

1. **Odrzucanie kroku w tłoku.** Strażnik środka (`nativeGuardCenter`, `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source:183-205`) i walidator zawierania (`nativeValidateBubbleContainment`, `:350-363`) zapalają bit 2. Dzieje się to, gdy środek przechodzi przez ścianę albo leży we wnętrzu bryły, oraz gdy mniejsza bańka mieści się cała w większej. Bit 2 staje się `WorldRejectionReason.solverGuard` (`Sources/BubblePhysicsPublic/BubbleWorld.swift:423`). Świat żyje, ale krok jest odrzucony, a transakcja czeka w kolejce. Kontakt jest twardy: `NativeMetalConfiguration.contactCompliance` = 0 (`Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift:1-16`). Przy bilansie pól powyżej 1 pełne rozdzielenie kół jest niemożliwe, więc solver przepycha środki przez ściany i jedne bańki w drugie. Świat staje przy bilansie pól 0,85–1,81, często zanim zabraknie miejsca.
2. **Miękkość odwrotna do prawa Laplace'a.** Wgniecenie z nacisku to `clamp(λ · invMass / r, 0, 0,5)` (`NativePostSolveKernels.metal-source:700-702`), więc ciężka duża bańka się nie ugina, a mała bierze cały zgniot. Bańka „2” ma w tłumie promień efektywny 0–8 pt, a do chwytu potrzeba 16 pt. `deformability` ma sufit 1 (`Sources/BubblePhysicsPublic/Model/Resources.swift:26`), a podatności kontaktu gra w ogóle nie widzi.
3. **Jedna ogólna przyczyna.** Gra nie odróżnia odrzucenia za ścianę od odrzucenia za bańkę w bańce.

```mermaid
flowchart LR
  subgraph before["v2.1.0"]
    a1["twardy kontakt PBD<br/>(compliance 0)"] --> a2["tłok: residuum nie spada,<br/>środki przepchnięte"]
    a2 --> a3["strażnik: ściana / bańka w bańce<br/>bit 2"]
    a3 --> a4["stepFailed + solverGuard<br/>kolejka stoi"]
  end
```

```mermaid
flowchart LR
  subgraph after["v2.2.0"]
    b0["walidacja punktu w transakcji<br/>(add / replace / merge)"] -->|zły punkt gry| b5["transactionRejected<br/>invalidPlacement"]
    b0 --> b1["kontakt XPBD z podatnością<br/>c(r, ρ) z materiału"]
    b1 --> b2["tłok: nakładanie ograniczone siłą,<br/>kontur ściśnięty wg c_a : c_b"]
    b2 --> b3["bańka w bańce: ograniczone<br/>wypychanie, licznik par"]
    b2 --> b4["środek przez ścianę lub bryłę:<br/>stepFailed + lastSolverGuardCause"]
  end
```

## Goals and non-goals

### Goals

**G1: Tłok nie odrzuca kroku**
Układ baniek postawionych w poprawnych punktach nigdy nie kończy się odrzuconym krokiem ani awarią świata, nawet gdy suma pól docelowych wielokrotnie przekracza pole planszy. Rosnący nacisk daje coraz mocniejsze ściśnięcie konturów, a środki nie wychodzą poza ściany. To obowiązuje dla każdej podatności, także dla domyślnego kontaktu twardego.
- [ ] G1-AC1 — Na planszy 360 × 640 z czterema ścianami (bryły sztywne) stawiamy po kolei bańki, które rosną od 10% do pełnego promienia w ciągu 1 s, aż bilans pól dojdzie do 2,5. Potem świat robi 600 kroków (10 s). W całym przebiegu `lastAdvanceIssue` nie przyjmuje `stepFailed` ani `worldFailed`, `failureReason == nil`, nie ma zdarzeń `didExitSimulationRegion` i żadna bańka nie znika z klatki. · `verify: test na urządzeniu Metal przez publiczne BubbleWorld, osobno dla materiału z podatnością 0 i dla materiału z podatnością dodatnią`
- [ ] G1-AC2 — W tym samym przebiegu środek każdej bańki w każdej klatce leży wewnątrz prostokąta ograniczonego wewnętrznymi krawędziami ścian. · `verify: asercja na pozycjach z każdej klatki w teście G1-AC1`
- [ ] G1-AC3 — Przy materiale z podatnością dodatnią i stałym tłoku średni promień efektywny baniek (z `WorldFrame`) przy bilansie 2,5 jest mniejszy niż przy bilansie 1,5. Silniejszy nacisk daje więc mocniejsze ściśnięcie, a nie awarię. · `verify: dwa przebiegi testu G1-AC1 z różnym bilansem, porównanie średniego stosunku promienia efektywnego do docelowego`

**G2: Bańka w bańce i trudne punkty rozwiązuje siła, nie odrzucenie**
Bańka dodana częściowo albo całkiem wewnątrz innej, wynik scalenia, którego środek wypada w miejscu zajętym przez trzecią bańkę, i dwie bańki o prawie wspólnym środku dają w kolejnych krokach rozsunięte bańki. Rozsuwanie idzie bez odrzucenia kroku, bez skoków i bez teleportu.
- [ ] G2-AC1 — Bańkę r = 20 dodajemy ze środkiem 5 jednostek od środka bańki r = 60 na pustej planszy. Żaden krok nie jest odrzucony. `WorldDiagnostics.containedBubblePairCount` jest równy 1 w pierwszej klatce po dodaniu i spada do 0 w ciągu 2 s symulacji. · `verify: test publicznego BubbleWorld`
- [ ] G2-AC2 — W przebiegu z G2-AC1 przesunięcie środka każdej bańki między dwiema kolejnymi klatkami nie przekracza udokumentowanego limitu na krok (CD-D-9). · `verify: asercja na różnicy pozycji kolejnych klatek`
- [ ] G2-AC3 — Dwie bańki dodane w tej samej transakcji, ze środkami oddalonymi o 0,01 jednostki, są przyjęte i w ciągu 2 s rozsunięte tak, że żadna nie zawiera drugiej, bez odrzuconego kroku. · `verify: test publicznego BubbleWorld`
- [ ] G2-AC4 — `mergeBubbles` dwóch baniek, których punkt styku leży wewnątrz trzeciej bańki, kończy się zdarzeniem `didAdd` wyniku. Nie ma `transactionRejected` ani odrzuconego kroku w ciągu 2 s. · `verify: test publicznego BubbleWorld`
- [ ] G2-AC5 — W tłoku z G1-AC1 (bilans 2,5) `containedBubblePairCount` po każdej klatce jest liczbą skończoną i nieujemną, a krok nie jest odrzucony, także wtedy, gdy licznik jest większy od 0. · `verify: asercja w teście G1-AC1`

**G3: Zły punkt od gry odrzuca transakcję, a zły punkt scalenia silnik poprawia sam**
Punkt, w którym bańki nie da się poprawnie postawić, wraca do gry jako odrzucona transakcja z nazwaną przyczyną. Świat działa dalej i gra może wysłać nowy punkt. Punkt wyniku scalenia wybiera silnik, więc silnik sam go poprawia.
- [ ] G3-AC1 — `add` bańki ze środkiem w tym samym miejscu co środek istniejącej bańki (odległość poniżej progu z CD-D-7) daje w klatce zdarzenie `transactionRejected(token, rejection)` z `rejection.reason == .invalidPlacement(id, .coincidentCenter)`. Bańka się nie pojawia, a następny krok (z inną transakcją) jest przyjęty. · `verify: test publicznego BubbleWorld`
- [ ] G3-AC2 — `add` bańki ze środkiem we wnętrzu wielokąta bryły sztywnej daje `.invalidPlacement(id, .insideRigidBody)`. Ze środkiem poza `simulationRegion` daje `.invalidPlacement(id, .outsideRegion)`. W obu przypadkach świat przyjmuje następny krok. · `verify: test publicznego BubbleWorld`
- [ ] G3-AC3 — `replace` bańki na bańkę w złym punkcie odrzuca transakcję z tymi samymi przyczynami co `add`. · `verify: test publicznego BubbleWorld`
- [ ] G3-AC4 — `mergeBubbles`, którego punkt styku leży dokładnie w środku trzeciej bańki, we wnętrzu bryły albo poza regionem, kończy się `didAdd` wyniku. Środek wyniku w pierwszej klatce nie pokrywa się ze środkiem żadnej innej bańki, nie leży we wnętrzu bryły i leży w regionie. Ten sam układ wejściowy daje zawsze ten sam środek wyniku. · `verify: test publicznego BubbleWorld, dwa przebiegi z porównaniem pozycji`
- [ ] G3-AC5 — Transakcja z poprawnymi punktami, w tym bańka częściowo nachodząca na inną, nie jest odrzucana za punkt. · `verify: test publicznego BubbleWorld`

**G4: Podatność kontaktu opisana w materiale w dwóch wymiarach**
Materiał bańki opisuje podatność kontaktu w dwóch wymiarach: jak podstawowa podatność zmienia się z promieniem nominalnym bańki i jak zmienia się sztywność wraz ze ściśnięciem (opis znormalizowany). Gra może nadpisać podstawową podatność dla jednej bańki. Podatność 0 zachowuje zachowanie v2.1.0.
- [ ] G4-AC1 — Dwie bańki r = 20 i r = 40 z tym samym materiałem (podatność podstawowa > 0, wykładnik promienia > 0, wykładnik ściśnięcia = 0) dociskamy do ściany tą samą stałą siłą (`MotorDrive`). Po uspokojeniu (1 s) stosunek spadku promienia efektywnego do promienia docelowego jest większy dla bańki r = 40. · `verify: test publicznego BubbleWorld`
- [ ] G4-AC2 — Ta sama scena z ujemnym wykładnikiem promienia daje odwrotną kolejność: większy względny spadek ma bańka r = 20. · `verify: ten sam test, drugi przypadek`
- [ ] G4-AC3 — Przy wykładniku ściśnięcia > 0 podwojenie siły docisku zwiększa względne ściśnięcie bańki mniej niż dwukrotnie. Przy wykładniku 0 zwiększa je dwukrotnie (± 20%). · `verify: test publicznego BubbleWorld, dwie siły na bańkę`
- [ ] G4-AC4 — W parze bańka sztywna (podatność 0) i bańka miękka dociśniętej do siebie sztywna zachowuje promień efektywny równy docelowemu (± 1%), a ściśnięcie bierze miękka. · `verify: test publicznego BubbleWorld`
- [ ] G4-AC5 — `contactCompliance` ustawione w `BubbleDescriptor`, a także w `BubbleResult` dla wyniku scalenia, nadpisuje podstawową podatność materiału tylko tej bańki. Dwie bańki z tym samym materiałem i różnym nadpisaniem uginają się różnie w scenie G4-AC1, a bańka bez nadpisania zachowuje się jak bez niego. · `verify: test publicznego BubbleWorld`
- [ ] G4-AC6 — Materiał bez parametrów podatności (wartości domyślne) daje te same pozycje i kontury co v2.1.0. Istniejące testy kroku, konturu i renderu przechodzą bez zmian oczekiwań, poza testami, które celowo sprawdzały odrzucenie za bańkę w bańce (te zmieniają się zgodnie z G2). · `verify: swift test na całym pakiecie; lista zmienionych oczekiwań w opisie PR`
- [ ] G4-AC7 — Podatność ujemna albo nieskończona, wykładnik nieskończony, promień odniesienia ≤ 0 i podatność > 0 w materiale `kind: .rigid` rzucają `ModelValidationError.valueOutOfRange` przy tworzeniu materiału. Ujemne albo nieskończone `contactCompliance` rzuca przy tworzeniu deskryptora. · `verify: test jednostkowy modelu`

**G5: Przyczyna odrzucenia i zawieranie są publicznie widoczne**
- [ ] G5-AC1 — Gdy krok zostaje odrzucony, bo środek bańki w trakcie symulacji przeszedł przez ścianę albo wszedł we wnętrze bryły, `lastRejectionReason == .solverGuard` i `lastSolverGuardCause == .centerCrossing`. · `verify: test publicznego BubbleWorld z bryłą kinematyczną przesuniętą jednym krokiem na środek bańki przyciśniętej do ściany`
- [ ] G5-AC2 — `lastSolverGuardCause` jest `nil`, gdy żaden krok nie został jeszcze odrzucony albo ostatnie odrzucenie miało inny powód niż `.solverGuard`. · `verify: test publicznego BubbleWorld`
- [ ] G5-AC3 — `containedBubblePairCount` podaje liczbę par baniek, z których mniejsza mieści się cała w kole większej, po ostatnim ukończonym kroku. Na pustej planszy wynosi 0. · `verify: G2-AC1 i test pustej planszy`

**G6: Wydanie 2.2.0**
- [ ] G6-AC1 — Repozytorium ma tag `v2.2.0`. `CHANGELOG.md` opisuje nowe pola i przypadki, w tym nowy przypadek `TransactionRejectionReason.invalidPlacement` jako zmianę, która może wymagać gałęzi `default` w wyczerpującym `switch`, oraz zmianę semantyki zawierania. `README.md` podaje wersję 2.2.0, a `docs/integration-guide.md` opisuje podatność materiału i nadpisanie na bańce. · `verify: przegląd plików i git tag`
- [ ] G6-AC2 — Strażnik wydajności (`swift run -c release BubblePhysicsPerfGuard`) przechodzi na Macu z tymi samymi progami co dla 2.1.0. · `verify: uruchomienie strażnika`

### Non-goals

- Test przeciskania (W4 ze specyfikacji) i dobór parametrów gry: oba należą do 2KBubbles po tagu.
- Zmiany w repozytorium 2KBubbles, w tym podbicie wersji silnika.
- Ujawnianie liczby iteracji solvera grze (`makeBenchmarkWorld` zostaje `package`).
- Miękkie ściany i bryły: kontakt bańka–bryła używa tylko podatności bańki.
- Zmiana domyślnego zachowania: bez nowych parametrów silnik zachowuje się jak v2.1.0, poza brakiem odrzuceń z G2.
- Pomiary na iPhonie X i limit liczby baniek.

## Architecture

Zmiana ma cztery części, od wejścia do wyjścia kroku.

**1. Walidacja punktu w transakcji (G3).** `TransactionStager` (`Sources/BubblePhysicsRuntime/TransactionStager.swift`) przy `add`, `replace` i `mergeBubbles` sprawdza środek nowej bańki względem stanu po wcześniejszych operacjach tej samej transakcji:
- odległość od środka każdej innej bańki poniżej progu `coincidentCenterTolerance` (CD-D-7) daje `.coincidentCenter`;
- punkt we wnętrzu wielokąta, koła lub kapsuły bryły sztywnej daje `.insideRigidBody`;
- punkt poza `simulationRegion` daje `.outsideRegion`.

Przy `add` i `replace` błąd odrzuca całą transakcję istniejącą drogą `TransactionRejection` z nowym przypadkiem `invalidPlacement(ObjectID, PlacementIssue)`. Przy `mergeBubbles` silnik nie odrzuca transakcji. `StructuralOperations.mergeCenter` (`Sources/BubblePhysicsRuntime/StructuralOperations.swift:10`) zwraca punkt styku, a nowa funkcja `StructuralOperations.resolvedMergeCenter` sprawdza go tym samym testem i przy błędzie próbuje deterministycznie kolejnych kandydatów. Kolejność kandydatów:
1. punkty na odcinku między środkami źródeł;
2. środki źródeł;
3. punkty na spirali wokół środka źródła o największej masie, z krokiem równym progowi.

Lista jest skończona, a środek źródła był poprawnym punktem przed scaleniem, więc ostatni krok zawsze trafia w poprawny punkt (CD-D-6).

**2. Podatność kontaktu (G1, G4).** `PhysicsMaterial` dostaje pole `contactCompliance: BubbleContactCompliance` z czterema wartościami:
- `base` c₀ ≥ 0, domyślnie 0;
- `referenceRadius` r_ref > 0;
- `radiusExponent` s;
- `compressionExponent` k.

`BubbleDescriptor` i `BubbleResult` dostają `contactCompliance: Float?`, które zastępuje c₀ jednej bańki. Podatność bańki w kroku to:

c = c₀ · (r / r_ref)^s · ρ^k,

gdzie r to promień docelowy, a ρ ∈ (0, 1] to stosunek promienia konturu do promienia docelowego w kierunku kontaktu z poprzedniej opublikowanej klatki. ρ ograniczamy od dołu wartością `ρ_min` (stała silnika, np. 0,01), żeby przy k < 0 podatność nie rosła do nieskończoności. Dolna granica konturu wynosi 0. Część c₀ · (r / r_ref)^s liczy host w `NativePublicWorld` (`Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift:158-171`) i zapisuje w nowych polach `NativeBubble` (`contact: float4` = część bazowa, k, rezerwa). Czynnik ρ^k liczy GPU.

W `nativeUpdateContactMultipliers` (`Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source:399-419`) `alpha` przestaje być stałą świata (`solver.physics.x`) i staje się podatnością pary podzieloną przez dt²:
- para bańka–bańka: α = (c_a + c_b) / dt²;
- para bańka–bryła: α = c_a / dt².

`nativeMeasureResidual` (`:439-459`) używa tego samego α. Przy c₀ = 0 dla obu stron α = 0, czyli dzisiejszy twardy PBD, bit w bit.

**3. Kontur według podziału podatności (G4).** W `nativeAccumulateContactPressure` (`NativePostSolveKernels.metal-source:665-750`) para, w której choć jedna strona ma c > 0, wycina kontur bańki a na głębokość nakładanie · c_a / (c_a + c_b), liczoną od jej brzegu wzdłuż normalnej pary. Kontakt ze ścianą lub bryłą wycina całe nakładanie bańki miękkiej. Bańka, której wszystkie pary mają c = 0 po obu stronach, idzie dzisiejszą drogą: cięciwa radykalna i nacisk `λ · invMass / r` z sufitem 0,5, bez zmian (G4-AC6). Sufit 0,5 nie dotyczy drogi miękkiej.

**4. Strażniki bez odrzucenia za zawieranie (G2, G5).**
- `nativeSeparateContainedBubbles` i `nativeSeparateAndGuardContainedBubbles` (`NativePostSolveKernels.metal-source:213-318`) dalej rozsuwają pełne zawieranie, ale korekcja jednej bańki na krok jest ograniczona do `containmentCorrectionLimit` · r_mniejszej (CD-D-9). Zawieranie znika więc w kilku krokach, bez teleportu. Kierunek przy prawie wspólnym środku zostaje deterministyczny (kolejność ID, `:240`).
- `nativeValidateBubbleContainment` (`:350-363`) nie zapala bitu 2. Liczy pary zawarte atomowo do nowego licznika w `safetyControl`, a host publikuje go jako `WorldDiagnostics.containedBubblePairCount`.
- `nativeGuardCenter` (`:183-205`) zapala nowy bit `centerCrossing` razem z dotychczasowym bitem 2. `NativeMetalSolver` (`Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift:946-951`) przenosi przyczynę w `NativeMetalSafetyFailure`, a `BubbleWorld.handleAdvanceError` (`Sources/BubblePhysicsPublic/BubbleWorld.swift:378-393`) ustawia `lastSolverGuardCause`. Odrzucenie zostaje tylko dla środka, który w trakcie symulacji przeszedł przez ścianę albo wszedł we wnętrze bryły i nie dał się zrzutować (Q4).

```mermaid
flowchart TD
  tx["transakcja add / replace / merge"] --> val{"punkt poprawny?"}
  val -->|"add / replace: nie"| rej["transactionRejected<br/>invalidPlacement"]
  val -->|"merge: nie"| alt["resolvedMergeCenter<br/>kolejny kandydat"] --> val
  val -->|tak| host["NativePublicWorld:<br/>c₀·(r/r_ref)^s, k → NativeBubble.contact"]
  host --> xpbd["XPBD: α = (c_a+c_b)/dt² · ρ^k"]
  xpbd --> guard["strażnik środka<br/>+ ograniczona naprawa zawierania"]
  guard -->|"środek przez ścianę"| step["stepFailed<br/>lastSolverGuardCause = .centerCrossing"]
  guard --> count["licznik containedBubblePairCount"]
  guard --> contour["kontur: wgniecenie wg c_a : c_b<br/>(c=0 obu stron: droga v2.1.0)"]
```

## Components

- **`Sources/BubblePhysicsPublic/Model/Resources.swift`**: `BubbleContactCompliance` (c₀, r_ref, s, k, wartość `.hard`) i pole `PhysicsMaterial.contactCompliance` z walidacją (G4-AC7).
- **`Sources/BubblePhysicsPublic/Model/Objects.swift`**: `BubbleDescriptor.contactCompliance: Float?` z walidacją.
- **`Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`**: `BubbleResult.contactCompliance: Float?`, przenoszone na wynik scalenia i podziału.
- **`Sources/BubblePhysicsPublic/Model/WorldFrame.swift`**: `TransactionRejectionReason.invalidPlacement(ObjectID, PlacementIssue)` i wyliczenie `PlacementIssue` (`.coincidentCenter`, `.insideRigidBody`, `.outsideRegion`).
- **`Sources/BubblePhysicsPublic/Diagnostics.swift`**: `SolverGuardCause` (`.centerCrossing`), pola `WorldDiagnostics.lastSolverGuardCause` i `containedBubblePairCount`.
- **`Sources/BubblePhysicsPublic/BubbleWorld.swift`**: przeniesienie przyczyny strażnika i licznika zawierania do diagnostyki.
- **`Sources/BubblePhysicsRuntime/TransactionStager.swift`**: walidacja punktu przy `add`, `replace` i `mergeBubbles`.
- **`Sources/BubblePhysicsRuntime/StructuralOperations.swift`**: `resolvedMergeCenter`, czyli deterministyczna lista kandydatów; przeniesienie nadpisania podatności na wynik.
- **`Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`**: wyliczenie części bazowej podatności i k dla każdej bańki.
- **`Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`** i struktura `NativeBubble` w `Shaders/NativeGeometryKernels.metal-source:4-16`: nowe pole `contact`, z aktualizacją testu ABI (`Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`).
- **`Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`**: α pary w `nativeUpdateContactMultipliers` i `nativeMeasureResidual`.
- **`Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`**: podział wgniecenia w `nativeAccumulateContactPressure`, limit korekcji zawierania, licznik zawierania zamiast bitu 2, bit przyczyny w `nativeGuardCenter`.
- **`Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`**: odczyt nowego bitu i licznika, przyczyna w `NativeMetalSafetyFailure`.
- **`Tests/BubblePhysicsRuntimeTests/`**: nowe testy G1–G5 na publicznym `BubbleWorld` oraz zmiana oczekiwań w `BubbleWorldCompletionTests.swift:56` (zawieranie nie odrzuca kroku).
- **`Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`**: walidacja G4-AC7.
- **`CHANGELOG.md`, `README.md`, `docs/integration-guide.md`**: wydanie 2.2.0 (G6).

## Error handling

- Podatność wyliczona na GPU okazuje się nieskończona albo NaN (np. przez skrajny wykładnik). Krok kończy się istniejącą ścieżką `nonFiniteValues`, czyli `worldFailed`, jak każda inna wartość nieskończona. Walidacja materiału (G4-AC7) odrzuca nieskończone parametry, a `ρ_min` chroni przed dzieleniem przez zero, więc ta ścieżka nie powinna się pojawiać w poprawnych danych.
- Transakcja z kilkoma operacjami, z których jedna ma zły punkt, jest odrzucona w całości, zgodnie z istniejącą semantyką `TransactionRejection.operationIndex`.

## Testing & verification

- Test regresji G4-AC6: cały `swift test` na Macu z urządzeniem Metal. W opisie PR wymieniamy każde zmienione oczekiwanie i jego powód.
- Strażnik wydajności G6-AC2, bo kontur i solver dostają dodatkowe obliczenia na parę.

## Decisions 🔍

| ID | Title | Context | Options | Choice | Rationale | Source | Goal impact | Consequences |
|----|-------|---------|---------|--------|-----------|--------|-------------|--------------|
| CD-D-1 | Test przeciskania poza zmianą | W4 wymagało testu przeciskania jako warunku tagu; najpierw wybrano test w 2KBubbles w tej zmianie | test w silniku; test w grze w tej zmianie; brak testu w zmianie | brak: test przeciskania i dobór parametrów robi gra po tagu | Właściciel uznał, że parametryzowana podatność wystarczy grze do zaliczenia testu po swojej stronie | `user` | usuwa W4 z celów; G1–G4 zastępują je testami silnika | zmiana nie dotyka repozytorium 2KBubbles; ryzyko, że parametry nie wystarczą, wychodzi dopiero w grze |
| CD-D-2 | Przyczyna odrzucenia jako dodatkowe pole | Dziś istnieje tylko `.solverGuard`, a wersja ma być minor | nowe pole `lastSolverGuardCause`; nowe przypadki `WorldRejectionReason` (3.0.0); wartość powiązana (3.0.0) | nowe pole `WorldDiagnostics.lastSolverGuardCause` | Zmiana tylko dodaje API, a gra przechowuje `WorldRejectionReason` w `BoardFailure.stepsRejected` bez zmian | `user` | G5-AC1, G5-AC2 | `.solverGuard` zostaje jedyną wartością odrzucenia przez strażnika |
| CD-D-3 | Granica kontraktu odrzucenia | Trzeba ustalić, kiedy odrzucenie jest jeszcze dozwolone | bańki nigdy nie odrzucają, zostają przeszkody sztywne; nigdy żadnego odrzucenia; kontrakt tylko dla planszy prostokątnej | bańki nigdy nie odrzucają kroku; niewłaściwe są tylko: ten sam środek co inna bańka, środek we wnętrzu bryły, środek poza planszą | Właściciel wskazał te trzy przypadki jako jedyne nierozwiązywalne | `user` | G1, G2, G3 | środek przepchnięty przez ścianę lub bryłę w trakcie symulacji dalej odrzuca krok (G5-AC1) |
| CD-D-4 | Zły punkt odrzuca transakcję | Odrzucony krok zostawia transakcję w kolejce, więc gra nie mogłaby podać nowego punktu | odrzucenie transakcji; odrzucenie kroku; odrzucenie kroku z usunięciem transakcji | `transactionRejected` z `invalidPlacement(ObjectID, PlacementIssue)`; świat idzie dalej | Spełnia intencję właściciela: wywołujący dowiaduje się o złym punkcie i podaje nowy; gra już obsługuje to zdarzenie (`BoardWorld.swift:447` w 2KBubbles) | `user` | G3-AC1–G3-AC3 | nowy przypadek w `TransactionRejectionReason` formalnie łamie wyczerpujący `switch`; gra ma tylko `if case`, więc wydanie zostaje minor z adnotacją w CHANGELOG (G6-AC1) |
| CD-D-5 | Rdzeń: miękki kontakt XPBD | Twardy PBD nie ma rozwiązania przy bilansie pól > 1 | XPBD z podatnością pary; twardy kontakt z limitem korekcji; zmiana promienia fizycznego | XPBD z α = (c_a + c_b) / dt², kontur dzielony według c_a : c_b | Jedna wielkość daje brak awarii, miękkość zależną od promienia i kontur zgodny z rozkładem zgniotu; solver ma już ścieżkę `alpha` | `user` | G1, G4 | α zależy od pary, a nie od świata; `NativeMetalConfiguration.contactCompliance` zostaje dla harnessu |
| CD-D-6 | Punkt scalenia poprawia silnik | Punkt wyniku scalenia wybiera silnik, nie gra | odrzucenie transakcji; deterministyczne szukanie innego punktu | `resolvedMergeCenter` ze skończoną listą kandydatów zakończoną spiralą wokół środka źródła | Właściciel: punkt wybrany przez silnik silnik ma poprawiać aż do skutku; determinizm zachowuje powtarzalność gry | `user` | G2-AC4, G3-AC4 | wynik może pojawić się poza punktem styku; zdarzenie `mergeContact` dalej podaje punkt styku |
| CD-D-7 | Próg „tego samego środka” | „Identyczny środek” wymaga progu liczbowego | równość bitowa; stała względna do promienia; tolerancja solvera | `coincidentCenterTolerance` = max(1e-4 · r_mniejszej, tolerancja solvera `solver.physics.y`), stała udokumentowana w kodzie | Równość bitowa przepuściłaby punkty różne o 1 ULP, których naprawa nie rozsunie stabilnie; próg względny działa przy każdej skali; środki oddalone o 0,01 przy r ≥ 20 są ponad progiem (G2-AC3) | `auto (dyskusja Q4–Q6)` | G3-AC1, G2-AC3 | gra stawiająca bańkę bliżej niż próg dostaje odrzucenie i losuje nowy punkt |
| CD-D-8 | Dwa wymiary podatności w materiale | Właściciel chce jednego opisu, który obejmuje kontakt twardy, stały, miękki i sztywniejący | tryby `.hard`/`.radiusLaw`; tylko podatność na bańce; tylko krzywa ściśnięcia; dwa wykładniki | c = c₀ · (r / r_ref)^s · ρ^k w materiale, c₀ nadpisywane na bańce; dolna granica konturu 0 | Właściciel: jeden wymiar to zmiana podatności podstawowej z promieniem nominalnym, drugi to znormalizowany opis sztywności od ściśnięcia; gra wybiera materiał | `user` | G4-AC1–G4-AC5 | c₀ = 0 to dzisiejszy twardy kontakt; `deformability ≤ 1` zostaje bez zmian, bo miękkość kontaktu niesie podatność |
| CD-D-9 | Ograniczona siła przy bańce w bańce | W2 wymaga rozsuwania bez skoków i teleportu | natychmiastowe rozdzielenie (dziś); limit przesunięcia na krok | `containmentCorrectionLimit` = 0,25 · r_mniejszej na krok, stała silnika | Przy 60 krokach/s pełne zawieranie znika w ułamku sekundy, a jeden krok nie przesuwa środka o więcej niż ćwierć promienia | `auto (W2 ze specyfikacji, Q13)` | G2-AC1, G2-AC2 | przez kilka klatek bańki mogą być widoczne jedna w drugiej |
| CD-D-10 | Jedna przyczyna i licznik zawierania | Po W2 przyczyna „bańka w bańce” nie ma drogi, by się pojawić | jedna przyczyna i licznik; obie przyczyny; bez nowego pola | `SolverGuardCause.centerCrossing` i `WorldDiagnostics.containedBubblePairCount` | Nie ma martwego przypadku w API, a gra i testy mają sygnał zawierania bez awarii | `user` | G5-AC1–G5-AC3 | przyszłe przyczyny dojdą jako nowe przypadki wyliczenia |
| CD-D-11 | Ściany i bryły zostają twarde | Kontakt bańka–bryła potrzebuje α | bryła z własną podatnością; tylko podatność bańki | α = c_bańki / dt² | Bez nowego parametru brył; środek dalej nie przechodzi przez ścianę dzięki strażnikowi | `auto (Non-goals, Q4)` | G1-AC2, G4-AC1 | miękkich ścian nie da się ustawić |
| CD-D-12 | Droga v2.1.0 dla podatności 0 | Domyślne materiały nie mogą zmienić konturów i pozycji | zawsze nowy kontur; nowy kontur tylko gdy c > 0 | para z c = 0 po obu stronach idzie dzisiejszą drogą konturu (cięciwa radykalna, nacisk z sufitem 0,5) | Gwarantuje G4-AC6 i zgodność z 2.1.0 przy domyślnych danych | `auto (specyfikacja W3: „przy wartości zerowej nie gorzej niż v2.1.0”)` | G4-AC6 | dwie drogi konturu w shaderze |
| CD-D-13 | Wersja 2.2.0 | Zmiana dodaje API, ale nowy przypadek wyliczenia i zmiana semantyki zawierania są widoczne | 2.2.0; 3.0.0 | 2.2.0 z adnotacjami w CHANGELOG | Właściciel prosił o 2.2.0, gra nie ma wyczerpujących `switch` po zmienianych wyliczeniach | `user` | G6-AC1 | klient z wyczerpującym `switch` po `TransactionRejectionReason` musi dodać gałąź |

## Key facts & assumptions

- **Najważniejsza reguła:** krok symulacji z bańkami w poprawnych punktach nigdy nie jest odrzucany z powodu baniek. Odrzucenie przez strażnika oznacza wyłącznie środek, który przeszedł przez ścianę albo bryłę.
- Ściany planszy 2KBubbles to bryły sztywne (`BoardWorld.swift:113-120` w 2KBubbles), więc „poza planszą” w grze to wnętrze bryły albo punkt poza `simulationRegion`.
- Założenie niepotwierdzone, ale nie blokujące: przy podatności dodatniej i 8 iteracjach Jacobiego tłok o bilansie 2,5 dochodzi do stanu bez odrzuceń w 10 s. Jeśli test G1-AC1 pokaże inaczej, plan może zmienić liczbę iteracji wewnętrznie, bez nowego API.
- Liczba ρ pochodzi z konturu poprzedniej klatki, więc odpowiedź na ściśnięcie ma opóźnienie jednego kroku.
