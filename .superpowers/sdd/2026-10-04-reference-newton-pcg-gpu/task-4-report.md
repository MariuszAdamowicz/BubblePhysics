# Task 4 — matrix-free PCG na GPU

## Zakres

Wykonano wyłącznie Task 4 w czterech plikach briefu. CPU reference, historyczny Metal, world integration, UI benchmarku oraz Studio OS pozostały bez zmian. Nie użyto rozszerzenia zakresu ani dodatkowych helperów.

## Implementacja

- `ReferenceMetalBufferLayout.swift`: rekord kontrolny Swift/MSL z trzema polami SIMD4, wyrównaniem 16 i stride 48; active, licznik, flagi non-finite, normy, próg oraz współczynniki rekurencji.
- `ReferenceMetalSolver.swift`: ładowanie czterech pipeline'ów PCG, trwałe bufory wektorów i control, endpoint `solvePCGForTesting(snapshot:endCenters:rightHandSide:limit:) async throws -> ReferencePCGResult`.
- `ReferenceNewtonPCGKernels.metal`: `referencePCGInitialize`, `referencePCGAdvance`, `referencePCGUpdateDirection`, `referencePCGFinalize`; matrix-free operator i odwrotna przekątna pochodzą z Task 3.
- `ReferenceMetalPCGTests.swift`: 10 testów rzeczywistego Metal, z pominięciem wyłącznie przy braku urządzenia, oraz niezależny od urządzenia test ABI dodany po recenzji.

CPU koduje dokładnie stały maksymalny limit iteracji do pojedynczego command bufferu, bez odczytu skalara między dispatchami. Rekord GPU zatrzymuje aktualizacje korekty, reszty i kierunku po progu zbieżności albo guardzie. Jacobian i denominator mogą nadal być obliczane przez zakodowane późniejsze dispatch'e, lecz nie zmieniają wyniku. Pusty układ i niepozytywny limit zachowują wynik CPU.

Denominator wykorzystuje dwufazową, stałoblokową redukcję Task 3. Normy i r·z sumują się na GPU w kolejności rosnących wierszy, zachowując kolejność CPU. Initialize/advance/finalize pracują na pojedynczym wątku GPU, a Jacobian, odwrotna przekątna i aktualizacja kierunku są równoległe. Zachowano denominator > Float.ulpOfOne, kontrolę finite denominatora/rz/current norm/nextRZ i końcową kontrolę korekty. NaN lub infinity w RHS są jawnie raportowane przed iteracją.

Jawna różnica odporności: GPU flaguje NaN w RHS bezpośrednio poprzez `isfinite`, podczas gdy CPU `max(0, dot(residual, residual))` może maskować NaN jako zero i zakończyć bez flagi non-finite. GPU ma w tym przypadku silniejszy guard; nie jest to pełna bitowa równoważność z CPU. Dla skończonych fixture'ów pozostaje sprawdzona zgodność korekty i norm do `1e-3` oraz dokładna zgodność licznika iteracji.

## Ruling dotyczący wyniku

Publiczny typ CPU `ReferencePCGResult` nie ma publicznego konstruktora. Zgodnie z rulingiem kontrolera wykonano pustą fabrykę przez `ReferencePCGSolver.solve(rightHandSide: [], apply: { $0 }, inverseDiagonal: [], tolerance: 0, iterationLimit: 0)`, a następnie przypisano każde publiczne pole z końcowego readbacku GPU. Fabryka nie wykonuje operatora ani iteracji i nie dostaje danych układu. Komentarz produkcyjny opisuje ten kontrakt; literalny test korekty oraz porównania CPU dowodzą, że pusty wynik nie trafia do użytkownika. Nie zmieniono API CPU.

## RED/GREEN

1. Najpierw napisano 8 testów. RED kompilacji: brak `solvePCGForTesting`, exit 1; log `/tmp/reference-metal-task4-red.log`.
2. Po szkielecie endpointu i rozwiązaniu niedostępnego konstruktora: behawioralny RED, 8 testów, 34 failures, exit 1. Brak korekty/iteracji/norm i sygnałów non-finite. Log `/tmp/reference-metal-task4-behavior-red.log`.
3. Minimalna implementacja GPU: GREEN, 8 testów, 0 failures/skips. Log `/tmp/reference-metal-task4-green.log`.
4. Dodano niezerową resztę poniżej tolerancji oraz 513 wierszy przekraczających dwa pełne i jeden częściowy blok, wraz z ponownym użyciem buforów dla jednego wiersza. GREEN, 10 testów. W fixture 513 ostatni wiersz ma RHS (32,-64), więc pominięcie częściowego bloku zmienia wynik wyraźnie ponad 1e-3.
5. Mutacyjny RED zbieżności: czasowo wyłączono tylko warunek progu. Test niezerowej reszty zwrócił 2 zamiast 1 iteracji i zmienioną korektę/normę — 3 failures, exit 1. Log `/tmp/reference-metal-task4-convergence-mutation-red.log`. Warunek przywrócono.
6. Mutacyjny RED denominatora: czasowo zastąpiono > ulpOfOne przez > 0. Test małego denominatora zwrócił 1 zamiast 0 iteracji — 1 failure, exit 1. Log `/tmp/reference-metal-task4-denominator-mutation-red.log`. Guard przywrócono.
7. Mutacyjny RED redukcji: czasowo pominięto ostatni blok. Mocniejsza fixture 513 dała 1031 niezgodnych asercji, w tym 8 zamiast 1 iteracji, błędne wektory i błędny następny solve o jednym wierszu; exit 1. Log `/tmp/reference-metal-task4-reduction-mutation-red-final.log`. Redukcję przywrócono.
8. Końcowy focused GREEN: `swift test --filter ReferenceMetalPCGTests`, 10 testów, 0 failures/skips, exit 0. Log `/tmp/reference-metal-task4-focused-final.log`. Bańka–bańka jest zgodna z CPU dla limitu 1 i 8 (CPU/GPU kończą po 2 iteracjach przy limicie 8), bańka–odcinek po 1, diagonalny układ przy limicie 8 po 1. Korekta i obie normy mieszczą się w 1e-3; licznik jest równy dokładnie.

