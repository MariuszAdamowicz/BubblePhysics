# Light Design: Polityka jazdy i masa wyniku w BubbleResult (v2.1.0)

**Date:** 2026-11-12
**Artifact:** light-design
**Status:** Approved
**Template version:** default/0.3.27

**Plugin version:** 0.7.10
**Agent Sessions:** claude-code: 006bd53f-f4b3-4f93-a021-a56985cb609f

## Why & what

Dziś bańka powstała ze scalenia zawsze dostaje `BubbleDrivePolicy.standard`, czyli sztywnienie i `maximumSpeed` 12. Wynika to z tego, że `resultDescriptor` (`Sources/BubblePhysicsRuntime/TransactionStager.swift:563`) nie przekazuje polityki do `BubbleDescriptor`. Masa wyniku jest zawsze sumą mas źródeł. Gra potrzebuje, żeby wynik łączenia miał własną politykę jazdy i opcjonalnie nadpisaną masę. Dlatego `BubbleResult` (`Sources/BubblePhysicsPublic/Model/WorldTransaction.swift:20`) dostaje dwa pola z wartościami domyślnymi: `drivePolicy: BubbleDrivePolicy = .standard` i `mass: Float? = nil`. Dzięki domyślnym wartościom istniejący kod kompiluje się bez zmian. Wydanie to v2.1.0, a gra przypina je jako exact.

- [ ] Wynik scalenia ma `drivePolicy` podaną w `BubbleResult`, a bez niej `.standard`; podział przekazuje politykę tak samo · `verify: swift test --filter TransactionStagerTests` przechodzi z nowymi testami
- [ ] `mass` nadpisuje masę wyniku scalenia, a `nil` daje sumę mas źródeł · `verify: swift test --filter TransactionStagerTests`
- [ ] Prędkość wyniku scalenia to pęd źródeł podzielony przez sumę mas źródeł, niezależnie od `mass` · `verify: swift test --filter TransactionStagerTests`
- [ ] Podział, w którym któraś część ma `mass != nil`, jest odrzucany z `invalidStructuralOperation` · `verify: swift test --filter TransactionStagerTests`
- [ ] Na GPU wynik scalenia prowadzony przez `beginPlayerDrive` jedzie z `maximumSpeed` z nowej polityki, a nie z 12 · `verify: swift test --filter BubblePhysicsPublicTests.MotionCommandTests` (lokalny GPU)
- [ ] `CHANGELOG.md` opisuje 2.1.0 i 2.0.1, `integration-guide.md` pokazuje nowe pola, README podaje wersję 2.1.0 · `verify: swift test` cały zielony (w tym `MigrationGuideTests`, `IntegrationGuideTests`)
- [ ] PR do `main` otwarty, a po merge'u tag `v2.1.0` na commicie merge'a jest na origin · `verify: git ls-remote --tags origin v2.1.0` zwraca hash commita merge'a

## How - Program design

**Model.** W `BubbleResult` (`WorldTransaction.swift:20-37`) dopisujemy `public let drivePolicy: BubbleDrivePolicy` i `public let mass: Float?` wewnątrz samej struktury. W `init` stają się nowymi ostatnimi parametrami, po `decal:`, tak jak wcześniej weszły `filter`, `layer` i `decal`: `drivePolicy: BubbleDrivePolicy = .standard, mass: Float? = nil`. `BubbleDrivePolicy` (`Sources/BubblePhysicsPublic/Model/Motion.swift:10`) jest `Equatable` i `Sendable`, więc `BubbleResult` zachowuje oba protokoły. Komentarz nad strukturą (`WorldTransaction.swift:19`) zmieniamy tak, żeby masę wyznaczał silnik, chyba że `mass` ją nadpisuje. Doc comment pola `mass` mówi trzy rzeczy: `nil` oznacza sumę mas źródeł, prędkość wyniku zawsze wynosi pęd źródeł podzielony przez ich sumę mas, a pole działa tylko w `mergeBubbles`, bo w `splitBubble` wartość różna od `nil` odrzuca transakcję. `BubbleResult.init` nie rzuca. Niedodatnią lub nieskończoną masę odrzuca walidacja `requirePositive(mass, "bubble.mass")` w `BubbleDescriptor.init` (`Sources/BubblePhysicsPublic/Model/Objects.swift:149`), wywoływana z `resultDescriptor`.

