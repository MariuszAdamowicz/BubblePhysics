# BubblePhysics — publiczne API v1

## Status i cel

Ten dokument definiuje zatwierdzony publiczny kontrakt API v1 dla wielokrotnego użytku biblioteki fizyki deformowalnych baniek 2D dla iOS 16+ i macOS 13+. Nie jest planem implementacji ani kontraktem wewnętrznego solvera.

Biblioteka ma pozwalać zbudować szybką grę mobilną — w tym `2KBubbles` — bez wyboru CPU/GPU, znajomości buforów Metal, cache kontaktów ani parametrów XPBD/PBD. GPU-native jest ścieżką produkcyjną; CPU reference pozostaje ukrytym narzędziem jakości i fallbackiem kompletnej klatki.

Publiczna architektura ma formę jednego świata, atomowych transakcji i wyniku klatki:

```text
BubbleWorld + WorldTransaction -> advance(by:) -> WorldFrame
```

## Zasady kontraktu

- Gra opisuje świat przez obiekty, zasoby, komendy i zdarzenia; solver jest hermetyczny.
- Wszystkie zmiany świata są zatwierdzane atomowo na granicy stałego kroku symulacji.
- Gra nie wybiera backendu CPU/GPU i nie przełącza go zależnie od liczby baniek.
- Parametry jakości solvera, cache, iteracje, encodery i bufory GPU nie należą do API gry.
- Renderowanie Metal jest zintegrowaną, bezpośrednią ścieżką GPU; CPU snapshot jest opcjonalnym adapterem/debugiem.
- Błędy konfiguracji i limity są jawnie raportowane. Biblioteka nie maskuje ich częściową publikacją świata ani ukrytym obniżeniem jakości.

## Świat i przestrzeń

`BubbleWorld` przechowuje obiekty, materiały, style, harmonogram przejść, kolejkę transakcji oraz runtime symulacji i renderowania.

`WorldConfiguration` zawiera obowiązkowy `simulationRegion`. Jest to skończony prostokątny obszar obliczeniowy dla broad phase i pojemności GPU, a nie fizyczna granica. Granice gry tworzy się zwykłymi statycznymi wielobokami.

Każdy obiekt ma politykę wyjścia z regionu:

- `remove` — po całkowitym wyjściu collidera obiekt jest usuwany;
- `wrap` — po całkowitym wyjściu collider jest translacyjnie przenoszony na przeciwległą stronę, z zachowaniem prędkości i stanu ruchu.

`wrap` v1 nie tworzy toroidalnych kolizji przez szew regionu. Statyczna geometria poza `simulationRegion` jest błędem walidacji.

`Viewport` jest niezależną od fizyki, osiowo ustawioną kamerą z centrum i rozmiarem/zoomem, bez obrotu. Tłumaczy współrzędne ekranowe na współrzędne świata i odwrotnie; nie usuwa obiektów, nie ogranicza symulacji i nie zmienia kolizji.

## Obiekty

Każdy obiekt ma trwały `ObjectID`, `RenderStyleID`, zainteresowania zdarzeniami oraz lokalne parametry prezentacyjne. Geometria i ruch określają zachowanie fizyczne.

### Bubble

`Bubble` jest podstawowym obiektem deformowalnym. Ma indywidualne właściwości takie jak docelowy promień, masa, pozycja i prędkość oraz odwołuje się do `PhysicsMaterialID` zgodnego z bańką.

Bańka może przechodzić płynnie między stanem miękkim a sztywnym kołem. Przy rozpoczęciu `playerDriven` miękka bańka może zostać usztywniona do koła o efektywnym promieniu wynikającym z aktualnego ściśnięcia. Kontur relaksuje się przez kilka kroków, aby uniknąć skoku wizualnego. Po zwolnieniu może wrócić do miękkiego zachowania.

### PolygonObject

`PolygonObject` jest prostym, zamkniętym wielobokiem bez dziur i bez samoprzecięć. API przyjmuje dowolną poprawną listę wierzchołków, także wielobok wklęsły; biblioteka waliduje go i może dekomponować wewnętrznie, nie ujawniając tej reprezentacji grze.

Wielokąt może być statyczny, sterowany albo fizycznie dynamiczny. Dynamiczny i `motorDriven` wielokąt posiada masę, moment bezwładności, prędkość liniową i kątową; kolizje mogą zmieniać jego pozycję oraz obrót.

### ForceFieldObject

`ForceFieldObject` jest niekolizyjnym obiektem o geometrii zasięgu. Działa na filtrowane obiekty `dynamic` i `motorDriven`. V1 obejmuje pola:

- kierunkowe;
- radialne, przyciągające lub odpychające;
- wirowe.

