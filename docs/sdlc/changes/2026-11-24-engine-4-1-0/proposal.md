# Propozycja: BubblePhysics 4.1.0 — koszt pracy podkroku w jednej grupie wątków

**Date:** 2026-11-24
**Status:** Proposal (wejście dla `/tt-agentic-sdlc:change-design`, jeszcze nie projekt)
**Punkt wyjścia:** tag `v4.0.0`; pomiar `docs/benchmarks/v4.0.0-iphone-x.md` (raport @d9a812c, mierzony kod `cfa22c8`); projekt 4.0.0 `docs/sdlc/changes/2026-11-23-engine-4-0-0/change-design.md`, decyzje CD-D-27 i CD-D-28

## Problem

Wersja 4.0.0 nie mieści się w budżecie klatki 16,67 ms (G8-AC2) na iPhonie X w dwóch scenach uderzeń. Rewizja 4.0.0 przeniosła pętlę podkroków do jednej dyspozycji jednej grupy wątków (CD-D-27). Zakładała, że ok. 0,6–0,7 ms na podkrok to narzut kolejnych dyspozycji. Pomiar to założenie obalił.

| Scena | p95 `8ef9d87` (wiele dyspozycji) | p95 `cfa22c8` (jedna dyspozycja) | prognoza CD-D-27 | podkroki p95 | fizyka GPU (telemetria) | fizyka na podkrok |
|---|---|---|---|---|---|---|
| tłum w spoczynku | 12,0 ms | 11,6 ms | ok. 12 ms | 1 | 1,24 → 1,31 ms | — |
| gumka przy ścianie | 13,4 ms | 13,7 ms | — | 2 | 1,98 → 2,08 ms | — |
| czołowe zderzenie 128 | 21,5 ms | 19,7 ms | 13–15 ms | 11 | 7,01 → 6,50 ms | 0,64 → 0,59 ms |
| strzał w tłum | 58,8 ms | 39,2 ms | 14–17 ms | 49–50 | 34,4 → 28,9 ms | 0,69 → 0,59 ms |

Wnioski z pomiaru:

- Jedna dyspozycja zdjęła tylko ok. 15% kosztu podkroku. Ok. 0,59 ms na podkrok dla 150 baniek to praca samego podkroku w jednej grupie, a nie narzut dyspozycji.
- Zysk w strzale w tłum (58,8 → 39,2 ms) to głównie zniknięcie par buforów z czekaniem CPU: czas poza GPU spadł z 15,0 do 9,0 ms, a czas GPU końca kroku z 8,4 do 3,4 ms.
- Presja rejestrów po poprawce tier 1 jest mała. Fizyka w spoczynku wzrosła o ok. 6%. A11 daje jednak jądru jednej grupy tylko 448 wątków (`single_group_width=448`, limit potoku `maxTotalThreadsPerThreadgroup`), a nie 1024 jak Mac. To sygnał wysokiego zużycia rejestrów przez jądro.
- Jedna grupa wątków biegnie na jednym rdzeniu GPU. A11 ma trzy rdzenie, więc fizyka używa co najwyżej jednej trzeciej GPU. To hipoteza, bez pomiaru zajętości rdzeni.
- Strzał w tłum potrzebuje ok. 49 × 0,59 ≈ 29 ms samej fizyki. Żadna z kandydatek CD-D-28 (stały koszt klatki, koszt bufora końca kroku) nie zbije tego poniżej 16,67 ms. Do budżetu brakuje ok. 22,5 ms, czyli ponad połowy klatki.

## Cel 4.1.0

Czołowe zderzenie 128 i strzał w tłum mieszczą się w 16,67 ms p95 na iPhonie X (G8-AC2), bez zmiany fizyki widocznej w grze i bez utraty gwarancji kontaktu z granicą na promieniu (przejście przez ścianę albo bańkę wykluczone z konstrukcji, CD-D-22). Wariantem awaryjnym jest uzgodniona zmiana kryterium, a nie cichy przesuw progu.