**Runtime.** W `TransactionStager.swift`:
- `resultDescriptor` (`:563-569`) przekazuje do `BubbleDescriptor` dodatkowo `drivePolicy: result.drivePolicy`. Parametr `drivePolicy:` istnieje już w `Objects.swift:137`.
- `merge` (`:571-595`) liczy prędkość tak jak dziś: `momentum / mass`, gdzie `mass` to suma mas źródeł w `Double`. Do `resultDescriptor` podaje `mass: result.mass ?? Float(mass)`.
- `split` (`:597-`) przed `remove(source)` sprawdza `first.result.mass == nil && second.result.mass == nil`, a w przeciwnym razie rzuca `TransactionRejectionReason.invalidStructuralOperation`. Masa części zostaje masą źródła × udział. Polityka jazdy części przechodzi przez `resultDescriptor` sama.

Do sprawdzenia przy implementacji: czy `StructuralOperations.initializeMerge` (wywoływany w `merge` po `add`) nie nadpisuje masy z deskryptora. Test z nadpisaną masą to wykryje.

**Dokumentacja i wersja.**
- Nowy `CHANGELOG.md` w katalogu głównym. Wpis 2.1.0 opisuje nowe pola `BubbleResult` i odrzucanie `mass` w podziale. Krótki wpis 2.0.1 to poprawki po review z PR #3.
- `docs/integration-guide.md:180-197` (przykład `merge(...)` z `BubbleResult`) dostaje akapit o `drivePolicy:` i `mass:`.
- `README.md:5` podaje wersję 2.1.0 i linkuje `CHANGELOG.md`. Odsyłacz do `docs/MIGRATION-v2.md` jako przejścia z 1.x na 2.0.0 zostaje, więc README nadal wspomina 2.0.0.
- Asercję w `Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift:106` zmieniamy tak, żeby wymagała „2.1.0” i odsyłacza `(CHANGELOG.md)`, a dalej pilnowała wzmianki o 2.0.0 jako wersji migracji. Komentarz testu (`:4-5`) idzie razem z nią.
- `docs/migration/v1-api-diff.txt` porównuje v1.0.0 z HEAD, więc nowe parametry `BubbleResult.init` mogą zmienić jego treść. Diff generujemy ponownie poleceniami z nagłówka pliku (`:7-14`). Jeśli się zmieni, wiersz `BubbleDescriptor.init`, `BubbleResult.init` w `docs/MIGRATION-v2.md:18` dopisuje, że `BubbleResult.init` ma też `drivePolicy:` i `mass:` na końcu.

**Wydanie.** Agent otwiera PR do `main` i na tym kończy pracę. Merge robi właściciel. Tag `v2.1.0` na commicie merge'a i `git push origin v2.1.0` agent wykonuje dopiero po wyraźnym potwierdzeniu merge'a przez właściciela. Push idzie przez `credential.helper` z `gh`, bo zwykły push z keychaina dostaje 403.

## Plan

