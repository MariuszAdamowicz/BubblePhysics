# Wielobańkowy świat radialny GPU

## Cel i powód zmiany

Rozszerzyć prototyp jednej radialnej bańki do świata, który pozwala ocenić
rzeczywistą jakość fizyki: wiele deformowalnych baniek o wyraźnie różnych
rozmiarach, granice planszy oraz ruchomy wielokąt kinematyczny. Pierwsza scena
diagnostyczna ma pokazać nacisk, lokalną deformację, przepychanie, obrót,
odzyskiwanie kształtu i zajmowanie zwolnionej przestrzeni.

Obecny prototyp ujawnił trzy ograniczenia architektury:

- bańka zachowuje początkowe osiem czujników, więc jest widocznym ośmiokątem;
- kontakt z wielokątem jest wykrywany tylko wtedy, gdy punkt czujnika leży
  wewnątrz wielokąta, przez co krawędzie mogą się przecinać bez reakcji;
- `MetalRadialSimulation` przechowuje jeden korpus i nie reprezentuje kontaktów
  bańka–bańka.

Niniejsza specyfikacja zastępuje jednoobiektowe ograniczenia prototypu, ale nie
zmienia zaakceptowanego modelu: jeden punkt masy oraz bezmasowe radialne
czujniki powierzchni dla każdej bańki.

## Kryteria sukcesu

Etap jest udany, gdy na iPhonie X scena 12–20 baniek:

- nie ujawnia wizualnie wielokątnej aproksymacji konturu przy wyłączonych
  punktach diagnostycznych;
- nie pozwala ścianie, trójkątowi ani innej bańce trwale przeniknąć przez
  kontur bez wygenerowania reakcji;
- pokazuje lokalne spłaszczenie i przesunięcie środka pod naciskiem;
- wypełnia przestrzeń zwalnianą przez poruszający się trójkąt;
- nie generuje samoistnego wirowania, skoków energii, przepełnienia ani wartości
  niefinitywnych;
- pozostaje płynna i dostarcza telemetrię niezbędną do dalszej optymalizacji.

Scena 300 baniek pozostaje następnym etapem wydajnościowym. Nie jest warunkiem
zaakceptowania jakości fizyki małej sceny kontaktowej.

## Model świata

`RadialWorldState` zawiera wiele `RadialBubbleState`. Każda bańka zachowuje
własny centralny korpus, materiał, zakres czujników, promień docelowy i parametr
maksymalnej długości segmentu. Identyfikator bańki jest stabilny przez cały czas
jej życia.

Reprezentacja GPU używa płaskich buforów:

- tablica korpusów;
- tablica opisów baniek: początek i liczba czujników, parametry materiału oraz
  identyfikator;
- wspólna tablica czujników;
- wspólna tablica punktów powierzchni;
- tablica kontaktów;
- tablice zredukowanych sił, momentów, kompresji i nacisków.

Zakresy czujników są ciągłe. Zmiana liczby czujników odbywa się na granicy
klatki przez przygotowanie nowego układu buforów i atomową zamianę aktywnego
zestawu. Brak zasobów jest jawnym błędem sesji, nie powodem cichego obniżenia
jakości.

## Adaptacyjna liczba czujników

Docelowe `N` wynika z bieżącego obwodu podzielonego przez
`maxSegmentLength`. Nie wprowadzamy arbitralnego limitu domenowego.

Remeshing ma histerezę, aby liczba próbek nie oscylowała co klatkę:

- zwiększenie `N`, gdy najdłuższy segment przekracza górny próg;
- zmniejszenie `N`, gdy wszystkie segmenty pozostają poniżej dolnego progu;
- brak więcej niż jednej przebudowy danej bańki na ustalony okres ochronny,
  chyba że grozi utrata kontaktu z powodu gwałtownego wzrostu.

Resampling zachowuje środek, pęd liniowy, orientację i moment pędu. Po kącie
materiałowym interpolowane są długości, prędkości radialne, cele i naciski.
Średnie wielkości są korygowane tak, aby remeshing nie wprowadzał widocznego
impulsu ani skoku objętości.

