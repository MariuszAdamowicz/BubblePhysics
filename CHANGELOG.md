# Changelog

Zmiany w wydaniach `BubblePhysics`. Przejście z 1.x na 2.0.0 opisuje [docs/MIGRATION-v2.md](docs/MIGRATION-v2.md), a z 2.x na 3.0.0 [docs/MIGRATION-v3.md](docs/MIGRATION-v3.md).

## 3.0.1

### Naprawione

- Tłumienie ζ_c kontaktu miękkiego działa przy każdej prędkości normalnej (zbliżania i rozdzielania). Dotąd dashpot był pomijany, gdy prędkość normalna przekraczała max(40, 2r), więc szybkie zderzenie ze ścianą było nietłumione (tylko γ materiału): mała bańka dociśnięta gumką (r 24, c₀ 0,0108, F 1200, uderzenie ok. 173 j/s) przestrzeliwała do ε ≈ 1 zamiast osiąść w ε = c₀ · F / r_ref = 0,648. Dashpot działa na prędkość względną, więc przy szybkiej kinematycznej przeszkodzie bańka przejmuje jej ruch normalny, zamiast go hamować. Tłumione jest także szybkie rozprężanie: zawarta para miękka (P-B-30) przy ζ_c 1 rozchodzi się wolniej niż w 3.0.0. Kontakty twarde (c₀ = 0) zachowują próg jak w 3.0.0.
- Krawędź statycznego wielokąta odpycha środek bańki, który minął ją w kroku. Dotąd, gdy przewidziany środek był za prostą krawędzi, krawędź nie dawała kontaktu, a strażnik środka tylko cofał go na krawędź: bańka pchana w ścianę stała na stałe w ε ≈ 1. Teraz kontakt daje krawędź wejścia: środek na początku kroku był przed nią (albo na niej), a droga środka w kroku przecina sam odcinek krawędzi, nie tylko jej prostą. Odpycha wzdłuż normalnej zewnętrznej, z wgnieceniem większym niż r. Tylna krawędź cienkiej ściany nadal nie odpycha, bo środek nigdy nie był przed nią, a przy skośnym wejściu nad narożnikiem wypukłym odpycha tylko krawędź, której odcinek droga przecięła. Reguła obejmuje także kontakty twarde (c₀ = 0), więc ich trajektorie przy ścianach różnią się od 3.0.0.

## 3.0.0

Przejście z 2.x opisuje [docs/MIGRATION-v3.md](docs/MIGRATION-v3.md).

### Zmienione (łamiące)

