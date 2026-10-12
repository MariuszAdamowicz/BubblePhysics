# Referencyjny GPU — pomijanie nieaktywnych etapów

Pomiar kodu `fd92989`, Mac mini Mac14,12, Apple M2 Pro, macOS 26.6.2. Scena `interactive-24`, Newton 4, seed 2842869, warmup 30, pomiar 300. Oba przebiegi ukończyły 330 klatek Metal, zero fallbacków.

| Metryka p95 | Baseline Task 3, diagnostyka | Task 4, diagnostyka |
| --- | ---: | ---: |
| Pełna klatka, ms | 270,4805 | 155,6493 |
| Ukończone GPU, ms | 160,6251 | 117,6158 |
| Command buffery | 242 | 82 |
| Encodery | 14897 | 4607 |

Spadek pełnego p95 wynosi 42,45%, GPU p95 26,78%, liczby command bufferów p95 66,12%, encoderów p95 69,07%. To porównanie dwóch przebiegów diagnostycznych, nie estymacja narzutu przez odejmowanie percentyli. Zmienność obciążenia hosta/GPU pozostaje ograniczeniem pomiaru.

Wariant bez diagnostyki: pełna klatka p50/p95/max 50,5709/152,5529/286,9562 ms; GPU p50/p95/max 35,5215/114,9077/222,0081 ms. Task 3 nie zawiera osobnego zwykłego baseline, więc nie wyliczamy względem niego poprawy wariantu zwykłego ani narzutu diagnostyki z pojedynczej pary pomiarów.

Jakość w obu przebiegach identyczna z baseline: penetracja p95/max 38,3238/46,4683, reszta p95/max 884,5847/5811,5098, maksimum niezbieżnych komponentów 9, containment 0, non-finite: no. Maksima pracy również bez zmian: solve 12, tentative 8, kontakty 24, grupy CCD 7. Istniejąca różnica względem CPU pozostaje nierozwiązana.

Zmiana odczytuje ukończone decyzje `flow.x/y` przed kolejnymi slotami solve/Newtona/PCG/line search. Zachowane są limity, shaderowa fizyka, kolejność kontaktów, overflow retry, fatal latch i atomowa publikacja. Aktywne partie PCG oraz końcowe buffery finish/guards/contours/render pozostają oddzielone jak wcześniej. Nie grupowano ich bez smoke fizycznego urządzenia.

Surowe wyniki:

- `reference-gpu-profile-mac-mini-2026-10-06.txt` — baseline Task 3.
- `reference-gpu-schedule-profile-mac-mini-2026-10-06.txt` — Task 4, diagnostyka.
- `reference-gpu-schedule-normal-mac-mini-2026-10-06.txt` — Task 4, zwykły.

Pełne `swift test`: 487 testów, zero błędów, jeden warunkowy skip. Unsigned iOS Release build udany.

## Smoke na fizycznym iPhonie X — 12.10.2026

Xcode 26.6, konfiguracja Run: Release. Scena `interactive-24`, Newton 4, ten sam seed, 30 warmup + 300 measured, diagnostyka GPU włączona. Surowy raport: `reference-gpu-schedule-iphone-2026-10-12.txt`. Wszystkie 330 klatek ukończono na Metal; brak fallbacków, hangów i non-finite. Jakość jest identyczna z wcześniejszym smoke iPhone’a: penetracja p95/max 38,3238/46,4683; reszta p95/max 884,5847/5811,5098; niezbieżne komponenty maks. 9; containment 0. Maksima pracy także bez zmian.

Pełna klatka p95 wyniosła 704,2258 ms wobec 1284,8055 ms w poprzednim, **niediagnostycznym** smoke; ukończone GPU p95 295,3576 wobec 399,5981 ms. Różnica wskazuje poprawę kierunkową, ale tych percentyli nie wolno traktować jako kontrolowanego pomiaru narzutu ani procentowej poprawy ze względu na różne tryby i warunki. W bieżącym profilu p95 to 82 command buffery, 4607 encoderów, 291,9491 ms kodowania hosta i 403,9678 ms oczekiwania. Najdroższy etap GPU p95 to PCG 153,8443 ms, następnie line search 55,3991 ms i kontury 43,5156 ms; percentyli etapów nie należy sumować.

Smoke bezpieczeństwa Task 4 zaliczony: brak hang/fallback i regresji jakości. **Bramka wydajności 10 ms nie jest zaliczona**; ten przebieg diagnostyczny nie jest pomiarem akceptacyjnym. Następne zadanie może badać seryjne budowanie kandydatów i CCD, ale profil urządzenia dodatkowo wskazuje na wysoki koszt sterowania hosta i PCG. Mac pozostaje pętlą rozwojową, iPhone X — urządzeniową bramką.
