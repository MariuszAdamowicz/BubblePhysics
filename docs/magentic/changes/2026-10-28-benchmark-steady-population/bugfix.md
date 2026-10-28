# Bugfix: stała populacja benchmarku rundy

**Data:** 2026-10-28

**Status:** Approved

**Artefakt:** `bugfix`

**Wersja pluginu:** 0.1.29

**Sesje agenta:** unknown: UNKNOWN

---

## Analiza przyczyny źródłowej

- **Objaw:** Fizyczny iPhone X zakończył benchmark z powodu przekroczenia pamięci przed ukończeniem 1680 klatek.
- **Reprodukcja:** Release uruchomiony na iPhonie X po rozpoczęciu benchmarku otrzymał systemowe zakończenie procesu z powodu pamięci.
- **Przyczyna:** `PublicWorldStressBenchmark.swift:133` składa spawn w każdej mierzonej klatce bez usuwania rezultatu, a linie 143-162 pozostawiają poprzednie wyniki merge. Populacja rośnie do około 300 dodatkowych obiektów na scenariusz, wymuszając przebudowy zasobów sceny.
- **Dowody:** Stager dodaje rezultat spawnu i odrzuca dopiero po braku miejsca; merge usuwa źródła, lecz dodaje nowy rezultat. Przy 300 iteracjach merge liczba obiektów rośnie do około 301. Kolejka transakcji i drawable nie kumulują się po poprawce lifecycle.
- **Wykluczono:** Command buffer kończył się poprawnie; brak dowodu na retencję drawable lub niezakończonych transakcji.
- **Otwarte warunki:** Trzeba zmierzyć na iPhonie X, że populacja pozostaje ograniczona, benchmark kończy 1680 klatek i raport jest kompletny.
- **Zweryfikowano:** Analiza faktycznych ścieżek spawn/merge, stagera i lifecycle drawable; bez trwałej instrumentacji.

## Projekt poprawki

### Co ma być prawdą po poprawce

- [ ] B1: Test dowodzi, że każdy scenariusz powtarza wymagane wejście semantyczne w 300 mierzonej klatce i nie zwiększa liczby żywych baniek ponad ustalony baseline scenariusza. · `verify: swift test --filter MetalRenderIntegrationTests.testEngineOwnedRoundBenchmarkKeepsSteadyPopulation`
- [ ] B2: Release na iPhonie X kończy 1680 klatek bez zakończenia pamięci, z raportem p95/maksimum i licznikami bezpieczeństwa. · `verify: manual-device — Release iPhone X, raport po 1680 klatkach`

### Podejście i granice

- **Miejsce poprawki:** `Sources/BubblePhysicsMetalRender/PublicWorldStressBenchmark.swift:105-162`.
- **Minimalne podejście:** Po zmierzeniu pojedynczego semantycznego spawnu lub merge usunąć jego wynik w kolejnej bezpiecznej transakcji; utrzymać baseline gęstej areny i zachować 300 wejść semantycznych na scenariusz.
- **Poza zakresem:** Zmiana silnika, areny, renderera, API, telemetryki, protokołu 120+300 lub produktu.

### Zadania implementacji

1. Dodać czerwony test stałej populacji oraz liczby wejść semantycznych. · `verify: swift test --filter MetalRenderIntegrationTests.testEngineOwnedRoundBenchmarkKeepsSteadyPopulation`
2. Wprowadzić minimalne cleanup transakcje benchmarku i potwierdzić zielony test oraz Release build przez Xcode 26.6. · `verify: DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -configuration Release -destination 'id=e7cdbee72f005b19f554e4c3675383f3dbea4c0c' build`

### Decyzje

| ID | Decyzja | Opcje | Wybór i dowód |
| --- | --- | --- | --- |
| BF-1 | Populacja próby | narastająca; stała | Stała: mierzy koszt operacji bez zmiany gęstości sceny i eliminuje potwierdzony wzrost obiektów. |

## Odchylenia implementacji

| # | Zadanie | Typ | Opis | Status |
| --- | --- | --- | --- | --- |

## Dowody implementacji

| Element | Dowód |
| --- | --- |
| Przyczyna | `PublicWorldStressBenchmark.swift:133,143-162`; `TransactionStager.swift:293,437,455-461`. |