- `BubbleContactCompliance` ma tylko `base` (c₀) i `referenceRadius` (r_ref). Podatność bańki to c = c₀ · r / r_ref, gdzie r to bieżący promień fizyczny, bez wykładników i bez ρ. Ta sama siła ściska więc każdą bańkę o ten sam ułamek promienia, ε = c₀ · F / r_ref, a para dzieli wgniecenie w proporcji promieni.
- Walidacja stagera liczy najgorszą α pary z największego promienia (bieżącego, docelowego, celu trwającego przejścia i `endRadius`) jako c₀ · r_max / r_ref, bez ρ_min^kc.
- Rekord cache kontaktu niesie sumę podatności końców (`compliance.x` = c_a + c_b) zamiast ρ końców. `nativeUpdateContactRho` znika z kroku, a kontur pary dzieli wgniecenie według podatności z `contact.x`.
- Jedno tłumienie ruchu liniowego. `MotionControllers.prepare` mnoży prędkość przez e^(−γ · dt) (γ to `damping` materiału obiektu) przed dodaniem F / m · dt, dla ról `.dynamic`, `.motorDriven` i `.playerDriven`. Kernele (`nativePredict`, `nativeRigidPredict`) nie tłumią już ruchu liniowego na ścieżce publicznej, tłumią tylko obrót. Siła działa więc w całości: bańka dociśnięta gumką w nasyceniu, `MotorDrive` albo siłą globalną ugina się o c · F, bez względu na γ i masę (wcześniej gumka traciła około 11,5 % siły przez e^(−D · dt / m), a każda siła jeszcze około 1 % przy γ 0,6). Prędkość narzucona torem (`.pathDriven`, bryła kinematyczna) nie jest tłumiona.
- Napęd tylko gumką siłową. `BubbleDrivePolicy(bandStiffness:maximumForce:)` ma dwa pola, bez `.standard`. `BubbleDescriptor.drivePolicy` i `BubbleResult.drivePolicy` są opcjonalne i domyślnie `nil`. Bańka bez `drivePolicy` i bryła nie dają się chwycić: `beginPlayerDrive` odrzuca je z `incompatibleObjectKind(id)`. Chwyt nie zmienia promienia ani kształtu bańki. `replace`, scalenie i podział chwyconej bańki kończą chwyt, ponowny chwyt tylko z polityką.
- Krawędzie statycznych wielokątów odpychają tylko od zewnątrz, a wypukły wierzchołek raz. Dotąd każda krawędź bryły statycznej była odcinkiem dwustronnym: cienka ściana (grubość mniejsza niż ugięcie, albo zwykła ściana przy dużej bańce) dawała bańce drugą sprężynę od tylnej krawędzi, a wierzchołek wypukły dwa kontakty z tym samym punktem. Teraz kontakt powstaje w obszarze wnętrza krawędzi po jej stronie zewnętrznej (stała normalna zewnętrzna) albo w obszarze wypukłego wierzchołka (normalna od wierzchołka, jeden kontakt, wierzchołek należy do krawędzi, która się w nim zaczyna); klasyfikacja na granicy obszarów jest dokładnym dopełnieniem, także o jedno ULP obok. Ugięcie przy ścianie to c · F niezależnie od jej grubości. Strona zewnętrzna wynika ze znaku pola wielokąta, więc obieg wierzchołków podany przez grę nie ma znaczenia. Krawędzie sąsiednie współliniowe w tolerancji 1e-5 (|e₁ × e₂| ≤ 1e-5 · |e₁| · |e₂|) są scalane i ich wspólny wierzchołek nie zmienia kontaktu. Dotyczy też kontaktów twardych (c₀ = 0). Segment solvera ma o jedno pole więcej (stride 112 → 128 B); CCD i strażniki środka działają jak dotąd, dwustronnie.
- Kontur tylko rysowany. Kernele konturu i renderu nie zapalają już bitów błędu za wartość konturu (skończoność punktów, długość krawędzi, skończoność i zakres promienia efektywnego, deformacji i obwiedni), a `nativeCheckFinite` sprawdza z rekordu deformacji tylko limity prędkości. Odczyt ramki nie odrzuca kroku za kontur, tylko naprawia opublikowane wartości: promień efektywny nieskończony albo spoza [0, `targetRadius`] staje się `targetRadius`, nieskończona albo odwrócona obwiednia staje się obwiednią koła bańki, a deformacja spoza [0, 1] nie wchodzi do statystyk. Pozycje, prędkości i promienie fizyczne nie zależą od konturu (dwa światy z `deformability` 0 i 0,65 dają identyczne wyniki bit w bit). Walidacja stanu fizycznego (skończoność, λ ≥ 0, spójność pakietu renderu) zostaje.

### Usunięte

- `BubbleDrivePolicy.bandDamping` (D): tłumienie gumki zastępuje γ materiału. `BubbleDrivePolicy.rigidifies`, `rigidificationDuration`, `relaxationDuration` i `distanceResponse`, `maximumSpeed`: narzucona prędkość i usztywnianie przy chwycie znikają razem z trybem prędkościowym. `BubbleDrivePolicy.standard`.
- `BubbleContactCompliance.radiusExponent` (s) i `BubbleContactCompliance.compressionExponent` (k). Przestrojenie podatności opisuje [docs/MIGRATION-v3.md](docs/MIGRATION-v3.md).