## Krok 0: profil podkroku na iPhonie X (przed projektem)

Projekt powinien zacząć się od liczb, a nie od kolejnego szacunku. Szacunek CD-D-27 chybił ok. 2,5×. Proponowany pomiar to Xcode GPU Frame Capture i Metal System Trace sceny `shot-into-crowd` na iPhonie X, Release:

- czas poszczególnych faz podkroku w jądrze jednej grupy: siły kontaktu, redukcja h, całkowanie, sprawdzenie zapasu, przebudowa siatki;
- liczba barier `threadgroup_barrier` na podkrok i ich udział w czasie;
- zajętość rdzeni GPU w czasie fizyki (jeden z trzech czy więcej);
- zużycie rejestrów i pamięci grupy jądra, które ogranicza szerokość do 448;
- liczba kandydatów na bańkę w klatce uderzenia (raport: `max_candidates_per_object=64` w strzale wobec 8 w spoczynku) i koszt pętli po kandydatach.

Wynik tego kroku rozstrzyga, który z kierunków poniżej ma sens.

## Kierunki do rozważenia w change-design

Kolejność nie jest rankingiem. Ranking ustali profil z kroku 0.

1. **Mniej podkroków (reguła h).** 49 podkroków w strzale wynika z członu d / (4 · v) przy prędkości ok. 3 · 10³ j/s. Możliwości: lokalne h albo podkroki tylko dla wyspy kontaktu z szybką bańką, zamiast wspólnego h dla całego świata. Ta opcja wraca w nowej formie: CD-D-27 odrzucił lokalne h, bo nie zmniejszało liczby dyspozycji, ale przy jednej dyspozycji zmniejsza pracę. Inne możliwości to mniejsza wartość zapasu w warunku d / 4 i warunek przy odjeździe. Ryzyko: bilans energii G4-AC1 (odbicie 0,991–0,995) i gwarancja CD-D-22.
2. **Tańszy podkrok w jednej grupie.** Mniej barier na podkrok przez łączenie faz, redukcja h przez operacje SIMD-group zamiast pamięci grupy, mniejsze zużycie rejestrów (szersza grupa na A11) i krótsza pętla po kandydatach, gdy aktywnych kontaktów jest mało.
3. **Więcej niż jeden rdzeń GPU.** Kilka grup wątków współpracujących w jednej dyspozycji wymaga synchronizacji między grupami, której Metal na A11 nie gwarantuje. Druga możliwość to podział pracy podkroku (siły i całkowanie) na grupy z jedną dyspozycją na fazę, ale to wraca do kosztu dyspozycji z 4.0.0. Trzeba to zmierzyć, zanim zostanie odrzucone.
4. **Zmiana kryterium G8-AC2.** Na przykład osobny, wyższy próg dla klatki uderzenia (zdarzenie jednorazowe) albo p95 liczone z sekwencji gry, a nie z powtarzanego uderzenia. To decyzja autora i gry, nie silnika.

## Poza zakresem

- Zmiana prawa kontaktu F = K_c · ε / (1 − ε)² i materiału bańki.
- Zmiana kontraktu `BubbleWorld.advance` (dwa czekania CPU, CD-D-18), chyba że profil pokaże, że to on blokuje budżet po zmniejszeniu kosztu fizyki.
- Kontakt bryły dynamicznej z bańkami (znane ograniczenie 4.0.0).

## Ryzyka i otwarte pytania

- Mac nie odtwarza ani tier 1, ani wydajności A11. Każdą zmianę jądra jednej grupy trzeba mierzyć na iPhonie X, a jądro musi zostać w granicy 31 wiązań i bez wskaźników w buforach (bugfix `2026-11-24-iphone-x-world-failure`).
- Bliźniak ścieżek (G8-AC4) musi objąć każdą nową ścieżkę, którą wprowadzą kierunki 1–3.
- Czy bramka przeciskania na gałęzi gry (zadanie 43 planu 4.0.0, pominięte przy tagu `v4.0.0`) ma być warunkiem 4.1.0?
