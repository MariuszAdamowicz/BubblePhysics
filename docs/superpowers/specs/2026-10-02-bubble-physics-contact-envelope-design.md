# BubblePhysics — solver środków i kierunkowej deformacji

## Status i relacja do poprzedniego projektu

Dokument opisuje zatwierdzony kierunek następnej generacji biblioteki
`BubblePhysics`. Zastępuje model dynamicznego pierścienia punktów i sprężyn
opisany w `2026-09-29-bubble-physics-v1-design.md`, ale nie nakazuje jeszcze
usunięcia jego implementacji. Dotychczasowy solver pozostaje w repozytorium
wyłącznie jako materiał porównawczy do czasu zweryfikowania nowego rozwiązania.

Nowa implementacja powstaje w dwóch zgodnych etapach:

1. referencyjny, deterministyczny solver CPU w Swift;
2. backend Metal realizujący te same reguły fizyczne i sprawdzany tymi samymi
   scenariuszami.

CPU jest wzorcem poprawności i nie otrzymuje twardego wymagania czasu klatki.
Backend Metal ma osiągnąć dla pełnej klatki na iPhonie X `p95 <= 16,67 ms`
w scenie 300 baniek.

## Cel

Biblioteka ma wydajnie symulować duży, ciasno upakowany zbiór miękkich baniek o
bardzo różnych rozmiarach, włącznie z bańkami o docelowym promieniu większym
niż plansza. Bańki mogą stykać się ze sobą, ze ścianami oraz ze statycznymi i
kinematycznymi wielokątami zbudowanymi ze sztywnych odcinków.

Model ma zachowywać pozory poprawnej fizyki: nacisk rozchodzi się przez układ,
duże ściśnięcie stawia rosnący opór, szybka przeszkoda nie przechodzi przez
bańkę, a po ustaniu nacisku kontur płynnie wraca do docelowego kształtu.
Priorytetami są stabilność, przewidywalność i wydajność potrzebna grom, a nie
symulacja rzeczywistej membrany z dokładnością naukową.

## Główne uproszczenie

Fizyka położenia i wizualny kontur są osobnymi warstwami.

- Solver operuje na punktach centralnych, masach, prędkościach, docelowych
  promieniach, sztywnych odcinkach i niewielkim zbiorze kontaktów.
- Deformacja jest kierunkowym polem nacisku przypisanym bańce, a nie zbiorem
  dynamicznych punktów masowych.
- W czasie iteracji obliczany jest tylko promień powierzchni w kierunkach
  potrzebnych kontaktom.
- Pełne `N` punktów konturu powstaje jeden raz po zakończeniu solvera i służy
  rendererowi.

Nie istnieją dynamiczne promienie mające własną prędkość ani remeshing
sterowany długością niestabilnych krawędzi. Eliminuje to źródło kolców,
oscylacji i lawinowego wzrostu kosztu znane z poprzedniej implementacji.

## Model bańki

Minimalny stan fizyczny bańki obejmuje:

```text
id
center, previousCenter
velocity
mass, inverseMass
targetRadius
stiffness
linearDamping
rotation, angularVelocity
directionalDeformations
```

`targetRadius` opisuje rozmiar, do którego bańka powraca bez nacisku. Nie jest
sztywnym zakazem penetracji. Gdy na planszy nie ma miejsca, część konfliktu
zostaje rozwiązana przesunięciem środka, a część sprężystą deformacją.

Kierunkowa deformacja jest małym rekordem związanym z aktywnym kontaktem:

```text
contactID
direction
depth
angularWidth
pressure
```

Funkcja `supportRadius(angle)` zwraca aktualny promień powierzchni w wybranym
kierunku. Zaczyna od `targetRadius`, odejmuje gładkie wpływy kontaktów i
uwzględnia nieliniowy wzrost oporu przy silnym ściśnięciu. Funkcja nie tworzy
punktów graficznych i jej koszt zależy od liczby lokalnie istotnych kontaktów,
nie od docelowego `N` konturu.

Masa wpływa na przesunięcie środka. Podatność i aktualne ściśnięcie wpływają na
to, jaka część penetracji może zostać pochłonięta jako deformacja. Im większe
dotychczasowe ściśnięcie, tym większy opór wobec dalszej deformacji.

## Sztywne odcinki i wielokąty

Ściana planszy oraz każdy bok przeszkody są sztywnymi odcinkami `AB`. Odcinek
może należeć do obiektu statycznego albo kinematycznego. Nacisk baniek nigdy
nie zmienia jego ruchu.