1. Testy w `Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`, wzorzec z `Tests/BubblePhysicsRuntimeTests/CollisionFilterTests.swift:51`. Najpierw nie przechodzą. Sprawdzają: (a) scalenie z `BubbleResult(drivePolicy: BubbleDrivePolicy(maximumSpeed: 3))` daje deskryptor z tą polityką, a bez niej `.standard`; (b) podział przenosi `drivePolicy` każdej części; (c) `mass: 10` daje masę wyniku 10, a `nil` sumę mas źródeł; (d) przy źródłach o masach 1 i 3 i prędkościach `[4,0]` i `[0,0]` oraz `mass: 10` prędkość wyniku to `[1,0]`; (e) podział z `mass` w którejkolwiek części rzuca odrzucenie z `invalidStructuralOperation` · `verify: swift test --filter TransactionStagerTests` się nie kompiluje albo pada na nowych testach
2. Pola `drivePolicy` i `mass` z doc comments w `BubbleResult` i `init` (`Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`); przekazanie polityki w `resultDescriptor`, `result.mass ?? Float(mass)` w `merge` i kontrola `mass == nil` w `split` (`Sources/BubblePhysicsRuntime/TransactionStager.swift`) · `verify: swift test --filter 'TransactionStagerTests|CollisionFilterTests|DecalStagingTests|RenderMaterialModelTests'` przechodzi
3. Test GPU w `Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`, wzorzec `testPlayerDriveUsesDistanceResponsiveSpeedUpToConfiguredMaximum` (`:40`). Dwie bańki o równej masie w `[-1,0]` i `[1,0]` są scalane w wynik z `BubbleDrivePolicy(maximumSpeed: 3)`, a potem `beginPlayerDrive` z daleko leżącym celem. Jeśli wynik nie jest dostępny w tej samej transakcji, jazda idzie w kolejnej transakcji po `advance`. Przesunięcie `achievedPoint.x` względem środka scalenia po kroku `1/60` wynosi ≈ 0.05 (3/60), a nie 0.2 (12/60) · `verify: swift test --filter BubblePhysicsPublicTests.MotionCommandTests` przechodzi na lokalnym GPU
4. Ponowne wygenerowanie `docs/migration/v1-api-diff.txt` poleceniami z jego nagłówka; przy zmianie aktualizacja wiersza `BubbleResult.init` w `docs/MIGRATION-v2.md:18` · `verify: swift test --filter MigrationGuideTests` przechodzi
5. Zmiana asercji i komentarza w `Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift:104-108`: wymaga „2.1.0” i `(CHANGELOG.md)` oraz dalej „2.0.0” i obu przewodników. Test najpierw nie przechodzi · `verify: swift test --filter MigrationGuideTests` pada na README
6. Nowy `CHANGELOG.md` (2.1.0 i 2.0.1), `README.md:5` z wersją 2.1.0 i linkiem do changeloga, akapit o `drivePolicy:` i `mass:` w `docs/integration-guide.md` przy przykładzie `merge(...)` · `verify: swift test` cały przechodzi
7. Push brancha `feature/bubble-result-drive-policy-mass` i PR do `main` przez `gh pr create`, na tym koniec pracy agenta przed merge'em · `verify: gh pr view --json state` zwraca `OPEN`
8. Dopiero po wyraźnym potwierdzeniu merge'a przez właściciela: `git switch main && git pull`, `git tag v2.1.0 <merge-commit>`, `git push origin v2.1.0` przez helper `gh` · `verify: git ls-remote --tags origin v2.1.0` zwraca hash commita merge'a

## Decisions

