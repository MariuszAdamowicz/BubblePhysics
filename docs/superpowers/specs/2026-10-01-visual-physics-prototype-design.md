# Wizualny prototyp fizyki baniek — projekt

## Cel

Prototyp ma umożliwić ocenę wiarygodności deformowalnych baniek na fizycznym iPhonie X. Nie jest makietą finalnej gry ani próbą ustalenia jej oprawy artystycznej. Ma pokazać deformację, wzajemny nacisk, obrót, zachowanie przy chwycie oraz oddziaływanie ruchomego obiektu sztywnego, jednocześnie mierząc wydajność pełnego kroku symulacji i renderowania.

Warunkiem akceptacji jest możliwość przeciągnięcia bańki przez skupisko i zaobserwowania czytelnego oporu oraz deformacji. Po puszczeniu układ ma wracać do stabilnego stanu bez eksplozji numerycznej, migotania i przenikania na dużą skalę. Scena 300 baniek ma działać bez overflow i wartości non-finite.

## Zakres pierwszej wersji

Prototyp udostępni dwie deterministyczne sceny:

- około 40 większych baniek do czytelnej oceny zachowania;
- 300 baniek do oceny zachowania pod obciążeniem.

Użytkownik będzie mógł przełączać scenę, zatrzymać i wznowić symulację, zresetować ją, włączyć diagnostykę oraz niezależnie zatrzymać kinematyczny trójkąt.

Poza zakresem pozostają mechanika łączenia liczb, finalne tekstury i dźwięk, system menu gry, trwałe wyniki, efekty cząsteczkowe oraz ostateczne strojenie parametrów fizyki.

## Architektura

Warstwa prezentacji zostanie zbudowana jako `MTKView` osadzony w SwiftUI. SwiftUI odpowiada wyłącznie za powłokę aplikacji, panel sterowania i telemetrię. Symulacja i rysowanie korzystają z Metal.

Sesja GPU utrzymuje bufory cząstek, zakresów baniek, ograniczeń, par kandydatów, sąsiedztwa oraz geometrii pomiędzy klatkami. Pełny krok obejmuje predykcję, broad phase, budowę sąsiedztwa, kontakty, zachowanie kształtu, granice planszy oraz interakcje z obiektami sztywnymi. Renderer odczytuje końcowe pozycje z tych samych buforów GPU bez kopiowania geometrii do CPU.

Kod prototypu zostanie podzielony na jednostki o pojedynczej odpowiedzialności:

- trwała sesja GPU zarządza cyklem życia buforów i kodowaniem klatki;
- renderer rysuje bańki, trójkąt, etykiety i diagnostykę;
- kontroler sceny tworzy warianty 40/300, resetuje stan i animuje trójkąt;
- adapter dotyku wybiera bańkę i aktualizuje ograniczenie chwytu;
- panel SwiftUI prezentuje sterowanie oraz telemetrię.

Nie zostanie dodana biblioteka 2D. SpriteKit i SwiftUI `Canvas` nie będą używane do właściwego renderowania, ponieważ wymuszałyby kopiowanie geometrii lub utrudniały bezpośrednie użycie deformowalnego modelu fizycznego.

## Renderowanie baniek

Każda bańka jest rysowana jako triangulowany wachlarz złożony z punktu centralnego i adaptacyjnej liczby punktów brzegowych `N`. Renderer nie zakłada górnego limitu `N`; korzysta z zakresów zapisanych przez silnik.

Pierwsza oprawa wykorzystuje półprzezroczyste kolorowe wypełnienie, jaśniejszy brzeg i subtelny gradient sugerujący objętość. Kolor jest deterministycznie przypisany do identyfikatora bańki i nie wpływa na fizykę. Rysowanie musi zachować faktyczny zdeformowany obrys; shader nie może zastępować go idealnym okręgiem.

Etykieta liczby znajduje się nad wypełnieniem. Jej orientację wyznacza materialna oś bańki: wektor od środka do stabilnie wybranego punktu brzegowego. Etykieta obraca się razem z bańką, lecz nie jest rozciągana przez deformację obrysu. Przy tworzeniu lub resecie sceny prototyp generuje poza pętlą klatki atlas tekstur zawierający wszystkie używane etykiety liczbowe; w trakcie renderowania korzysta wyłącznie z gotowego atlasu.