## 2.3.0

### Dodane

- Gumka siłowa w `BubbleDrivePolicy`: `bandStiffness: Float?` (K_band), `bandDamping: Float` (D, domyślnie 0) i `maximumForce: Float?`. Przy `bandStiffness` != `nil` chwycona bańka (`beginPlayerDrive`) dostaje siłę K · (cel − położenie), obciętą do `maximumForce` z zachowaniem kierunku, zamiast narzuconej prędkości; dochodzą do niej siła globalna i pola sił jak przy bańce `.dynamic`. Prędkość: `v ← (v + F / m · dt) · e^(−D · dt / m)`. Prędkość ustalona bez kontaktów to K · s / (m · γ + D), γ to `damping` materiału. Bez `bandStiffness` (domyślnie) napęd działa jak w 2.2.0; w trybie gumki `maximumSpeed` i `distanceResponse` są ignorowane.
- Walidacja gumki: `bandStiffness`, `bandDamping` i `maximumForce` rzucają `ModelValidationError.valueOutOfRange` z nazwą pola (`drive.bandStiffness`, `drive.bandDamping`, `drive.maximumForce`) dla wartości niedodatnich, ujemnej D i nieskończonych, a `bandDamping` ≠ 0 albo `maximumForce` bez `bandStiffness` też. Transakcja z bańką, której K_band · dt² / m ≥ 1 (wstawienie, zamiana, wynik scalenia, część podziału), jest odrzucana z `invalidValue(.valueOutOfRange("drive.bandStiffness"))`. W trybie gumki `beginPlayerDrive` i `updatePlayerDrive` odrzucają cel poza limitem jak siła `MotorDrive`.
- `PhysicsMaterial.contactDampingRatio` (ζ_c, ostatni parametr `init`, domyślnie 1): ułamek tłumienia krytycznego sprężyny kontaktu miękkiego, średnia w parze, przy ścianie wartość bańki. Ujemna, NaN albo nieskończona wartość rzuca `valueOutOfRange`; materiał `.rigid` przyjmuje tylko 1.

### Zmienione

- Kontakt miękki działa jak sprężyna: bańka ugina się o c · F (wcześniej o około 3,85 · c · F przy kroku 1/60), w spoczynku stoi (wcześniej raportowała prędkość w stronę kontaktu), a drgania tłumi ζ_c i masy zamiast stałego tłumienia. Do prędkości trafia pełna korekta kontaktów XPBD; bańki twarde i pozostałe korekty (przeguby, bryły, CCD, strażniki) bez zmian. **Gra musi przestroić `base` (c₀) mniej więcej 3,85 razy w górę, żeby zachować dotychczasowy wygląd.**
- ρ kontaktu liczy się z pozycji przewidzianych w bieżącym kroku, bez wygładzania i opóźnienia o klatkę, a kontur pokazuje tylko bieżące kontakty: wgniecenie znika w tej samej klatce co kontakt, bez relaksacji w czasie. Usunięte `deformationRecoveryRate` z solvera natywnego i jego adaptera (w `BubblePhysicsReference` zostaje). Pierwsza klatka wyniku scalenia lub podziału bierze kontur z seeda źródeł jak dotąd.
- Limit λ pary z 2.2.0 obowiązuje tylko pary twarde. Para miękka (także miękka–twarda) nie ma limitu, bo po zmianie sprężyny bańka w spoczynku stoi i limit stawiał sufit siły przenoszonej łańcuchem baniek (ok. 3 888 dla r = 12, m = 0,36).
- Komentarz `ObjectState.Kind.bubble(effectiveRadius:)`: to minimalna odległość konturu od środka, bez „odbudowy”.

### Uwagi

