# Task 7 — raport wykonania

## Zakres

Dodano typowane zdarzenia `mergeContact`, `driveBlocked`, `enteredSensor`, `exitedSensor`, `didExitSimulationRegion` i `didWrap` oraz jawny `WorldEventOverflow` w `WorldFrame` i `WorldDiagnostics`. Istniejące, domyślnie puste `EventInterest` i pojedynczą pojemność `WorldConfiguration.eventBufferCapacity` wykorzystano bez tworzenia drugiej konfiguracji. Potwierdzenia transakcji zachowały dotychczasową semantykę.

GPU filtruje kontakty merge dopiero po sprawdzeniu zainteresowania **obu** baniek i wspólnego bitu pełnej maski `UInt64` (`MergeGroupSet`). Ten sam ograniczony bufor i licznik overflow przyjmują wyłącznie przejścia wejścia/wyjścia sensorów. Sensory kołowe i wielokątne sprawdzają bańki oraz wielokąty na GPU; filtr ID sensora jest przygotowywany z deskryptorów i sprawdzany przy selekcji pary. Poprzednie przecięcia par są przechowywane w prywatnych buforach GPU, także gdy zdarzenie nie zmieściło się w buforze publikacji. Odczyt zdarzeń obejmuje tylko `min(liczba wybranych, pojemność)` rekordów oraz licznik; istniejące odczyty kontaktów i konturów solvera pozostają osobną ścieżką.

Zdarzenia regionu respektują zainteresowanie obiektu i wspólną pojemność. `driveBlocked` powstaje przy wejściu w blokadę lub zmianie blokera, wyłącznie dla zainteresowanego obiektu; ciągły `DriveFeedback` pozostaje niezależny. Nie dodano wykonywania merge/split ani renderera.

## Dowody testowe

- RED: nowy zestaw `EventInterestTests|NativeMetalEventCompactionTests` nie kompilował się z powodu brakujących wariantów `WorldEvent` i `WorldFrame.eventOverflow`.
- RED: `testMergeContactRequiresBothInterestAndOverlappingUInt64GroupBit` początkowo nie wykrywał styku po rozwiązaniu kontaktu; filtr przełączono na rekord aktywny w bieżącej klatce zamiast dodatniej penetracji po solverze.
- RED→GREEN: `testPolygonObjectEntersAndExitsPolygonSensor` wykazał brak obsługi wielokątów, a `testPolygonSensorIgnoresDistantCollinearEdges` wykazał fałszywy kontakt krawędzi; oba scenariusze działają po dodaniu ścieżki GPU i testu zakresów odcinków.
- RED→GREEN: `testWrapEventRequiresInterest` potwierdził brak zdarzenia wrap przed dołączeniem flag regionu.
- RED→GREEN: `EventCompactorTests` wymusił jednorazowe `driveBlocked` przy ciągłym feedbacku.
- `swift test --filter 'EventInterestTests|NativeMetalEventCompactionTests|NativeMetalBroadPhaseTests|NativeMetalContactCacheTests'`: PASS przed końcowymi rozszerzeniami testów i obsługi wielokątów; końcowa weryfikacja podana niżej.
- `git diff --check`: PASS.
- Pierwszy pełny `swift test`: jedna porażka w istniejącym `NativeMetalSolverLifecycleTests/testABIRecordsUseSixteenByteLanes` (rekord bańki ma teraz 144 zamiast 128 bajtów po dodaniu 16-bajtowego lane mask). Pozostałe pakiety przeszły. Asercję ABI uaktualniono i rozszerzono o nowe rekordy; filtr tego testu przeszedł po korekcie.

## Weryfikacja końcowa

Powtórne pełne `swift test` zakończyło się kodem 0: 698 testów, 0 porażek, 1 test pominięty przez istniejący pakiet referencyjny. Wszystkie osiem pakietów XCTest przeszło. Wynik zapisano w `/tmp/bubble-task7-verified-swift-test.log`.

## Uwagi

Pojemność dotyczy dyskretnych zdarzeń symulacji. Dotychczasowe potwierdzenia i odrzucenia transakcji są kontrolnym wynikiem operacji i nie są usuwane przez bufor GPU. Niezwiązany, wcześniej obecny `Benchmarks/iOS/BubblePhysicsBench/.DS_Store` pozostaje nietknięty i nie będzie dodany do commita.

## Korekta P2 — kolejność par i usuwanie obserwowanych obiektów

Test RED wykazał, że stała para sensora z identyfikatorami obiektów `1` i `UInt64.max` ponownie emitowała `enteredSensor`, a po wyjściu nie emitowała obu `exitedSensor`. Przyczyną był porządek bańek według signed `ReferenceBubbleID` i wyszukiwanie poprzednich par według unsigned `UInt64`. Wyszukiwanie i skan brakujących par używają teraz tego samego porządku signed dla bańek, z zachowaniem pełnych bitów `UInt64` w rekordach; wielokąty nadal używają własnego porządku unsigned.

Drugi test RED wykazał brak `exitedSensor` po usunięciu obserwowanego obiektu. Poprzednie aktywne pary, których nie ma w bieżącej uporządkowanej tablicy, są teraz skanowane i kompaktowane na GPU do wspólnego ograniczonego bufora zdarzeń. Stan par przechowuje bit zainteresowania wyjściem. Po usunięciu ostatniego ciała runtime wykonuje jedną klatkę GPU tylko wtedy, gdy istnieje historia par do rozliczenia; wyczyszczenie historii pozwala ponownemu użyciu tego samego ID wygenerować nowe wejście.

Regresje obejmują trwałe przecięcie `1`/`UInt64.max`, usunięcie i ponowne dodanie bańki i wielokąta, ścieżkę bez ciała oraz dwa usunięte przecięcia przy pojemności 1. Ostatni przypadek potwierdza 1 opublikowane wyjście, `droppedCount == 1` i brak ponownej emisji w następnej klatce. `swift test --filter 'NativeMetalEventCompactionTests|EventInterestTests/testRemovingLastBody'`: 11 testów, 0 porażek. Pełny `swift test`: 703 testy, 0 porażek, 1 istniejący test pominięty; osiem pakietów XCTest przeszło. Log: `/tmp/task7-p2-full.log`.
