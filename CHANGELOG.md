# Changelog

Zmiany w wydaniach `BubblePhysics`. Przejście z 1.x na 2.0.0 opisuje [docs/MIGRATION-v2.md](docs/MIGRATION-v2.md).

## 2.2.0 (w przygotowaniu)

### Dodane

- `TransactionRejectionReason.invalidPlacement(ObjectID, PlacementIssue)`: transakcja odrzucona z powodu złego punktu bańki. ID to bańka z błędnym punktem: dodawana albo zastępująca w `add` i `replace`, wynik scalenia albo część podziału w `mergeBubbles` i `splitBubble`.
- `PlacementIssue` nazywa przyczynę. Przy kilku naraz wygrywa pierwsza w kolejności:
  - `.outsideRegion`: środek poza `simulationRegion`,
  - `.insideRigidBody`: środek we wnętrzu wielokąta, koła albo kapsuły bryły sztywnej,
  - `.coincidentCenter`: środek bliżej środka innej bańki niż tolerancja wspólnego środka (1e-4 mniejszego z dwóch promieni, nie mniej niż tolerancja położenia solvera).

### Zmienione

- Kod z wyczerpującym `switch` po `TransactionRejectionReason` musi obsłużyć nowy przypadek `invalidPlacement`. Dodaj przypadek albo gałąź `default`.
- `add` i `replace` bańki w złym punkcie odrzucają całą transakcję z `invalidPlacement`. Wcześniej taka bańka trafiała do świata i dopiero solver radził sobie z jej punktem. Dotyczy to także dwóch baniek dodanych w tym samym punkcie w jednej transakcji. Przy `replace` bańka zastępowana jest z testu wyłączona.
- Region obowiązuje przy `regionExitPolicy = .wrap` tak samo jak przy pozostałych politykach: `.wrap` przenosi bańkę, która wyszła w kroku, ale nie pozwala postawić jej poza regionem, więc `add` poza regionem daje `.outsideRegion`.
- `mergeBubbles` i `splitBubble` same poprawiają punkt wyniku. Gdy punkt styku (scalenie) albo centroid części (podział) jest zły, silnik bierze pierwszego poprawnego kandydata z ustalonej listy, więc dwa przebiegi dają ten sam punkt. Transakcję odrzuca dopiero wyczerpanie listy, z `invalidPlacement` dla ID wyniku albo części. Źródła scalenia są z testu punktu wyłączone, bo znikają razem ze scaleniem.
- Przy podziale z przesuniętą częścią prędkość liniowa i kątowa części są liczone względem jej końcowego środka, więc pęd i moment pędu źródła zostają zachowane.

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
