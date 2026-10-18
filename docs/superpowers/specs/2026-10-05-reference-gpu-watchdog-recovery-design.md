# BubblePhysics — odzyskanie GPU po watchdog i równoległy runner referencyjny

## Cel

Przekształcić referencyjny backend GPU tak, aby nie wysyłał długiego, seryjnego command buffera powodującego hang na iPhonie X, zachowując atomowość klatki, semantykę CPU i stałe limity Newtona/PCG. Efektem ma być mierzalny, kwalifikowalny przebieg GPU na fizycznym iPhonie, a nie ukrywanie błędów przez fallback.

## Dowód problemu

Smoke Release z 2026-10-05, `interactive-24`, limit Newtona 4, iPhone X, iOS 16.7.16: 157 klatek Metal i 173 fallbacki. Dwa command buffery zakończyły się `kIOGPUCommandBufferCallbackErrorHang`; później 171 submissionów otrzymało `SubmissionsIgnored`. Raport jest `gpu_measurement=ineligible`, a p95 całego command buffera wynosi 275.5938 ms. To znacząco przekracza budżet 10 ms i p95 CPU 1.9065 ms dla tej sceny.

Pierwsza przyczyna `unavailable` została już usunięta w `2891909`: trzy surowe źródła shaderów są dołączane jako `.metal-source`, aby runtime mógł je kompilować z `fastMathEnabled=false` i `REFERENCE_WORLD_RUNTIME`.

## Ustalona diagnoza

`referenceAdvanceWorld` wykonuje pełny CCD, event loop, Newton, PCG, line search i post-solve w jednym wątku GPU. W `interactive-24` pętla może wywołać `wSolve` do 17 razy na klatkę. Same testowe operatory i PCG zadań 3–4 istnieją, ale produkcyjny runner ich nie używa. Nie ma dowodu nieskończonej pętli; etap powodujący hang musi zostać zidentyfikowany instrumentacją.

## Zakres

1. Dodać diagnostykę command bufferów: etykiety encoderów, pełny `NSError`, `MTLCommandBufferError`/`encoderExecutionStatus`, krok sceny i telemetrię ukończonych prób Metal.
2. Po hang, timeout, `accessRevoked` albo `SubmissionsIgnored` trwale przełączyć pozostałe klatki bieżącej sesji benchmarku na CPU. Fallback danej klatki pozostaje pełnoklatkowy i odtwarza ją z wejściowego świata.
3. Rozbić monolityczny world runner na ograniczone etapy GPU z prywatnym scratch state między command bufferami. Zastąpić seryjny Newton/PCG użyciem istniejących równoległych operatorów oraz matrix-free PCG.
4. Publikować do `ReferenceWorld` wyłącznie końcowy, w pełni zwalidowany stan; scratch, próby line-search i częściowe wyniki nie mogą wyciec do świata.
5. Utrzymać semantykę CPU: stabilne ID i last-writer collisions, prefiks grup CCD, guard strony odcinka, containment, non-finite oraz brak cichego dropu.

## Poza zakresem

- dynamiczne/adaptacyjne limity Newtona lub PCG;
- nowe parametry fizyki i zmiana scen deterministycznych;
- zmiana legacy `BubblePhysicsMetal`;
- deklarowanie sukcesu bez kwalifikowalnych danych z urządzenia;
- port macOS jako produktu.

## Architektura

Każda klatka używa krótkiej sekwencji command bufferów: przygotowanie geometrii/CCD, iteracje Newtona z równoległymi operatorami i PCG, a na końcu post-solve/kontury/render. Wszystkie trzymają stan tylko w buforach GPU. CPU czeka na ukończenie etapów, obsługuje retry po pojemności oraz na końcu czyta i waliduje komplet finalnego wyniku. Błąd dowolnego etapu unieważnia całą próbę i uruchamia CPU od niezmienionego snapshotu.

Limity dispatchu pozostają dokładnie limitami skonfigurowanymi przez scenariusz; GPU control records mogą pominąć pracę po zbieżności, lecz nie zmieniają limitu ani konfiguracji między klatkami.

## Kontrakt telemetryczny

Do benchmarku trafiają osobno: ukończone klatki Metal i ich czas command bufferów; fallbacki CPU wraz z przyczyną także podczas warmup; krok i label etapu pierwszego błędu GPU; liczba wywołań solve, w tym tentative, kontakty i grupy CCD.

Każdy fallback, także trwałe odcięcie GPU po hang, pozostawia `gpu_measurement=ineligible`. Raport nie miesza czasu zakończonego GPU z czasem CPU fallbacku przy ocenie GPU.

## Kryteria akceptacji

1. Testy deterministyczne pokrywają hang/error latch, pełnoklatkowy fallback, brak publikacji częściowego stanu oraz zgodność CPU dla collision/CCD.
2. Pełne `swift test` i unsigned Release iOS przechodzą bez nowych błędów.
3. Na iPhonie X krótki smoke `interactive-24`, limit 4, ma co najmniej jedną ukończoną klatkę Metal albo raportuje etapową przyczynę błędu bez lawiny kolejnych submissionów.
4. Bramka właściwa wymaga obu macierzy `4/8/12/16`, 30 warmup + 300 measured, bez fallbacków, `stress-300 p95 <= 10 ms` oraz jakości nie gorszej od baseline’u CPU. Niespełnienie którejkolwiek części jest wynikiem negatywnym, nie podstawą do zmiany limitów.

## Ryzyka

Rozdzielenie etapów zwiększa synchronizację i wymaga precyzyjnej własności scratch buffers. Jeżeli praca równoległa nadal nie mieści się w budżecie, dane z urządzenia będą podstawą decyzji CEO o dalszej optymalizacji albo zakończeniu ścieżki GPU; nie będzie automatycznego rozszerzania zakresu.