Tryb diagnostyczny pokazuje punkty brzegowe, środek, obrys, materialną oś oraz dane trójkąta. Nakładka diagnostyczna nie zmienia modelu fizycznego.

## Chwyt i dotyk

Dotknięcie wybiera najwyżej renderowaną bańkę zawierającą punkt dotyku. Punkt zaczepienia jest najbliższym fragmentem powierzchni bańki, a nie automatycznie jej środkiem.

Pozycja celu chwytu jest filtrowana w czasie, a maksymalna korekta na krok jest ograniczona. W luźnym układzie bańka podąża za palcem szybko. Pod naciskiem pozostaje za celem, deformuje się i przepycha sąsiadów, dzięki czemu opór jest widoczny. Gwałtowne przesunięcie palca nie teleportuje bańki i nie generuje nieograniczonego impulsu.

Po zakończeniu dotyku ograniczenie chwytu jest usuwane bez dodawania osobnego impulsu wynikającego z ostatniego ruchu palca.

## Kinematyczny trójkąt

Scena zawiera jeden sztywny, kinematyczny trójkąt. Nie reaguje on na nacisk baniek, ale przekazuje im ruch powierzchni wynikający z prędkości liniowej i kątowej.

Środek trójkąta porusza się po zamkniętej eliptycznej trasie przechodzącej przez centralną część planszy. Parametr trasy jest ciągły, dlatego nie występuje teleportowanie ani gwałtowna zmiana kierunku. Trójkąt jednocześnie obraca się ze stałą, niewielką prędkością. Oddzielny przełącznik zatrzymuje jego animację bez zatrzymywania baniek.

W trybie diagnostycznym widoczne są kontur, triangulacja kolizyjna i wektor prędkości trójkąta.

## Przepływ klatki

W aktywnej klatce:

1. kontroler wyznacza transformację i prędkości kinematycznego trójkąta;
2. adapter dotyku aktualizuje lub usuwa ograniczenie chwytu;
3. sesja GPU koduje jeden pełny krok fizyki;
4. renderer koduje rysowanie z końcowych buforów tej samej sesji;
5. bufor poleceń jest prezentowany przez `MTKView`;
6. telemetria jest agregowana i przekazywana do SwiftUI z niższą częstotliwością niż renderowanie.

Pauza zatrzymuje aktualizację fizyki i trójkąta, ale pozwala ponownie narysować ostatni poprawny stan. Reset tworzy deterministyczny stan wybranego wariantu sceny.

## Telemetria i obsługa błędów

Panel pokazuje FPS, p50 i p95 czasu pełnej klatki, liczbę baniek i cząstek, liczbę kandydatów oraz kontaktów, a także flagi overflow i non-finite.

Wykrycie błędu wykonania Metal, overflow lub wartości non-finite zatrzymuje symulację. Ostatni poprawny obraz pozostaje widoczny, a panel pokazuje jednoznaczną przyczynę. Prototyp nie kontynuuje symulacji z uszkodzonym stanem i nie przełącza się bezgłośnie na CPU.

## Testowanie i akceptacja

Testy automatyczne obejmują:

- generowanie indeksów wachlarza dla zmiennego `N`, w tym minimalnej poprawnej bańki;
- stabilną orientację etykiety przy obrocie i deformacji;
- wybór najwyżej renderowanej bańki oraz najbliższego punktu powierzchni;
- filtrowanie celu i ograniczenie maksymalnej korekty chwytu;
- ciągłość pozycji, prędkości i kąta kinematycznego trójkąta na zamkniętej trasie;
- przekazywanie liniowej i stycznej prędkości trójkąta bańkom;
- brak non-finite podczas długiego przebiegu obu scen;
- zachowanie adaptacyjnego `N` i poprawnych zakresów buforów po resecie;
- zatrzymanie sesji oraz czytelny stan błędu po overflow.

Weryfikacja urządzenia obejmuje build Release dla iOS 16 przez Xcode 26.6 i uruchomienie na iPhonie X. Scena 40 baniek służy przede wszystkim do oceny jakości deformacji i chwytu, a scena 300 baniek do jednoczesnej oceny zachowania oraz zapasu wydajności. Ostateczna decyzja o wiarygodności fizyki wymaga obserwacji prototypu na urządzeniu i należy do CEO.
