# Changelog

Zmiany w wydaniach `BubblePhysics`. Przejście z 1.x na 2.0.0 opisuje [docs/MIGRATION-v2.md](docs/MIGRATION-v2.md).

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
