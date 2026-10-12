# Referencyjny GPU — równoległe kandydaty i CCD

Pomiar diagnostyczny Mac mini Mac14,12 / Apple M2 Pro, Release, `interactive-24`, Newton 4, seed 2842869, warmup 30 + 300 klatek mierzonych. Surowy raport Task 5: `reference-gpu-candidates-profile-mac-mini-2026-10-12.txt`; porównanie Task 4: `reference-gpu-schedule-profile-mac-mini-2026-10-06.txt`. W obu przebiegach 330/330 klatek Metal, zero fallbacków. Percentyle etapów odnoszą się do całych command bufferów i nie sumują się.

| Metryka p95 | Task 4 | Task 5 |
| --- | ---: | ---: |
| Pełna klatka, ms | 155,6493 | 140,3888 |
| Ukończone GPU, ms | 117,6158 | 99,8865 |
| CCD, ms | 11,5505 | 5,6051 |
| PCG, ms | 59,7551 | 56,0083 |
| Line search, ms | 26,4662 | 22,7496 |
| Kontury, ms | 14,8746 | 15,1295 |

CCD p95 spadło o około 51,5%, lecz pełna klatka tylko o około 9,8%. Jest to poprawa kierunkowa dla podobnego przebiegu diagnostycznego, nie dowód spełnienia budżetu. PCG pozostaje największym mierzonym etapem. Liczniki command bufferów p95 pozostały na 82; encoderów p95 wzrosły z 4607 do 4619. Jakość w obu raportach jest identyczna: penetracja p95/max 38,3238/46,4683, reszta 884,5847/5811,5098, maks. 9 niezbieżnych komponentów, containment 0, brak non-finite.

Krótki smoke `stress-300` na Macu (0 warmup + 3 measured, Newton 4) ukończył 3/3 Metal bez fallbacku; pełna klatka p95 około 1332 ms, GPU p95 około 1256 ms. Tak mała próba nie jest pomiarem akceptacyjnym ani porównaniem z bazą. Wskazuje, że `stress-300` pozostaje bardzo daleko od celu, a największymi etapami są PCG i line search.

Testy porównują kandydatów, ID, czasy TOI i grupy CCD z niezależnym oracle CPU dla `stress-300`, sprawdzają dokładną wymaganą pojemność po overflow oraz deterministyczny retry. Pełne `swift test`, unsigned iOS Release build w Xcode 26.6 i niezależny przegląd przeszły. **Bramka Task 5 pozostaje otwarta do smoke Release na fizycznym iPhonie X po zmianie potoku CCD**. Mac nie zastępuje tej walidacji ani bramki 10 ms p95 dla 300 baniek.