Pole ma parametry siły oraz zaniku z odległości. Nie przyjmuje dowolnych closure/funkcji wykonywanych przez grę.

### SensorObject

`SensorObject` jest niekolizyjnym obiektem o geometrii zasięgu i filtrze obserwowanych obiektów. Publikuje `enteredSensor` i `exitedSensor`, gdy odpowiednie zainteresowanie zdarzeniami jest włączone. Nie publikuje zdarzenia w każdej klatce przebywania obiektu w strefie.

### Role ruchu

Fizyczne obiekty używają jednej z ról ruchu:

- `static` — nie reaguje ruchem na siły ani kontakty;
- `dynamic` — porusza się wyłącznie pod wpływem sił i kontaktów;
- `motorDriven` — jest dynamiczny, ale otrzymuje dodatkowy napęd/cel od gry i nadal może zostać spowolniony, przesunięty albo obrócony przez fizykę;
- `pathDriven` — realizuje ruch gry po ścieżce, lecz zatrzymuje się przy nierozwiązywalnej blokadzie;
- `playerDriven` — dąży do celu przekazanego przez gracza i podlega regułom kolizyjnym świata.

`pathDriven` ani `playerDriven` nie oznaczają teleportacji. W szczególności obiekt prowadzony po ścieżce nigdy nie łamie fizyki: przy blokadzie zatrzymuje się i publikuje feedback/zdarzenie, gdy jest obserwowany.

## Materiały, style i parametry

Fizyka i renderowanie używają niezależnych współdzielonych zasobów:

```text
PhysicsMaterialID -> właściwości fizyczne
RenderStyleID     -> shader, zasoby i bazowe kanały wizualne
```

Biblioteka pozwala tworzyć i rejestrować materiały, ale nie dostarcza nazwanych presetów gameplayowych ani estetycznych. Zasób materiału jest aktualizowalny; zmiana wpływa od kompletnej następnej klatki na wszystkie zgodne obiekty, które wskazują ten sam identyfikator. Masa i docelowy promień są indywidualnymi własnościami bańki, nie współdzielonego materiału.

Parametry fizyczne są pojęciami domeny fizyki, np. deformowalność, tłumienie i tarcie; publiczny kontrakt nie eksponuje compliance solvera, cache ani liczby iteracji.

`RenderStyle` definiuje shader i bazowe kanały prezentacyjne. Obiekt może posiadać lokalne kanały prezentacyjne, np. `selectionHighlight` lub `saturation`. Lokalna wartość o tym samym `ParameterID` zawsze zastępuje wartość stylu. Bardziej złożone łączenie kanałów należy do shaderu/renderera gry.

## Przejścia parametrów

Biblioteka zapewnia deterministyczny w czasie symulacji mechanizm przejść parametrów. Przejście ma cel, wartość docelową, czas trwania i serializowalną krzywą (`linear`, easing lub cubic Bézier). Nowsze przejście tego samego parametru zastępuje poprzednie.

Przejścia obejmują:

- parametry fizyczne materiałów;
- parametry świata, w tym stałą siłę świata;
- kanały `RenderStyle`;
- lokalne kanały prezentacyjne obiektu;
- indywidualny docelowy promień bańki.

Ruch po ścieżce, player drive i napęd nie są przejściami parametrów; mają własną semantykę kontrolera ruchu.

## Transakcje i czas

Gra buduje `WorldTransaction` i przekazuje ją do świata. W jednej transakcji może tworzyć, usuwać i zastępować obiekty; zmieniać materiały/style; ustawiać ruch; rozpoczynać, aktualizować i kończyć player drive; przekazywać impulsy; zmieniać siłę świata; uruchamiać przejścia parametrów oraz wykonywać operacje strukturalne.

Transakcja jest walidowana i stosowana w całości na granicy kroku albo odrzucana bez częściowej zmiany świata. Kolejność zatwierdzonych transakcji jest deterministyczna.

Podstawowym wejściem czasu jest `advance(by:)`. Gra przekazuje czas od renderera, a biblioteka utrzymuje stały krok fizyki i akumulator. Przy trwałym zaleganiu czasu biblioteka raportuje diagnostykę; nie redukuje potajemnie jakości solvera.

## Sterowanie, siły i feedback

Gra tłumaczy dotyk ekranu przez `Viewport` i przekazuje wyłącznie cel w przestrzeni świata. Typowy cykl to `beginPlayerDrive`, aktualizacje celu i `endPlayerDrive`.

V1 obsługuje:

- bezpośrednie player drive;
- jednorazowe impulsy;
- stałą siłę świata, np. grawitację albo wiatr;
- lokalne `ForceFieldObject`.

Stała siła świata i pola lokalne domyślnie działają wyłącznie na `dynamic` i `motorDriven`. `static`, `pathDriven` i aktywnie `playerDriven` je ignorują.

