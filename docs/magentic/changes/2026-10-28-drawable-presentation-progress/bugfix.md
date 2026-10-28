# Bugfix: postęp benchmarku po prezentacji drawable

**Data:** 2026-10-28

**Status:** Approved

**Artefakt:** `bugfix`

**Wersja pluginu:** 0.1.29

**Sesje agenta:** unknown: UNKNOWN

---

## Analiza przyczyny źródłowej

- **Objaw:** Po naciśnięciu `Start` na fizycznym iPhonie X benchmark pozostaje na `0 / 1680`.
- **Reprodukcja:** Release `BubblePhysicsBench` został uruchomiony na `iPhone (Mariusz)` przez `/Applications/Xcode-26.6.app`; po naciśnięciu `Start` i pięciu sekundach UI nadal pokazywał `0 / 1680`.
- **Przyczyna:** `Sources/BubblePhysicsMetalRender/PublicWorldStressBenchmark.swift:185` bezterminowo oczekuje na `DrawablePresentationLatch.wait()`. Potwierdzony ślad z urządzenia pokazuje kolejno `world_advance_enter`, `command_completed status=4`, `presentation_wait_enter`, bez `drawable_presented`; dlatego callback `progress` przy linii 206 nigdy nie jest wywołany.
- **Dowody:** Tymczasowa instrumentacja na iPhonie X potwierdziła ukończenie command buffera przed blokadą oraz brak callbacku `CAMetalDrawable.addPresentedHandler`. Testy automatyczne wywołują `run` bez `drawableProvider`, więc nie wykonują gałęzi `present(drawable)` ani `presentation.wait()`.
- **Wykluczono:** Solver i command buffer nie są pierwszą blokującą granicą: status command buffera to `.completed`. Usterka nie jest także układem SwiftUI; występuje po widocznym i użytym przycisku `Start`.
- **Otwarte warunki:** Należy potwierdzić, że nowy mechanizm prezentacji dostarcza callback dla każdej klatki na tym iPhonie X, nie używa timeoutu jako pozytywnego wyniku i zachowuje prawdziwy pomiar input→presentation.
- **Zweryfikowano:** Fizyczny iPhone X, Release, Xcode 26.6; diagnostyka została po odczycie usunięta, bez commitu.

## Projekt poprawki

### Co ma być prawdą po poprawce

- [ ] B1: Test integracyjny z kontrolowanym drawable dowodzi, że postęp nie następuje przed sygnałem prezentacji, a po sygnale kończy dokładnie jedną klatkę bez oczekiwania bez końca. · `verify: swift test --filter MetalRenderIntegrationTests.testDrawablePresentationSignalsProgressForEachFrame`
- [ ] B2: Release na iPhonie X osiąga postęp większy od zera po `Start`, kończy 1680 klatek i raportuje p95/maksimum input→presentation bez timeoutu przedstawianego jako sukces. · `verify: manual-device — Release iPhone X, screenshot postępu i pełny raport po 1680 klatkach`

### Podejście i granice

- **Miejsce poprawki:** `Sources/BubblePhysicsMetalRender/PublicWorldStressBenchmark.swift:167-185` oraz `Benchmarks/iOS/BubblePhysicsBench/App/PublicWorldStressView.swift`.
- **Minimalne podejście:** Przenieść pozyskanie i prezentację drawable do cyklu rysowania `MTKView`, który zapewnia rzeczywisty lifecycle prezentacji, a benchmarkowi przekazywać potwierdzenie prezentacji tej samej klatki. Nie wprowadzać timeoutu jako zastępstwa prezentacji.
- **Poza zakresem:** Fizyka, arena, spawn, renderer baniek, 2KBubbles, budżet wydajności oraz zmiana protokołu 120+300.

### Zadania implementacji

1. Dodać i obserwować czerwony test kontrolowanego sygnału prezentacji dla jednej klatki; test musi wykazać brak postępu przed sygnałem i jego wznowienie po sygnale. · `verify: swift test --filter MetalRenderIntegrationTests.testDrawablePresentationSignalsProgressForEachFrame`
2. Zaimplementować minimalną integrację cyklu `MTKView` z benchmarkiem, po której test jest zielony, postęp nie blokuje się, a report nadal mierzy prawdziwą prezentację. · `verify: DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -configuration Release -destination 'id=e7cdbee72f005b19f554e4c3675383f3dbea4c0c' build`

### Decyzje

| ID | Decyzja | Opcje | Wybór i dowód |
| --- | --- | --- | --- |
| BF-1 | Zdarzenie prezentacji | timeout; dotychczasowy bezpośredni `currentDrawable`; cykl `MTKView` | Cykl `MTKView`: ślad dowodzi, że dotychczasowy handler nie sygnalizuje, a timeout nie byłby dowodem G4-AC3. |

## Odchylenia implementacji

| # | Zadanie | Typ | Opis | Status |
| --- | --- | --- | --- | --- |

## Dowody implementacji

| Element | Dowód |
| --- | --- |
| Przyczyna | iPhone X: `command_completed status=4`, następnie `presentation_wait_enter`, bez `drawable_presented`. |