- Zawarta para miękka wystrzeliwuje mniejszą bańkę z prędkością do `maximumLinearSpeed`: energia ściśnięcia się uwalnia, a krok nie jest odrzucany. `maximumLinearSpeed` ogranicza prędkość po wystrzale, ale nie skok pozycji w kroku wyjścia z zawierania. Przy bardzo małej podatności skok może sięgnąć pełnego nakładania, a CCD nie chroni przed przejściem przez inną bańkę. Gwarancja 0,25 · min r na krok z 2.2.0 zostaje dla par twardych. Wystrzałów unika się, nie dopuszczając do głębokich zawierań.
- Z gumką używaj `rigidifies: false`: bańka z `rigidifies = true` ma przy chwycie wyzerowany kontur i dociśnięta do ściany wygląda jak koło nachodzące na ścianę.
- Szczegóły: [docs/integration-guide.md](docs/integration-guide.md), sekcja „Chwyt gumką”. Raport siatki twardnienia: `docs/benchmarks/v2.3.0-rho-grid-2026-11-19.md`.

## 2.2.0

### Dodane

- `TransactionRejectionReason.invalidPlacement(ObjectID, PlacementIssue)`: transakcja odrzucona z powodu złego punktu bańki. ID to bańka z błędnym punktem: dodawana albo zastępująca w `add` i `replace`, wynik scalenia albo część podziału w `mergeBubbles` i `splitBubble`.
- `PlacementIssue` nazywa przyczynę. Przy kilku naraz wygrywa pierwsza w kolejności:
  - `.outsideRegion`: środek poza `simulationRegion`,
  - `.insideRigidBody`: środek we wnętrzu wielokąta, koła albo kapsuły bryły sztywnej,
  - `.coincidentCenter`: środek bliżej środka innej bańki niż tolerancja wspólnego środka (1e-4 mniejszego z dwóch promieni, nie mniej niż tolerancja położenia solvera).
- `WorldDiagnostics.lastSolverGuardCause: SolverGuardCause?` podaje przyczynę ostatniego odrzucenia kroku przez strażnika (`lastRejectionReason == .solverGuard`): `.centerCrossing` (środek bańki przeszedł przez ścianę albo wszedł we wnętrze bryły, także łuk obrotu bryły pominięty przez próbkowanie) albo `.rigidRotationBudget` (obrót bryły sztywnej szybszy niż budżet 128 próbek). Jest `nil`, gdy nic nie odrzucono albo ostatnie odrzucenie miało inny powód.
- `WorldDiagnostics.containedBubblePairCount: Int` to liczba par „bańka w bańce” (mniejsza cała w kole większej) po ostatnim ukończonym kroku. Pusta plansza daje 0.
- `BubbleContactCompliance` opisuje podatność kontaktu bańki w czterech wartościach: `base` c₀ ≥ 0, `referenceRadius` r_ref > 0, `radiusExponent` s i `compressionExponent` k. Podatność bańki w kroku to c = c₀ · (r / r_ref)^s · ρ^k, gdzie r to bieżący promień fizyczny, a ρ ∈ [0, 1] to wygładzony stosunek promienia konturu do r w kierunku kontaktu. Przy tej samej sile względne wgniecenie rośnie jak r^(s−1), a dla k > 0 bańka sztywnieje wraz ze ściśnięciem. Wartość `.hard` (c₀ = 0, domyślna) daje kontakt twardy i kontur jak w v2.1.0.
- `PhysicsMaterial.contactCompliance: BubbleContactCompliance` (ostatni parametr `init`, domyślnie `.hard`). Ujemna, NaN albo nieskończona podatność, zły wykładnik, promień odniesienia ≤ 0 (także NaN i nieskończony) oraz podatność > 0 w materiale `.rigid` rzucają `ModelValidationError.valueOutOfRange`.
- Nadpisanie `contactCompliance: Float?` w `BubbleDescriptor` zastępuje c₀ jednej bańki. Ujemna, NaN albo nieskończona wartość rzuca `valueOutOfRange` przy tworzeniu deskryptora.
- `BubbleResult.contactCompliance: Float?` nadpisuje c₀ wyniku scalenia i każdej części podziału. Zła wartość odrzuca transakcję z `invalidValue(.valueOutOfRange("contactCompliance"))`, bo inicjalizator `BubbleResult` nie rzuca.