Stan kinematyczny zachowuje poprzednie i bieżące położenie końców:

```text
id
previousA, previousB
currentA, currentB
linearVelocity
angularVelocity
ownerID
```

Najbliższy punkt odcinka względem środka bańki `P` jest wyznaczany jednym
obliczeniem:

```text
t = clamp(dot(P-A, B-A) / dot(B-A, B-A), 0...1)
Q = A + t * (B-A)
```

`Q` automatycznie pokrywa się z `A` lub `B`, gdy rzut leży poza odcinkiem.
Nie wykonuje się osobnych testów początku, końca ani środka odcinka.

Kontakt występuje, gdy odległość `P-Q` jest mniejsza od
`supportRadius(direction(P-Q))`. Dla kontaktu zapamiętywana jest dozwolona
strona odcinka. Żadna korekta innego kontaktu nie może pozostawić środka po
stronie zabronionej.

Publicznym obiektem może pozostać wielokąt, lecz narrow phase operuje na jego
zewnętrznych odcinkach. Wewnętrzne przekątne triangulacji nie są powierzchnią
kolizji.

## Kontakty bańka–bańka

Broad phase może używać docelowych promieni, aby bezpiecznie znaleźć
potencjalne pary. Dokładny test używa aktualnej powierzchni w kierunku linii
łączącej środki:

```text
direction = normalize(centerB - centerA)
penetration = supportRadiusA(direction)
            + supportRadiusB(-direction)
            - distance(centerA, centerB)
```

Dodatnia wartość oznacza aktywny kontakt. Ujemna wartość usuwa pozorny
kontakt, który zniknął wskutek deformacji jednej lub obu baniek.

Para baniek tworzy zasadniczo jeden kontakt. Nie generuje się kontaktu dla
każdego punktu konturu ani każdej pary jego krawędzi. Korekta położenia jest
dzielona według odwrotnych mas. Korekta, której nie można wykonać z powodu
sztywnych ograniczeń lub innych baniek, przechodzi w kierunkową deformację i
nacisk.

Przy coincident centers solver używa deterministycznego kierunku zastępczego
wynikającego z identyfikatorów obiektów, aby uniknąć dzielenia przez zero i
niedeterministycznego wyboru normalnej.

## Ciągłe wykrywanie zderzeń

Test stanu wyłącznie na końcu kroku jest niedopuszczalny, ponieważ zarówno
bańki, jak i odcinki mogą się poruszać.

Dla dwóch poruszających się baniek używany jest względny ruch środków i test
czasu wejścia poruszającego się punktu w okrąg o promieniu równym sumie
aktualnych promieni podparcia. Daje to równanie kwadratowe i czas pierwszego
kontaktu `TOI` w zakresie kroku.

Dla przesuwającego się bez obrotu odcinka problem jest sprowadzany do
nieruchomego środka bańki oraz poruszającej się kapsuły: prostokątnej części
odcinka pogrubionej o promień i dwóch okręgów końcowych. Wybierany jest
najwcześniejszy poprawny czas kontaktu.

Dla odcinka obracającego się używane jest conservative advancement:

1. wyznacz `Q` i aktualną odległość powierzchni;
2. oszacuj bezpieczny przyrost czasu z względnej prędkości punktu powierzchni;
3. przesuń stan próbny;
4. ponownie wyznacz `Q`;
5. zakończ po znalezieniu kontaktu, końca kroku albo małego, stałego limitu
   iteracji.

Zmiana zapamiętanej strony odcinka bez zarejestrowanego kontaktu uruchamia
awaryjną korektę środka do ostatniej dozwolonej strony oraz licznik
diagnostyczny. Jest to zabezpieczenie, a nie podstawowy mechanizm solvera.

## Rekord kontaktu i trwałość

Kontakt zawiera co najmniej:

```text
id i rodzaj
uczestnicy
normal
pointQ
penetration
timeOfImpact
allowedSide
accumulatedCompression
age
```

Kontakty są pamiętane między klatkami i używane jako rozwiązanie początkowe.
Nowy kontakt jest aktywowany po przekroczeniu małej tolerancji penetracji, a
usuwany dopiero po powstaniu nieco większej przerwy. Histereza zapobiega
naprzemiennemu dodawaniu i usuwaniu kontaktu wskutek błędów numerycznych.

## Iteracyjne znajdowanie równowagi

Solver używa sekwencyjnego rozwiązania ograniczeń pozycyjnych w stylu XPBD.
Nie sumuje najpierw wszystkich dowolnych przesunięć. Każda zastosowana korekta
jest natychmiast widoczna dla następnych ograniczeń.

