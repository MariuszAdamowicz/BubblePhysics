# Changelog

Zmiany w wydaniach `BubblePhysics`. Przejście z 1.x na 2.0.0 opisuje [docs/MIGRATION-v2.md](docs/MIGRATION-v2.md).

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