Początkowe osiem czujników jest dopuszczalne tylko dla bańki bliskiej punktowi.
Wraz ze wzrostem `N` musi rosnąć przed pojawieniem się widocznych rogów.

## Geometria kontaktu

Podstawową jednostką geometrii jest segment między dwoma sąsiednimi czujnikami,
a nie sam punkt czujnika.

### Ściany

Kontakt ściany powstaje dla części segmentu leżącej poza planszą. Punkt
kontaktu jest rzutowany na ścianę, a kompresja rozdzielana barycentrycznie na
oba czujniki segmentu.

### Wielokąty sztywne

Generator wykrywa oba przypadki:

1. punkt lub fragment powierzchni bańki znajduje się wewnątrz wielokąta;
2. krawędź wielokąta przecina segment konturu, nawet gdy żaden jego koniec nie
   znajduje się wewnątrz drugiego kształtu.

Dodatkowo wykrywany jest przypadek wielokąta całkowicie znajdującego się
wewnątrz dużej bańki. Kontakt wybiera stabilną normalną separacji i powierzchnię
bańki, na którą wielokąt faktycznie naciska.

### Bańka–bańka

Kontakt powstaje na podstawie przecięć segment–segment oraz zawierania konturu.
Każdy kontakt wskazuje zakres czujników obu baniek, współrzędne barycentryczne,
punkt, normalną, penetrację i względną prędkość powierzchni.

Reakcja jest symetryczna: równe i przeciwne siły trafiają do obu centralnych
mas, a lokalna kompresja do odpowiednich czujników obu powierzchni. Sumaryczny
pęd liniowy pary nie może zmieniać się bez działania ściany lub obiektu
kinematycznego.

## Broad phase

Każda bańka publikuje konserwatywny AABB wyznaczony z aktualnych punktów
powierzchni i marginesu ruchu jednej klatki. Mała scena może używać sortowania
po osi z aktywną listą; interfejs kandydatów nie może jednak zależeć od tej
konkretnej implementacji.

Broad phase zwraca deterministycznie uporządkowane pary identyfikatorów. Ściany
oraz niewielka liczba wielokątów są osobnymi źródłami kandydatów. Nie wykonujemy
pełnego testu segmentów dla każdej pary baniek.

Przed testem 300 baniek porównamy sortowanie po osi z hierarchią AABB lub
wielopoziomową siatką. Decyzję podejmiemy na podstawie telemetrii rzeczywistego
rozkładu rozmiarów.

## Rozwiązywanie kontaktów i kolejność klatki

Jedna ustalona klatka wykonuje:

1. aktualizację kinematycznych wielokątów;
2. predykcję korpusów;
3. wyznaczenie punktów powierzchni;
4. AABB i broad phase;
5. generowanie kontaktów segmentowych;
6. deterministyczną redukcję sił, momentów i nacisków;
7. kilka iteracji kontakt–sprężyna, jeśli jedna iteracja nie usuwa penetracji;
8. integrację korpusów i sprężyn radialnych;
9. kontrolę energii, wartości niefinitywnych i przepełnienia;
10. remeshing na granicy klatki;
11. ponowne zbudowanie powierzchni do renderowania.

Kontakt nie gwarantuje matematycznie zerowej penetracji w pojedynczej iteracji.
Gwarantuje jednak, że penetracja jest wykryta, maleje w kolejnych iteracjach i
nie pozwala szybko poruszającemu się wielokątowi przeskoczyć całej powierzchni.
W razie potrzeby ruch kinematyczny jest dzielony na podkroki według drogi względem
najkrótszego aktywnego segmentu.

Redukcja wyników nie może zależeć od niedeterministycznej kolejności atomików
zmiennoprzecinkowych. Kontakty są grupowane według bańki i segmentu, a następnie
redukowane w stałej kolejności albo w kontrolowanej hierarchii GPU.

## Renderowanie

Każda bańka jest renderowana z własnego zakresu uporządkowanych punktów.
Triangulacja wachlarzem od środka pozostaje poprawna, ponieważ radialny kontur
jest gwiaździsty. Renderer obsługuje wiele instancji oraz etykiet zakotwiczonych
w centralnych korpusach.