Jedna iteracja ma kolejność:

1. obliczenie `supportRadius` wyłącznie dla kierunków aktywnych kontaktów;
2. potwierdzenie, aktualizacja albo usunięcie dotychczasowych kontaktów;
3. rozwiązanie ograniczeń ze sztywnymi odcinkami;
4. rozwiązanie kontaktów bańka–bańka;
5. ponowne rozwiązanie ograniczeń ze sztywnymi odcinkami;
6. aktualizacja kierunkowych deformacji i nacisków;
7. wykrycie nowych kontaktów powstałych wskutek zastosowanych korekt.

Sztywne odcinki są ograniczeniami bezwzględnymi. Przykładowo, gdy bańka jest
dociskana przez drugą bańkę do ściany, solver nie może rozwiązać konfliktu
przez przepchnięcie jej środka przez ścianę. Niedostępne przesunięcie zostaje
przeniesione na drugą bańkę albo pochłonięte jako deformacja.

Iteracje kończą się, gdy zbiór kontaktów pozostaje stabilny, największa
penetracja mieści się w tolerancji i zmiana pozycji jest mała. Niezależnie od
tego obowiązuje stały maksymalny limit, początkowo 12 iteracji. Przekroczenie
limitu nie zatrzymuje aplikacji, lecz jest widoczne w telemetrii.

## Kontur renderowany

Po zakończeniu solvera dla każdej bańki dobierane jest `N` wynikające z
aktualnego, zdeformowanego obwodu i maksymalnej dopuszczalnej długości odcinka
renderowanego konturu, a nie ze stabilności fizyki ani sztywnej tabeli
rozmiarów. Próbkowanie rozpoczyna się od małej liczby kierunków i dzieli tylko
te łuki, których odcinek przekracza limit. Nie obowiązuje górny limit `N`.
W każdym wybranym kierunku wywoływane jest `supportRadius(angle)`. Wynik może
przejść małą, stałą liczbę kroków wygładzających, które nie zmieniają stanu
fizycznego.

Pełny kontur nie uczestniczy w broad phase, CCD ani iteracjach równowagi.
Zmiana `N` wpływa na jakość i koszt renderowania, ale nie zmienia rozwiązania
fizycznego. Dzięki temu duża bańka może otrzymać więcej punktów graficznych
bez kwadratowego wzrostu kosztu kolizji.

Orientacja liczby lub tekstury pochodzi z kąta centralnego ciała. Kontur może
się deformować niezależnie od tego kąta.

## Przebieg kroku symulacji

```text
1. Zastosuj polecenia i zapamiętaj poprzednie stany.
2. Przewidź ruch środków i obiektów kinematycznych.
3. Zaktualizuj broad phase i listę potencjalnych par.
4. Wyznacz TOI dla par zagrożonych tunnelingiem.
5. Utwórz lub odśwież aktywne kontakty.
6. Iteruj solver równowagi z bezwzględnymi ograniczeniami odcinków.
7. Zakończ po zbieżności albo osiągnięciu limitu iteracji.
8. Wyznacz prędkości z różnicy pozycji i zastosuj tłumienie.
9. Wygeneruj pełne kontury renderowane.
10. Zapisz telemetrię oraz stan do renderowania.
```

Obsługa wielu zdarzeń TOI wewnątrz jednego kroku ma stały budżet. Po jego
wyczerpaniu solver zachowuje jednostronne ograniczenia odcinków i zgłasza
zdarzenie diagnostyczne, zamiast kontynuować nieograniczoną pętlę.

## Struktura pakietu

Nowy kod powstaje obok starego modelu:

```text
BubblePhysicsReference
    publiczne modele i referencyjny solver CPU

BubblePhysicsMetalNext
    backend Metal zgodny semantycznie z wersją CPU

BubblePhysicsBench
    wspólne deterministyczne scenariusze, raporty i host iOS
```

Nazwy targetów mogą zostać skrócone podczas planowania, ale rozdział
odpowiedzialności pozostaje wymaganiem. Kod CPU nie zależy od Metala ani
renderera. Scenariusze benchmarkowe dostarczają identyczny stan początkowy obu
backendom.

## Broad phase

Pierwsza wersja CPU użyje prostej struktury przestrzennej dobranej do bardzo
różnych rozmiarów baniek. Implementacja i testy nie mogą zakładać, że obiekt
zajmuje najwyżej stałą, małą liczbę komórek jednolitej siatki.

