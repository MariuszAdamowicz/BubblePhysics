# Projekt fizyki deformowalnych konturów

## Cel

Zastąpić prototypowy model kontaktów zastępczych okręgów modelem, w którym zachowanie bańki wynika z jej punktów, nieliniowych sprężyn i rzeczywistego konturu. Silnik ma pokazywać wiarygodne ściskanie, magazynowanie energii, rozprężanie i przepływ naprężeń dla co najmniej 300 baniek na iPhonie X.

Pole bańki nie jest ograniczeniem solvera. Może dowolnie maleć pod odpowiednio dużą siłą. Koszt dalszej kompresji rośnie przez nieliniową charakterystykę sprężyn, a po zwolnieniu nacisku zgromadzona energia przywraca kształt i przemieszcza otoczenie.

## Ustalenia fizyczne

Każda bańka składa się z punktu centralnego i adaptacyjnego, uporządkowanego pierścienia punktów brzegowych. Materiał tworzą trzy rodziny sprężyn:

- promieniowe: środek–brzeg;
- obwodowe: sąsiednie punkty pierścienia;
- stabilizujące zginanie: dalsi sąsiedzi pierścienia.

Sprężyny używają energii `E(ΔL) = 1/2 k₂ ΔL² + 1/4 k₄ ΔL⁴`, a więc siły `F = -(k₂ ΔL + k₄ ΔL³)`. Składnik sześcienny zapewnia progresywny wzrost oporu zarówno przy ściskaniu, jak i rozciąganiu. Nie wolno wprowadzać minimalnego pola, minimalnego promienia ani projekcji bezpośrednio przywracającej pole spoczynkowe. Współczynniki `k₂`, `k₄` oraz `drag` są jawnymi parametrami materiału i podlegają strojeniu na urządzeniu, lecz ich integracja jest niezależna od liczby FPS.

Ruch wszystkich cząstek podlega łagodnemu tłumieniu wykładniczemu:

`v = v * exp(-drag * dt)`

Tłumienie powoduje stopniowe zwalnianie swobodnej bańki i sprawia, że przepchnięcie skupiska wymaga pokonania oporu ruchu wszystkich poruszonych mas. Nie zastępuje ono kontaktu ani sprężystości.

## Kontakty rzeczywistych konturów

Broad phase wykorzystuje AABB obliczone z aktualnych punktów zdeformowanego konturu. Pole spoczynkowe i promień zastępczy nie uczestniczą w odrzucaniu ani rozwiązywaniu kontaktu.

Dla każdej pary kandydatów narrow phase wykrywa:

- penetrację punkt–odcinek w obu kierunkach;
- przecięcia odcinków, również gdy żaden wierzchołek nie znalazł się jeszcze wewnątrz drugiego konturu;
- samokolizję niesąsiadujących fragmentów jednego konturu.

Ograniczenie kontaktowe rozdziela korektę na punkt oraz dwa końce odcinka zgodnie z masami odwrotnymi i współrzędną barycentryczną. Kontakty bańka–bańka zachowują równą i przeciwną reakcję. Granice planszy oraz wielokąty sztywne korzystają z tego samego modelu punkt–odcinek. Ruchomy wielokąt przekazuje cząstkom swoją prędkość liniową i styczną.

GPU generuje rekordy kontaktów do deterministycznych zakresów przypisanych parom i cechom. Korekty są sortowane według indeksu cząstki oraz stabilnego identyfikatora źródła, następnie redukowane i stosowane bez wyścigów zapisu. Nie wolno wracać do odsuwania samych środków baniek.

## Adaptacyjna topologia

Liczba punktów `N` zależy od lokalnej długości aktualnego konturu, a nie od dyskretnej tabeli rozmiarów:

- odcinek trwale dłuższy niż próg dzielenia otrzymuje punkt pośredni;
- dwa trwale krótkie odcinki mogą zostać scalone przez usunięcie wspólnego punktu;
- różne progi dodawania i usuwania, licznik trwałości oraz okres ochronny zapobiegają oscylacji topologii;
- minimalne `N` wynosi 8, aby zachować nieosobliwy kontur i sensowny chwyt, ale nie istnieje maksymalne `N` modelu.

Każdy odcinek przechowuje długość materialną w stanie spoczynkowym. Przy podziale długość ta jest dzielona, a przy scaleniu sumowana. Nowy punkt otrzymuje interpolowaną pozycję i prędkość. Remeshing nie może przyjąć skompresowanego kształtu jako nowego kształtu spoczynkowego ani skasować energii sprężystej.

