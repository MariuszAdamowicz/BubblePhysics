# Referencyjny GPU — baseline profilu Mac mini, 2026-10-06

Kod: `6b74d3c` (`feat: profile reference GPU frame stages`). Host: Mac mini M2 Pro, model `Mac14,12`, GPU `Apple M2 Pro`, system `Version 26.6.2 (Build 25G83)`. Konfiguracja Release: `interactive-24`, seed 2842869, limit Newtona 4, 30 klatek warmup i 300 mierzonych. Diagnostyka włączona. Surowy stdout: [reference-gpu-profile-mac-mini-2026-10-06.txt](reference-gpu-profile-mac-mini-2026-10-06.txt); plik zapisany bez ręcznego przepisywania.

Komenda:

```sh
swift run -c release BubblePhysicsReferenceBench --scene interactive-24 --backend metal --limits 4 --warmup 30 --measured 300 --diagnostics
```

Przebieg zakończył się poprawnie (exit 0), 330/330 klatek Metal, zero fallbacków, zero kolejnych klatek containment, brak non-finite. Każdy etap ma 300 mierzonych próbek. `gpu_measurement=eligible` oznacza kompletność ścieżki GPU, nie zatwierdzenie wydajności ani jakości fizyki.

## Wynik

| Metryka | p50 | p95 | max |
|---|---:|---:|---:|
| Pełna klatka [ms] | 115,3351 | 270,4805 | 421,2184 |
| Suma ukończonych command bufferów GPU [ms] | 61,1671 | 160,6251 | 292,3771 |
| Command buffery / klatkę | 242 | 242 | 243 |
| Compute encodery / klatkę | 14897 | 14897 | 14899 |
| Kodowanie hosta [ms] | 13,6064 | 41,6926 | 48,9437 |
| Oczekiwanie hosta [ms] | 100,8265 | 231,1355 | 371,0875 |
| Końcowy readback hosta [ms] | 0,0145 | 0,0699 | 0,1160 |

| Etap GPU [ms] | p50 | p95 | max |
|---|---:|---:|---:|
| geometry | 0,0976 | 0,2904 | 0,4287 |
| newton | 2,1669 | 6,0620 | 10,7032 |
| pcg | 38,7753 | 104,0713 | 165,2604 |
| lineSearch | 12,6383 | 32,2419 | 66,4333 |
| ccd | 2,4417 | 7,3904 | 27,8215 |
| guards | 0,4909 | 1,5314 | 1,8329 |
| contours | 4,2994 | 14,9435 | 20,3931 |
| render | 0,1109 | 0,3334 | 0,5437 |

PCG jest największym etapem GPU, następnie line search i generowanie konturów. Harmonogram nadal koduje prawie 15 tys. encoderów na klatkę; 242 command buffery to regularna ścieżka obecnych limitów. Maksimum 243/14899 uwzględnia dodatkowy ukończony przebieg geometry po odkryciu większej wymaganej pojemności. Liczniki rzeczywiście aktywnej pracy: solve max 12, tentative solve max 8, kontakty max 24, grupy CCD max 7. Dane uzasadniają dalsze badanie kosztu harmonogramu, ale ten commit go nie zmienia.

## Interpretacja i ograniczenia

Etapy są przypisane do całych ukończonych command bufferów. `newton` zawiera inicjalizację PCG; `geometry` inicjalizację klatki i pierwszy begin-solve; `ccd` kolejne begin-solve oraz finalizację świata. Nie są to izolowane czasy pojedynczych kerneli ani wszystkich wywołań geometrii rozproszonych po solverze. Suma etapów w pojedynczej klatce równa się jej ukończonemu czasowi GPU; percentyle osobnych etapów nie muszą sumować się do percentyla całości.

Host encoding obejmuje utworzenie command buffera i kodowanie encoderów. Host waiting mierzy commit, oczekiwanie na ukończenie oraz wznowienie hosta, więc nakłada się na czas GPU. Readback obejmuje końcowy odczyt statusu oraz pakowanie baniek, kontaktów, konturów i render data. Przygotowanie/udostępnienie buforów przed kodowaniem, późniejsza walidacja i publikacja świata oraz przygotowanie benchmarku pozostają w pełnym czasie klatki, poza tymi trzema pomiarami hosta. Nie odejmujemy od siebie p95 hosta i GPU i nie traktujemy różnicy percentyli jako pomiaru narzutu.

Penetracja p95/max: 38,3238/46,4683. Reszta p95/max: 884,5847/5811,5098. Maksimum niezbieżnych komponentów: 9. Instrumentacja nie naprawia wcześniej opisanej różnicy jakości względem CPU; nie jest to akceptacja fizyki.

To pojedynczy profil diagnostyczny na Macu, ze znaczną zmiennością czasu. Nie wykonano tu równoległego pomiaru bez diagnostyki, więc jej narzut nie jest liczbowo oszacowany. Nie należy mieszać tego wyniku z pomiarem akceptacyjnym bez instrumentacji. Nie jest to prognoza iPhone’a X, dowód osiągnięcia 10 ms ani zaliczenie bramki `stress-300`. W tej sesji nie uruchamiano benchmarku na fizycznym iPhonie i nie rozpoczynano Task 4.