| ID | Title | Context | Options | Choice | Rationale | Source | Consequences |
|----|-------|---------|---------|--------|-----------|--------|--------------|
| LD-D-1 | Prędkość wyniku przy nadpisanej masie | `merge` liczy prędkość jako pęd podzielony przez sumę mas (`TransactionStager.swift:587`), a `mass` może tę masę zmienić | dzielić pęd przez sumę mas źródeł; dzielić przez nadpisaną masę | pęd / suma mas źródeł | wynik porusza się ze średnią prędkością źródeł ważoną ich masami, a nadpisana masa wpływa tylko na dalszą fizykę; tak zaproponował właściciel w zleceniu | user | pęd nie jest zachowany przy `mass` różnym od sumy; opisane w doc comment pola |
| LD-D-2 | `mass` w podziale | każda część podziału ma własny `BubbleResult`, więc pole `mass` da się ustawić także tam (`TransactionStager.swift:597`) | ignorować po cichu; odrzucić transakcję; respektować bez zachowania masy | odrzucić z `invalidStructuralOperation` | podana i bez słowa pominięta wartość to trudny do namierzenia błąd; odrzucenie zostawia drogę do respektowania pola w przyszłości bez łamania zachowania | user | nowy przypadek odrzucenia podziału; masa części zostaje masą źródła × udział |
| LD-D-3 | Miejsce opisu wydania | repo nie ma changeloga, a `MIGRATION-v2.md` opisuje tylko 1.x → 2.0.0 i jest związany testem z diffem v1 | sekcja w `MIGRATION-v2.md`; nowy `CHANGELOG.md` z wersją w README; tylko `integration-guide.md` | nowy `CHANGELOG.md` (2.1.0 i 2.0.1), README 2.1.0, dostosowany `MigrationGuideTests.swift:106` | przewodnik migracji to jednorazowe przejście; changelog to jedno miejsce na kolejne wydania dla gry przypiętej do dokładnej wersji | user | README przestaje mówić tylko o 2.0.0; test README pilnuje 2.1.0 i linku do changeloga |
| LD-D-4 | Kto scala i taguje | tag v2.1.0 jest praktycznie nieodwracalny, bo gra przypina exact 2.1.0 | agent scala i taguje; agent otwiera PR, właściciel scala, agent taguje po potwierdzeniu; całość ręcznie | agent otwiera PR, właściciel scala, agent taguje i pushuje po wyraźnym potwierdzeniu | przed nieodwracalnym tagiem pada ludzkie „tak” po przejrzeniu PR | user | zadanie 8 czeka na potwierdzenie; poprawki po tagu wymagają v2.1.1 |
| LD-D-5 | Walidacja `mass` | `mass: Float?` może być 0, ujemne albo NaN, a `BubbleResult.init` nie rzuca | walidacja w `BubbleResult.init` (zmiana na `throws`); walidacja w `BubbleDescriptor.init` przez `resultDescriptor` | walidacja `BubbleDescriptor.init` (`Objects.swift:149`) | nie łamie istniejących wywołań `BubbleResult(...)`; zła masa odrzuca transakcję w stagerze jak każda zła wartość deskryptora | auto (recon: `Objects.swift:149`, `WorldTransaction.swift:31`) | błąd pojawia się przy `submit`, a nie przy budowie `BubbleResult` |
| LD-D-6 | Wartość `maximumSpeed` w teście GPU | domyślna polityka ma `maximumSpeed` 12 (`Motion.swift:20-21`), więc test z 12 niczego nie dowodzi | 12; inna wartość | 3, bez `distanceResponse` | przesunięcie 0.05 zamiast 0.2 w jednym kroku `1/60` jednoznacznie odróżnia nową politykę od `.standard` | auto (recon: `MotionControllers.swift:127-131`, `MotionCommandTests.swift:40`) | test wymaga lokalnego GPU |
| LD-D-7 | „Kontrola z zadania 9” | zlecenie mówi o kontroli robiącej `sed` od `struct BubbleResult` do `}`, której w repo nie ma | dodać taki skrypt; tylko umieścić pola w samej strukturze | pola w samej `struct BubbleResult`, bez nowego skryptu | kontrola leży poza tym repo (plan gry); `plan.md:737` z engine-foundations dotyczy AABB konturu, a nie `BubbleResult` | auto (recon: brak skryptu w docs, Sources, Tests) | zewnętrzna kontrola znajdzie `drivePolicy` i `mass` w treści struktury |

## Implementation deviations

> *Guidance:* Left empty by light-design; light-implement adds one row per deviation, or "None."

| #   | Task | Type (change/gap) | Description | Date |
| --- | ---- | ----------------- | ----------- | ---- |
|     |      |                   |             |      |
