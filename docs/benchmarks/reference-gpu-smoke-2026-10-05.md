# BubblePhysics — smoke referencyjnego GPU na iPhonie X, 2026-10-05

Kryteria bramki nie są spełnione. Smoke ukończył wszystkie 330 klatek Metal bez fallbacku i zgłoszonego hang, ale p95 pełnej klatki dla zaledwie 24 bąbli wyniosło **1284.8055 ms**. To około 674 razy więcej niż baseline CPU i 128 razy więcej niż roboczy budżet 10 ms. Wynik nie stanowi akceptacji GPU.

## Źródło i zakres

Rzeczywisty raport skopiowany z fizycznego iPhone X został przekazany przez kontrolera sesji po świeżym smoke aplikacji Release z kodem `428d18d` (`fix: reserve complete records for empty Metal buffers`). System: iOS 16.7.16; scena: `interactive-24`; limit Newtona 4; seed 2842869; 30 warmup i 300 measured. Nazwa urządzenia drukowana przez aplikację pozostaje oryginalnym `iPhone`.

[Surowy raport](reference-gpu-smoke-iphone-2026-10-05.txt) zachowuje skopiowane linie i wartości bez dopisków. To pojedynczy smoke, **nie macierz akceptacyjna**. Porównanie CPU pochodzi z [baseline’u 2026-10-04](reference-convergence-iphone-2026-10-04.txt), wiersza `interactive-24` / limit 4, z identycznym seedem i liczbą kroków.

## Czas i jakość

| Miara | CPU baseline, limit 4 | GPU smoke, limit 4 |
| --- | ---: | ---: |
| Pełna klatka p50, ms | 0.7272 | 993.4200 |
| Pełna klatka p95, ms | 1.9065 | 1284.8055 |
| Pełna klatka max, ms | 3.0040 | 1649.1240 |
| `solver_p95_ms` | 1.6592, solver CPU | 399.5981, suma ukończonych etapów GPU |
| Penetracja p95 | 35.3938 | 38.3238 |
| Penetracja max | 45.6981 | 46.4683 |
| Reszta p95 | 1087.7268 | 884.5847 |
| Reszta max | 6406.6611 | 5811.5098 |
| Niezbieżne komponenty, max | 8 | 9 |
| Kolejne zawarcia, max | 0 | 0 |
| Non-finite | no | no |

Wiersz `gpu_completed` obejmuje 300 udanych mierzonych klatek: suma czasów ukończonych command bufferów ma p50 **225.6278 ms**, p95 **399.5981 ms**, max **612.6544 ms**. Samo p95 tej pracy GPU przekracza 10 ms około 40 razy. p95 pełnej klatki obejmuje także upload, oczekiwanie, readback, walidację i przygotowanie klatki; nie wolno traktować różnicy dwóch percentyli jako zmierzonego narzutu konkretnego etapu. `solver_p95_ms` CPU i GPU mają różny zakres, dlatego ich iloraz nie jest porównaniem czasu samego Newton/PCG.

Liczniki obejmujące warmup: CPU 0, Metal 330, fallback 0, warmup fallback 0. Brak wiersza błędu GPU. `eligible` potwierdza kwalifikowalny pomiar Metal w tym przebiegu, a nie spełnienie budżetu lub jakość wystarczającą do akceptacji. Maksima telemetrii z ukończonych mierzonych klatek: 12 total solve, 8 tentative solve, 24 kontakty i 7 grup CCD; nie są to sumy całego benchmarku.

Jakość nie jest jednoznacznie lepsza od CPU: penetracja p95 wzrosła o 2.9300 (około 8.28%), penetracja max o 0.7702, a maksimum niezbieżnych komponentów z 8 do 9. Reszty p95/max są niższe, zawarcia i non-finite pozostają bez regresji w raportowanych metrykach. Ten smoke nie dowodzi spełnienia warunku „jakość nie gorsza od CPU”.

## Wynik bramki i dalsza procedura

Watchdog nie wystąpił w tym konkretnym smoke; nie jest to dowód stabilności wszystkich scen lub limitów. Kryterium czasu nie jest spełnione już dla `interactive-24`. Kontroler polecił **nie uruchamiać automatycznie macierzy stress-300 ani pozostałych macierzy 4/8/12/16**, ponieważ p95 ukończonego GPU 399.5981 ms i pełnej klatki 1284.8055 ms zdecydowanie przekraczają roboczy budżet 10 ms.

Nie wykonano macierzy `interactive-24` 4/8/12/16 ani `stress-300`, nie ma ich wyników i nie utworzono dokumentu pozorującego pełną akceptację. Bramka pozostaje niezaakceptowana. Limity Newtona/PCG i parametry fizyki pozostają niezmienione. Dalsza inwestycja w optymalizację albo zakończenie tej ścieżki wymaga decyzji CEO; ten dokument zapisuje wynik pomiaru i brak spełnienia kryteriów.