Konkretny indeks zostanie wybrany w planie implementacji po małym pomiarze
porównującym co najmniej sweep-and-prune oraz hierarchię AABB. Interfejs
broad phase zwraca uporządkowane, unikalne pary i jest wymienny bez zmiany
solvera kontaktów. Brute force pozostaje wyłącznie wyrocznią testową dla
małych scen.

## Scenariusze poprawności

Wspólne testy CPU, a później CPU–Metal, obejmują:

- dwie jednakowe bańki dzielące korektę symetrycznie;
- bańki o różnych masach;
- coincident centers;
- łańcuch baniek przekazujący nacisk pomiędzy ścianami;
- bańkę dociskaną do rogu;
- bańkę o docelowym promieniu większym niż plansza;
- pozorny kontakt znikający po uwzględnieniu kierunkowej deformacji;
- szybki przesuwający się odcinek;
- przesuwający i obracający się odcinek;
- trójkąt mieszający bańki;
- powrót deformacji po usunięciu nacisku;
- stabilność aktywnego zbioru kontaktów i histerezy;
- deterministyczne odtworzenie tej samej sekwencji.

Testy sprawdzają nie tylko wartości skończone, lecz również maksymalną
penetrację, zachowanie dozwolonej strony odcinka, zachowanie symetrii, limit
iteracji i błąd pomiędzy backendami.

## Benchmarki

Benchmark obejmuje cały krok potrzebny grze, bez renderowania pikseli:

- przewidywanie ruchu;
- aktualizację broad phase;
- CCD i TOI;
- tworzenie oraz utrzymanie kontaktów;
- wszystkie iteracje solvera;
- kierunkowe promienie używane przez kontakty;
- końcowe wygenerowanie pełnych konturów.

Raport zawiera:

```text
p50 i p95 całego kroku
czas każdej fazy
liczbę baniek i odcinków
liczbę potencjalnych par i aktywnych kontaktów
liczbę iteracji solvera
liczbę testów TOI
największą pozostałą penetrację
liczbę awaryjnych korekt strony odcinka
liczbę przekroczeń budżetu
różnicę CPU–Metal
```

Sceny mierzone osobno:

1. dwie zderzające się bańki;
2. łańcuch baniek pomiędzy ścianami;
3. szybki przesuwający się odcinek;
4. obracający się odcinek;
5. trójkąt mieszający bańki;
6. jedna wielka, mocno ściśnięta bańka;
7. szczelna mieszanka bardzo różnych rozmiarów;
8. pełne plansze 40, 300 i 1000 baniek.

CPU służy jako pomiar informacyjny i wzorzec. Kryterium backendu Metal na
fizycznym iPhonie X wynosi dla sceny 300 baniek `p95 <= 16,67 ms` dla całego
kroku wymienionego powyżej, bez `NaN`, zmiany zabronionej strony odcinka,
przepełnienia buforów ani nieograniczonego wzrostu pamięci.

## Granice zakresu pierwszej implementacji

Pierwsza implementacja obejmuje środki baniek, masy, prędkości, tłumienie,
kierunkową deformację, ściany, statyczne i kinematyczne odcinki, wielokąt jako
zbiór odcinków, CCD, aktywny zbiór kontaktów, solver równowagi, generowanie
konturów oraz benchmark.

Łączenie, dzielenie, chwyt, siły użytkownika, pełny renderer gry, grafika,
audio i reguły `2KBubbles` pozostają poza pierwszym kamieniem milowym. Model
danych nie może ich uniemożliwiać, ale nie będą implementowane przed
potwierdzeniem poprawności i kosztu podstawowego solvera.

## Decyzje zatwierdzone przez CEO

- nowy solver powstaje jako biblioteka i jest najpierw oceniany benchmarkiem;
- CPU jest referencją poprawności, a Metal drugim, zgodnym backendem;
- fizyka używa centralnego punktu masy i docelowego promienia;
- sztywne granice są odcinkami, a najbliższy punkt kontaktu to pojedyncze
  `Q`, które może pokryć się z końcem odcinka;
- wykrywanie uwzględnia ruch bańki i odcinka oraz czas pierwszego kontaktu;
- równowaga, aktywne kontakty i kierunkowe deformacje są aktualizowane
  iteracyjnie;
- pełny kontur nie jest liczony w pętli solvera;
- sztywne odcinki są bezwzględnymi ograniczeniami i nie mogą zostać naruszone
  przez korekty kontaktów bańka–bańka;
- pełna klatka Metal dla 300 baniek na iPhonie X ma osiągnąć
  `p95 <= 16,67 ms`.
