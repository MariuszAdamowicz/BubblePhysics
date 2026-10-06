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

Pełne `swift test`: 487 testów, zero błędów, jeden warunkowy skip. Unsigned iOS Release build udany. Fizyczny iPhone X niewidoczny w `devicectl`; smoke urządzenia niewykonany. Status **DONE_WITH_CONCERNS**. Wynik Maca nie zalicza bramki iPhone ani 10 ms; dalsze zadania pozostają poza tym raportem.