Tryb `Punkty` pokazuje czujniki i segmenty. Normalny tryb nie może eksponować
rogów dla zaakceptowanego `maxSegmentLength`. Kolor i etykieta służą wyłącznie
czytelności diagnostycznej; finalna oprawa pozostaje poza zakresem.

## Scena diagnostyczna

Nowy domyślny tryb `Radial` zawiera 12–20 baniek:

- kilka małych baniek możliwych do łatwego przesunięcia;
- kilka średnich baniek;
- co najmniej jedną dużą bańkę ściskaną przez granice planszy;
- jedną bańkę o promieniu docelowym większym niż krótszy wymiar planszy;
- poruszający się i obracający trójkąt kinematyczny.

Bańki rodzą się kolejno ze stanu ściśniętego, aby nie zaczynały od nałożonych
gotowych konturów. Rozkład pozycji jest deterministyczny, dzięki czemu zrzuty,
testy i pomiary są porównywalne.

Sterowanie zachowuje `Pauza`, `Reset`, `Punkty` i `Pauza △`. Tryby legacy `40`
i `300` pozostają dostępne do porównania, lecz nie są implementacją radialnego
świata.

## Telemetria

Nakładka raportuje co najmniej:

- FPS, p50 i p95 pełnej klatki;
- czas broad phase, generowania kontaktów, redukcji/solve, remeshingu i renderu;
- liczbę baniek, czujników, segmentów, kandydatów i kontaktów;
- maksymalną penetrację przed i po solve;
- liczbę podkroków i iteracji;
- liczbę operacji remeshingu;
- maksymalny nacisk, prędkość liniową i kątową;
- flagi overflow oraz non-finite.

## Testy

### Jednostkowe CPU

- barycentryczne rozłożenie kontaktu segmentu ze ścianą;
- krawędź trójkąta przecinająca kontur między czujnikami;
- trójkąt całkowicie wewnątrz dużej bańki;
- kontakt dwóch konturów przez przecięcie segmentów i zawieranie;
- równe i przeciwne obciążenie pary baniek;
- remeshing z histerezą i bez impulsu centralnego ciała.

### Parzystość GPU

- zgodna liczba, normalne i penetracje kontaktów CPU/GPU dla małych scen;
- deterministyczny wynik po zmianie kolejności baniek i kontaktów;
- zmiana zakresów po remeshingu bez odczytu nieaktualnego bufora;
- jawny błąd alokacji i przepełnienia.

### Integracyjne

- rosnąca bańka zwiększa `N` przed ujawnieniem widocznych rogów;
- trójkąt przez 1000 kroków nie przechodzi przez bańkę;
- dwie bańki rozdzielają się i zachowują pęd;
- miejsce zwolnione przez trójkąt zostaje zajęte przez otaczające bańki;
- duża bańka ściskana przez planszę pozostaje skończona;
- przebieg co najmniej 10 000 kroków ma ograniczoną energię i zero overflow.

## Etapy wdrożenia

1. Wielobańkowy układ stanu i buforów bez kontaktów.
2. Adaptacyjne `N` działające w sesji GPU.
3. Segmentowe kontakty ścian i wielokątów.
4. Kontakty bańka–bańka oraz konserwacja pędu.
5. Broad phase i kompletna kolejność klatki.
6. Wielobańkowy renderer, scena diagnostyczna i telemetria.
7. Test długotrwały oraz odbiór na iPhonie X.
8. Dopiero po akceptacji fizyki: profilowanie i scena 300 baniek.

Każdy etap zachowuje uruchamialne testy i kończy się osobnym commitem. Nie
przechodzimy do optymalizacji kosztem geometrii kontaktu, zanim mała scena nie
zachowuje się wiarygodnie.

## Poza zakresem

- mechanika łączenia liczb oraz dzielenia baniek;
- sterowanie dotykiem i oporny chwyt;
- finalne materiały, sprite'y, efekty, muzyka i dźwięki;
- scena 300 radialnych baniek przed akceptacją jakości małej sceny;
- dowolne obiekty 3D;
- obowiązkowa zgodność z macOS jako platformą produktu.

Interfejs świata nadal nie może blokować późniejszego wzrostu, łączenia,
dzielenia ani większych scen.