Remeshing wykonywany jest na GPU jako rzadszy etap: oznaczenie zmian, prefix sum, kompaktowanie punktów i odbudowa zakresów sprężyn. Jeżeli bieżąca pojemność buforów jest niewystarczająca, operacja nie może zostać zastosowana częściowo. Sesja zwiększa pojemność i ponawia ją w kolejnej bezpiecznej granicy klatki.

## Stabilizacja orientacji etykiet

Orientacja etykiety wynika z filtrowanej osi materialnej obliczonej z kilku punktów konturu, nie z chwilowego kierunku jednego punktu. Kąt jest rozwijany bez skoku przy `-π/π`, a prędkość kątowa podlega tłumieniu. Deformacja promieniowa nie skaluje napisu. Rzeczywisty, płynny obrót bańki pozostaje widoczny, lecz chwilowe lokalne odkształcenie nie może powodować nagłego wirowania etykiety.

## Mapowanie obrazu

Świat prototypu ma jawne granice `375 × 812` punktów. Shadery renderujące otrzymują te granice niezależnie od rozdzielczości drawable w pikselach. Viewport zachowuje proporcje świata; na iPhonie X plansza wypełnia ekran. Rozdzielczość ekranu nie może zmieniać skali fizyki.

## Sceny weryfikacyjne

Wartość bańki jest proporcjonalna do jej pola spoczynkowego. Dla wartości `v` pole wynosi `A₂ * v / 2`. Wymiar liniowy rośnie więc jak `sqrt(v / 2)`. Przy promieniu bańki `2` około 14 punktów bańka `2048` ma promień spoczynkowy około 448 punktów i jest większa niż szerokość planszy.

Scena 40 zawiera wartości w licznościach: `2×20`, `4×8`, `8×5`, `16×3`, `32×2`, `64×1`, `512×1`. Zapewnia czytelny przekrój skal oraz przestrzeń do testu ruchu swobodnego, kontaktu, ściskania w rogu i rozprężania.

Scena 300 zawiera: `2×163`, `4×64`, `8×32`, `16×16`, `32×8`, `64×6`, `128×4`, `256×3`, `512×2`, `1024×1`, `2048×1`. Jest celowo przepełniona, aby duże i małe kontury pozostawały w jednoczesnym kontakcie.

Po przejściu trójkąta powstała przestrzeń ma być zajmowana przez rozprężające się i przemieszczające bańki. Nie jest wymagane natychmiastowe matematyczne wypełnienie, lecz trwała pusta kieszeń oznacza błąd modelu lub zbyt silne tłumienie.

## Telemetria i błędy

Telemetria rozdziela broad phase, narrow phase, sprężyny, remeshing, wielokąty i rendering. Raportuje liczbę punktów, segmentów, par kandydatów, kontaktów, operacji remeshingu, p50/p95, overflow i non-finite.

Overflow pojemności jest sygnałem do bezpiecznego wzrostu bufora, nie do obcięcia kontaktów lub punktów. Non-finite zatrzymuje sesję i zachowuje ostatnią poprawną klatkę. Nie stosujemy cichego fallbacku CPU.

## Weryfikacja

Testy automatyczne muszą objąć:

- monotoniczny wzrost oporu sprężyny przy rosnącej kompresji;
- możliwość wielokrotnego zmniejszenia pola bez twardego limitu;
- zachowanie długości materialnych, prędkości i energii w tolerancji remeshingu;
- kontakty punkt–odcinek, przecięcia odcinków i samokolizję;
- zachowanie reakcji pary kontaktowej;
- wielką bańkę ściśniętą przez ekran i sąsiadujące małe bańki;
- zamykanie przestrzeni pozostawionej przez ruchomy trójkąt;
- stabilną orientację etykiet;
- poprawne mapowanie planszy na drawable;
- długi przebieg bez non-finite i bez utraconych kontaktów.

Test na iPhonie X jest bramą jakościową. Najpierw oceniana jest scena 40: swobodny i gwałtowny chwyt, opór skupiska, deformacja, powrót, etykiety, trójkąt i diagnostyka. Następnie scena 300 ocenia mieszaninę skal oraz wydajność. Celem końcowym jest p95 pełnej klatki nie większe niż 16,67 ms, ale wiarygodność zachowania ma pierwszeństwo przed optymalizacją.

## Poza zakresem tej przebudowy

- mechanika łączenia liczb i reguły pełnej gry 2KBubbles;
- oprawa finalna, muzyka i monetyzacja;
- dokładne tarcie powierzchniowe i lepkość między błonami, o ile test urządzenia nie wykaże ich konieczności;
- obsługa macOS jako platformy produktowej.
