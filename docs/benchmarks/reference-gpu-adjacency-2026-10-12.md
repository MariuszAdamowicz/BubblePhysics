# Referencyjny GPU — lokalny indeks kontaktów

Task 6 tworzy deterministyczne sąsiedztwo kontaktów dla operatorów Newton/PCG i odbudowuje je po odświeżeniu aktywnych wycinków kontaktów. CPU pozostaje wyrocznią kolejności sumowania, duplikatów i reguły ostatniego zapisu. Pełne `swift test --quiet`, unsigned Release iOS build w Xcode 26.6 oraz niezależny review przeszły. Testy obejmują wrażliwy na kolejność operator, duplikaty, overflow i aktywację CCD z ID po obu stronach bitu 63.

## Mac mini — profil diagnostyczny

Mac14,12 / Apple M2 Pro, Release, `interactive-24`, limit Newtona 4, seed 2842869, warmup 30 + 300 mierzonych. Surowy raport: `reference-gpu-adjacency-profile-mac-mini-2026-10-12.txt`. Porównanie odnosi się do tej samej konfiguracji Task 5.

| Metryka p95 | Task 5 | Task 6 |
| --- | ---: | ---: |
| Pełna klatka, ms | 140,3888 | 65,7716 |
| Ukończone GPU, ms | 99,8865 | 47,2517 |
| PCG, ms | 56,0083 | 20,0783 |
| Line search, ms | 22,7496 | 15,7744 |
| CCD, ms | 5,6051 | 2,7891 |

Pełna klatka p95 spadła o około 53,2%, a PCG p95 o około 64,2%. Liczba encoderów p95 wzrosła z 4619 do 5414, więc poprawa pochodzi z pracy operatorów na lokalnym sąsiedztwie, a nie z redukcji liczby wysłań. Jakość jest identyczna z Task 5: penetracja p95/max 38,3238/46,4683, reszta p95/max 884,5847/5811,5098, maks. 9 niezbieżnych komponentów, containment 0 i brak non-finite.

Krótki diagnostyczny smoke `stress-300` na Macu (0 warmup + 3 measured) ukończył 3/3 klatek Metal bez fallbacku, lecz pełna klatka p95 około 823 ms. To nie jest pomiar akceptacyjny ani porównanie z bazą; etapami dominującymi w tej próbce są line search i CCD.

## iPhone X — smoke Release

Xcode 26.6, iPhone X z iOS 16.7.16, `interactive-24`, limit Newtona 4, seed 2842869, warmup 30 + 300 mierzonych, diagnostyka GPU włączona. Surowy raport: `reference-gpu-adjacency-iphone-2026-10-12.txt`.

| Metryka p95, iPhone X | Task 5 | Task 6 |
| --- | ---: | ---: |
| Pełna klatka, ms | 679,9320 | 578,2023 |
| Ukończone GPU, ms | 306,1075 | 211,8036 |
| PCG, ms | 166,9623 | 75,4935 |
| Line search, ms | 63,1282 | 69,1892 |
| CCD, ms | 16,9864 | 15,3675 |

W obu przebiegach ukończono 330/330 klatek Metal bez fallbacku, containment i non-finite. Penetracja p95/max 38,3238/46,4683, reszta p95/max 884,5847/5811,5098 i maksimum niezbieżnych komponentów 9 są identyczne. Smoke bezpieczeństwa Task 6 jest zaliczony. Pełna klatka p95 spadła o około 15,0%, a ukończone GPU p95 o około 30,8%; równocześnie line search wzrósł, więc nie sumujemy etapów ani nie przypisujemy całej poprawy wyłącznie PCG.

Budżet `10 ms p95` nie jest spełniony. Ten przebieg jest diagnostyczny i dotyczy 24 baniek, nie stanowi bramki `stress-300`. Kolejny krok planu to pełne macierze `interactive-24` i `stress-300` na tym samym urządzeniu, bez diagnostyki, aby podjąć końcową ocenę.