`DriveFeedback` jest ciągłą częścią `WorldFrame` wyłącznie dla aktywnych drive. Zawiera cel, osiągniętą pozycję/punkt, odchylenie oraz ewentualny kontakt blokujący. Gra może użyć go do renderowania linku dotyku, haptyki albo własnej akumulacji „napięcia kruszącego”. Biblioteka nie przechowuje ani nie interpretuje takiej miary gameplayowej.

## Operacje strukturalne

Gra zawsze decyduje, czy i kiedy następuje merge, split lub kruszenie.

### Merge i split baniek

Merge/split baniek są jednak semantycznymi operacjami silnika, a nie ogólnym `replace`:

- dla splitu gra przekazuje udziały docelowego rozmiaru oraz materiały/style wynikowych baniek; silnik tworzy dwie bańki w miejscu źródła z przejściową geometrią rozdzielanego kształtu, dobiera fizycznie poprawne pozycje i prędkości oraz pozwala solverowi naturalnie je rozdzielić;
- dla merge gra wskazuje źródłowe bańki i właściwości wyniku; silnik tworzy wynik w rejonie ich styku, inicjuje płynne przybliżenie unii konturów, przenosi stan fizyczny i relaksuje nowy kontur;
- w obu przypadkach silnik atomowo aktualizuje stan świata i unieważnia wyłącznie właściwe cache kontaktów.

Gra nie implementuje samodzielnie początkowego konturu, zapobiegania containment ani transferu pędu dla baniek.

### Wieloboki

Split/merge wieloboków są atomową zamianą geometrii. Gra dostarcza wynikową geometrię i atrybuty; silnik waliduje obiekty, zastępuje je na granicy kroku i przebudowuje konieczny stan kolizji. Silnik nie określa linii pęknięcia ani nie tworzy odłamków proceduralnie.

## Zdarzenia i filtry

Zdarzenia nie są globalnym strumieniem wszystkich kontaktów. Każdy obiekt ma `EventInterest`; domyślnie jest pusty. GPU filtruje i kompaktuje wyłącznie żądane rekordy przed ich publikacją do `WorldFrame`.

V1 obejmuje co najmniej:

- `mergeContact`;
- `driveBlocked`;
- `enteredSensor` i `exitedSensor`;
- `didExitSimulationRegion` i `didWrap`;
- potwierdzenia dodania, usunięcia i zastąpienia obiektów;
- wynik odrzucenia niepoprawnej transakcji/komendy.

`mergeContact` wymaga zainteresowania zdarzeniem oraz kompatybilności `MergeGroupSet`. Jest to 64-bitowa maska zarządzana przez grę; para jest kandydatem wyłącznie wtedy, gdy maski obu baniek mają co najmniej jeden wspólny bit. Biblioteka nie podejmuje automatycznej decyzji o merge.

Pojemność bufora zdarzeń jest jawna. Overflow jest raportowany w `WorldFrame` i diagnostyce; nie wolno go ukrywać.

## Renderowanie

`BubblePhysicsMetalRender` jest standardową ścieżką wydajnościową. Współdzieli niepubliczne dane GPU ze światem i koduje fizykę, kontury oraz renderowanie we właściwej kolejności do command bufferu aplikacji. Typowa ścieżka nie wykonuje transferu konturów GPU → CPU → GPU.

Renderer przyjmuje `Viewport`, render target/pass aplikacji oraz style gry. Biblioteka zawiera prosty styl techniczny do preview/debugu i pozwala grze dostarczyć własny shader/pipeline interpretujący kanały prezentacyjne.

Snapshot CPU stanu/konturów może być udostępniony adapterom SwiftUI, SpriteKit i rendererom CPU, ale nie jest ścieżką wydajnościową dla docelowej skali.

## Jawnie poza zakresem v1

- wieloboki z dziurami;
- kolizje toroidalne przez szew `simulationRegion`;
- snapshoty, save/load i replay;
- dowolne closure jako pola sił;
- publiczne API solvera, constraints, cache kontaktów, buforów Metal i wewnętrznych parametrów jakości.

## Kryteria jakości API

- Kod gry nie zawiera rozgałęzień CPU/GPU.
- Najprostsza gra mobilna może stworzyć świat, obiekty, materiały/style, przesłać transakcję, wywołać `advance(by:)` i wyrenderować wynik Metal bez readbacku.
- Rozszerzenia gry odbywają się przez obiekty, transakcje, materiały, style, pola, sensory i zdarzenia, nie przez dostęp do solvera.
- Kontrakt może rosnąć bez łamania istniejących nazw i semantyki; szczegóły implementacji CPU/GPU mogą zmieniać się wewnętrznie.
