# Analiza benchmarku zbieżności referencyjnego solvera

## Warunki pomiaru

- urządzenie: iPhone, iOS 16.7.16;
- konfiguracja: Release, 30 klatek rozgrzewki i 300 mierzonych;
- sceny: `interactive-24` i `stress-300`;
- limity Newtona: `4/8/12/16`;
- surowy, nieprzepisany raport: `reference-convergence-iphone-2026-10-04.txt`.

Roboczy budżet wynosi `10 ms p95` dla pełnej części CPU. Nie jest to samodzielne kryterium: ocena obejmuje też penetrację, reszty, niezbieżne komponenty, wieloklatkowe zawarcia i stany niefinitywne.

## Wynik czasu

| Scena | Limit | Full p50 [ms] | Full p95 [ms] | Solver p95 [ms] | Kontur p95 [ms] | Ocena budżetu |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `interactive-24` | 4 | 0,7272 | 1,9065 | 1,6592 | 0,3159 | mieści się |
| `interactive-24` | 8 | 0,9528 | 3,4988 | 3,1991 | 0,3214 | mieści się |
| `interactive-24` | 12 | 1,3498 | 4,1580 | 3,9088 | 0,3382 | mieści się |
| `interactive-24` | 16 | 1,6613 | 5,1245 | 4,8719 | 0,3228 | mieści się |
| `stress-300` | 4 | 17,5512 | 92,9683 | 87,0617 | 7,5302 | nie mieści się, 9,3× budżetu p95 |
| `stress-300` | 8 | 25,9199 | 164,5931 | 159,5598 | 6,9046 | nie mieści się, 16,5× budżetu p95 |
| `stress-300` | 12 | 35,5934 | 222,8277 | 216,2671 | 7,1289 | nie mieści się, 22,3× budżetu p95 |
| `stress-300` | 16 | 44,7875 | 277,4367 | 272,9760 | 6,8897 | nie mieści się, 27,7× budżetu p95 |

W `stress-300` solver odpowiada za około 94–98% p95 pełnej klatki. Kontury kosztują tylko 6,9–7,5 ms p95, a przygotowanie danych renderowania około 0,013–0,014 ms p95. Optymalizacja konturów lub broad phase nie może sama odzyskać wymaganych co najmniej 82,97 ms p95 dla wariantu z limitem 4.

## Jakość rozwiązania

`interactive-24` nie ma zawarć wieloklatkowych ani stanów `non-finite`, lecz każdy limit pozostawia 8–9 niezbieżnych komponentów i wysokie reszty. Większy limit nie poprawia metryk monotonicznie: p95 penetracji pozostaje w przedziale 34,33–37,53, a p95 reszty w przedziale 588,92–1252,89.

`stress-300` nie ma stanów `non-finite`, ale jest wyraźnie trudniejszy: 37–39 niezbieżnych komponentów, p95 penetracji 23,04–23,40 oraz 10–26 kolejnych klatek pełnego zawarcia. Limit 8 daje najniższą odnotowaną liczbę zawarć (10) i najniższe p95 reszty (1196,13), lecz jego p95 pełnej klatki wynosi 164,59 ms. Żaden stały limit z macierzy nie daje zarazem akceptowalnego czasu i jakości.

## Rekomendacja dla CEO

**Rekomendacja: B — port Newton/PCG na GPU.**

Jest to kierunek najlepiej uzasadniony pomiarem: głównym kosztem jest Newton/PCG, a nie kontury. Adaptacyjne kończenie zbieżnych komponentów na CPU (A) może ograniczyć pracę części układów, ale nie ma dowodu, że zredukuje p95 `stress-300` o rząd wielkości; przy tym 37–39 komponentów nadal pozostaje niezbieżnych. Optymalizacja konturów albo broad phase (C) nie trafia w dominującą fazę.

Port powinien zachować deterministyczne sceny i pełną telemetrię jakości jako bramkę porównawczą. Nie należy jeszcze ustalać dynamicznego limitu iteracji: jego projekt zależy od zachowania solvera GPU i wymaga osobnej decyzji CEO po specyfikacji portu.