### Zmienione

- Kod z wyczerpującym `switch` po `TransactionRejectionReason` musi obsłużyć nowy przypadek `invalidPlacement`. Dodaj przypadek albo gałąź `default`.
- `add` i `replace` bańki w złym punkcie odrzucają całą transakcję z `invalidPlacement`. Wcześniej taka bańka trafiała do świata i dopiero solver radził sobie z jej punktem. Dotyczy to także dwóch baniek dodanych w tym samym punkcie w jednej transakcji. Przy `replace` bańka zastępowana jest z testu wyłączona.
- Region obowiązuje przy `regionExitPolicy = .wrap` tak samo jak przy pozostałych politykach: `.wrap` przenosi bańkę, która wyszła w kroku, ale nie pozwala postawić jej poza regionem, więc `add` poza regionem daje `.outsideRegion`.
- `mergeBubbles` i `splitBubble` same poprawiają punkt wyniku. Gdy punkt styku (scalenie) albo centroid części (podział) jest zły, silnik bierze pierwszego poprawnego kandydata z ustalonej listy, więc dwa przebiegi dają ten sam punkt. Transakcję odrzuca dopiero wyczerpanie listy, z `invalidPlacement` dla ID wyniku albo części. Źródła scalenia są z testu punktu wyłączone, bo znikają razem ze scaleniem.
- Przy podziale z przesuniętą częścią prędkość liniowa i kątowa części są liczone względem jej końcowego środka, więc pęd i moment pędu źródła zostają zachowane.
- Bańka w bańce, prawie wspólny środek pary i zawieranie po scaleniu w zajętym miejscu nie odrzucają już kroku. Naprawy zawierania, która w v2.1.0 rozdzielała parę w jednym kroku, już nie ma: parę zawartą rozsuwa solver kontaktów w kilku kolejnych krokach, a para zawarta liczy się w `containedBubblePairCount`. Dlatego w pierwszej klatce po dodaniu bańki wewnątrz innej pary nie widać już rozdzielenia.
- Korekcja od pary baniek ma limit λ pary, wspólny dla warm startu i iteracji Jacobiego: λ ≤ ((max(0, v_a·n) + max(0, −v_b·n))·dt + 0,25·min(r_a, r_b)) / max(invMass_a, invMass_b), czyli 0,25 · min r ponad ruch baniek w stronę kontaktu. W v2.1.0 limit r / (invMass · liczba kontaktów) miał tylko warm start, więc nowy limit bywa ostrzejszy albo łagodniejszy, zależnie od liczby kontaktów, prędkości i promieni pary, a Jacobi ma limit pierwszy raz. Obie bańki pary dostają tę samą λ, więc pęd pary jest zachowany. Kontakty ze ścianami i bryłami oraz rzutowanie na przeszkody są poza limitem pary (warm start kontaktu ze ścianą zachowuje limit z v2.1.0). Stos baniek pod grawitacją się trzyma, bo limit przepuszcza prędkość, którą bańka w spoczynku gromadzi w stronę kontaktu.
- Strażnik środka rzutuje środek, który leży we wnętrzu ściany albo bryły, na krawędź przekroczoną w ruchu względnym (z położeniem krawędzi `previous` → `current`), a bez takiej krawędzi na najbliższą, jak dotąd. Gdy punkt po rzucie leży we wnętrzu sąsiedniej bryły (np. przy narożniku dwóch stykających się ścian), następują najwyżej 4 kolejne rzuty, każdy na krawędź z wolnym miejscem, czyli w regionie, poza bryłami i bez wejścia odcinka od startu kroku w jakąkolwiek bryłę. Dwie stykające się ściany dają narożnik wewnętrzny z marginesem zamiast odrzucenia kroku. Gdy żadna krawędź nie wyprowadza środka do wolnego miejsca, krok jest odrzucany z `.centerCrossing`.
- Odrzucenie podatności, która przepełnia Float: `add`, `replace`, `mergeBubbles`, `splitBubble`, `startTransition` promienia bańki i `updatePhysicsMaterial` sprawdzają, czy największa możliwa α pary z bańką (α_cfg + 2 · c_worst / dt², z nadpisaniem c₀) jest skończonym Float. Gdy nie jest, transakcja jest odrzucona z `invalidValue(.valueOutOfRange("contactCompliance"))`, a promień albo materiał zostają bez zmian. Dzięki temu GPU nie dostaje podatności, która kończyłaby się `worldFailed`.
- Kontakt miękki działa na GPU: α pary bańka–bańka to α_cfg + (c_a + c_b) / dt², a bańki ze ścianą albo bryłą statyczną α_cfg + c_a / dt². Kontakt z bryłą niestatyczną zostaje twardy. Kontur pary miękkiej dzieli wgniecenie w proporcji c_a : c_b, a bańka o c = 0 w takiej parze nie dostaje wgniecenia. Bańka z c > 0 omija bramkę deformowalności materiału, więc materiał z domyślnym `deformability` = 0 też ma kontur. Para twarda ma kontur jak w v2.1.0. Rekord bańki rośnie o jeden lane (176 → 192 B), a rekord cache kontaktu o jeden (64 → 80 B): to ABI wewnętrzne, niewidoczne dla gry.

