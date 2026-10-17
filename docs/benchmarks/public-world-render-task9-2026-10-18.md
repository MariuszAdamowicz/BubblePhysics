# Task 9 — publiczny renderer Metal i bramka urządzenia

## Stan implementacji

`BubblePhysicsMetalRender.encode(world:viewport:commandBuffer:renderPassDescriptor:)` koduje bezpośrednio z nieprzezroczystego uchwytu GPU. W produkcyjnej ścieżce kontury nie są kopiowane na CPU. `BubbleWorld.advance(by:commandBuffer:encodeRender:)` koduje fizykę i render do tego samego bufora wywołującego, zatwierdza go raz, a stan świata publikuje dopiero po poprawnym zakończeniu GPU. Błąd kodowania lub bufora pozostawia poprzednią kompletną klatkę.

Styl techniczny jest neutralnym wypełnieniem. Własny fragment shader używa `makeContourVertexFunction()` i otrzymuje rozwiązane kanały przez `RenderStylePipeline.encodeChannels`. Wypełniane są bańki, proste wielokąty (w tym wklęsłe), sensory i pola sił. To świadoma polityka wizualna: sensory i pola są widocznymi, pełnymi zasięgami; gra może zastąpić ich wygląd własnym fragment shaderem. Wierzchołki wielokątów są triangulowane na CPU z jawnej geometrii modelu, lecz kontury baniek pozostają na GPU. Metoda `debugContourSnapshot()` jest wyłącznie adapterem diagnostycznym i filtruje usunięte obiekty.

Podgląd iOS pobiera drawable w `MTKViewDelegate.draw(in:)`, prezentuje go przez ten sam command buffer, a kolejne żądanie rysowania wysyła po zakończeniu poprzedniego kroku. Nie używa ponownie zaprezentowanego drawable.

## Weryfikacja lokalna

- Testy integracyjne renderer/runtime obejmują ten sam command buffer, kanały przejścia bieżącego kroku, style wielokątów oraz widoczność sensorów/pól, brak rysowania bańki usuniętej przez region i pusty debug snapshot po usunięciu ostatniego ciała.
- Krótki test harnessu wykonuje 1 klatkę rozgrzewki i 2 mierzone; wymaga poprawnego kroku i zerowego odczytu konturów CPU. Nie jest to pomiar wydajności akceptacyjnej.
- `swift test` — **PASS**, kod wyjścia 0 (pełny zestaw pakietu). Po dopracowaniu sceny iOS `swift test --filter MetalRenderIntegrationTests` — **11/11 PASS**.
- Release build: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED**.

## Urządzeniowa bramka akceptacyjna — oczekuje

W aplikacji: „Wizualizacje” → „Publiczny stress-300” → „Start”. Harness uruchamia 300 baniek z tym samym seedem, rozkładem promieni i początkowych pozycji co scena referencyjna, cztery ściany i trójkąt przechodzący po tych samych punktach trasy; w publicznym API trójkąt jest zastępowany co krok, a nie prowadzony ciągłą kinematyką referencji. Limit solvera wynosi 4, jest 30 klatek rozgrzewki i 300 mierzonych. Każda klatka koduje publiczny `BubbleWorld` i bezpośredni renderer do jednego bufora. Raport zawiera p95 i maksimum pełnej klatki, licznik korekt guard, non-finite, fallbacków, błędnych klatek i odczytów konturów CPU. `native_quality_envelope` jest jawnie oznaczone jako nieocenione przez ten harness; wymaga oddzielnych serii referencyjnych przed uznaniem bramki jakości. Różnica kinematyki trójkąta również wymaga uwzględnienia przy interpretacji porównania p95.

Fizyczny iPhone X nie był podłączony: `xcrun devicectl list devices` wykazał tylko pięć wyłączonych symulatorów (iPad Pro M5, dwa iPhone 17, iPhone 17 Pro i iPhone SE 3). Dlatego **nie ma wyniku p95 na iPhone X ani zaliczonej bramki**. Wymagane jest wykonanie Release na iPhone X i porównanie p95 z zaakceptowanym przez CEO limitem **10,4568 ms**, przy zerowych fallbackach, problemach non-finite i odczytach konturów CPU oraz osobno potwierdzonej obwiedni jakości. Build na `generic/platform=iOS` dowodzi kompilacji, nie wydajności urządzenia.