Podczas dodawania dwóch testów poprawiono kolejność nazwanych argumentów konstruktora konfiguracji. Nie traktowano tego błędu kompilacji jako behawioralnego RED.

## Weryfikacja końcowa

- Kompilacja offline iOS 16/MSL 2.4: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcrun -sdk iphoneos metal -std=ios-metal2.4 -mios-version-min=16.0 -c Sources/BubblePhysicsReferenceMetal/Shaders/ReferenceNewtonPCGKernels.metal -o /tmp/reference-newton-pcg-task4-ios16.air`, exit 0 po przywróceniu wszystkich mutacji.
- `git diff --check`: exit 0.
- Pełny `swift test`: exit 0, 421 testów, 0 failures, 1 istniejący opt-in skip `ReferenceBenchmarkTests.testPrintLocalBaselineWhenRequested`. Zestawy: historyczny CPU 118, CPU reference 152, reference Metal 33 (w tym 10 PCG), historyczny Metal 110, core 8. Wszystkie pięć zestawów ma `All tests passed`; suite zakończyła się o 22:56:02. Log `/tmp/reference-metal-task4-full-final.log`. Focused run i pełna suite wykonane jednym poleceniem `swift test --filter ReferenceMetalPCGTests && swift test` po przywróceniu wszystkich mutacji.

## Ryzyka i granice

Ten etap dowodzi operatorów i sprawdzonych guardów PCG z opisaną wyżej różnicą NaN, nie jakości pełnego świata ani p95 na iPhonie. Szeregowy kernel advance oraz późniejsze, już niepotrzebne dispatch'e operatora po zbieżności mogą być kosztem wydajności; wymaga to pomiaru w Task 7. Nie wprowadzono adaptacyjnego limitu, zmiany fizyki, tolerancji ani portu produktu na macOS. macOS pozostał hostem testowym zgodnie z wcześniejszym rulingiem. Mutable solver zakłada serialnego właściciela, a evaluationInFlight chroni bufor przed ponownym wejściem podczas async; nie dodano nieuzasadnionego Sendable.

Istniejący nieśledzony `.DS_Store` pozostał bez zmian i poza commitem. Raport początkowo pozostawał w ignorowanym katalogu procesu `.superpowers`; follow-up dodaje do Git wyłącznie ten wskazany raport zgodnie z poleceniem kontrolera.

## Commit

`5fc5f0c18e6fefa6007dc683cfb28ef76594f074` — `feat: solve reference PCG on Metal`.

4 pliki, 454 insertions, 1 deletion. `git diff --cached --check` bezpośrednio przed commitem: exit 0. Po commicie pozostaje tylko wcześniejszy nieśledzony `Benchmarks/iOS/BubblePhysicsBench/.DS_Store`.

## Follow-up po recenzji

Dodano `testPCGControlMatchesMetalABI` w `ReferenceMetalPCGTests.swift`: size i stride równe 48, alignment 16, offsety state/norms/recurrence równe 0/16/32. Test nie wymaga urządzenia Metal i stale chroni kontrakt odczytu rekordu Swift/MSL.

TDD ABI: najpierw dodano test, a następnie na potrzeby mutacyjnego RED czasowo wstawiono dodatkowe pole SIMD4 przed state. `swift test --filter ReferenceMetalPCGTests.testPCGControlMatchesMetalABI` zakończyło się exit 1: 1 test, 5 failures (size/stride 64 i offsety 16/32/48). Log `/tmp/reference-metal-task4-abi-red.log`. Usunięto mutację, przywracając kod produkcyjny dokładnie do commitu `5fc5f0c` przed GREEN i pełną suite.

Follow-up GREEN: `swift test --filter ReferenceMetalPCGTests`, exit 0, 11 testów, 0 failures/skips. Log `/tmp/reference-metal-task4-followup-focused-green.log`. Następnie pełny `swift test`, exit 0: 422 testy, 0 failures, 1 istniejący opt-in skip `ReferenceBenchmarkTests.testPrintLocalBaselineWhenRequested`. Zestawy: historyczny CPU 118, CPU reference 152, reference Metal 34 (11 PCG/ABI), historyczny Metal 110, core 8. Wszystkie pięć zestawów zakończyło się `All tests passed`, ostatni o 23:07:57. Log `/tmp/reference-metal-task4-followup-full-green.log`.

Commit follow-up `test: lock reference PCG control ABI` obejmuje wyłącznie test i ten raport; raport jest dodany do Git jawnie pomimo ignorowania katalogu procesu, zgodnie z poleceniem kontrolera. Kod produkcyjny pozostaje identyczny z `5fc5f0c`, co potwierdza `git diff --exit-code -- Sources/BubblePhysicsReferenceMetal`, exit 0. Hash follow-up jest raportowany w zakończeniu sesji.