## 2.1.0

### Dodane

- `BubbleResult` ma dwa nowe pola, oba z wartościami domyślnymi, więc istniejące wywołania `BubbleResult(...)` kompilują się bez zmian. W `init` są ostatnimi parametrami, po `decal:`.
  - `drivePolicy: BubbleDrivePolicy = .standard`: polityka jazdy wyniku scalenia i każdej części podziału. Wcześniej wynik zawsze dostawał `.standard` (sztywnienie i `maximumSpeed` 12).
  - `mass: Float? = nil`: masa wyniku scalenia. `nil` oznacza sumę mas źródeł, jak dotąd. Prędkość liniowa i kątowa wyniku zawsze pochodzą z mas źródeł (pęd i moment pędu źródeł podzielone przez ich sumę mas i wynikającą z niej bezwładność), także przy nadpisanej masie, więc pęd nie jest wtedy zachowany. Niedodatnia albo nieskończona masa odrzuca transakcję z `invalidValue(.nonPositiveValue("bubble.mass"))` albo `invalidValue(.nonFiniteValue("bubble.mass"))`.

### Zmienione

- `splitBubble`, w którym `BubbleResult` którejkolwiek części ma `mass` różne od `nil`, jest odrzucany z `TransactionRejectionReason.invalidStructuralOperation`. Masa części podziału to nadal masa źródła razy udział.

## 2.0.1

Poprawki po review PR #3, bez zmian publicznego API modelu.

### Poprawione

- Krok bez GPU czyści historię kontaktów, więc para ciał dodana ponownie z tymi samymi ID znów dostaje `contactBegan` i `contactEnded`.
- Transakcja odrzuca skończone, ale ogromne (powyżej 1e6) wartości więzów, siły i momentu napędu silnikowego, zakresu zawiasu i docelowej prędkości silnika zawiasu. Wcześniej przepełniały `Float` w kroku i przełączały świat w `failed(.nonFiniteValues)`.

### Zmienione

- `PublicWorldStressBenchmark` (sceny, tryb pojemności, bramki i raporty) przeniesiono z `BubblePhysicsMetalRender` do osobnego produktu i modułu `BubblePhysicsMetalRenderBenchmark`. Kod, który go używa, linkuje nowy produkt i dopisuje `import BubblePhysicsMetalRenderBenchmark`.
- Hit-test pomija bańki, których obwiednia konturu nie zawiera punktu, zanim sprawdzi punkty konturu.
