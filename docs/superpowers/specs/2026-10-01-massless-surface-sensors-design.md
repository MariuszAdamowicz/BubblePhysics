# Model baniek z bezmasowymi czujnikami powierzchni

## Cel

Zastąpić obecny model, w którym wszystkie punkty konturu są niezależnymi
cząstkami masowymi, modelem stabilnej deformowalnej bańki. Bańka ma zachowywać
się jak jedno ciało, lokalnie uginać się pod naciskiem, przenosić nacisk na ruch
całości, obracać się i odzyskiwać kształt po ustaniu obciążenia.

Pierwszym kryterium sukcesu nie jest maksymalna wydajność ani scena 300 baniek,
lecz wiarygodne zachowanie jednej bańki pod naciskiem ścian i kinematycznego
wielokąta. Kontakty wielu baniek i test 300 obiektów zostaną dołączone dopiero
po potwierdzeniu poprawności pojedynczej bańki.

## Wnioski ze starego 2KBubbles

Stary `Mover` przechowywał jeden środek masy (`x`, `y`), prędkość (`vx`, `vy`)
i masę. Kolizje generowały siły działające na środek. Promień był osobnym stanem
sprężystym, a nowa bańka zaczynała od promienia równego zero i rosła do promienia
docelowego. Wizualne ściśnięcie nie rozdzielało bańki na niezależne masy.

Nowy model zachowuje tę sprawdzoną zasadę, ale zastępuje pojedynczy promień
uporządkowanym polem promieni, aby umożliwić deformację lokalną.

## Model stanu

### Ciało bańki

Każda bańka posiada dokładnie jeden stan masowy:

- pozycję środka masy;
- poprzednią pozycję lub prędkość liniową;
- masę i odwrotność masy;
- orientację materiałową;
- prędkość kątową;
- moment bezwładności;
- docelowy rozmiar wynikający z wartości bańki;
- postęp narodzin lub zmiany rozmiaru.

Translacja i obrót są całkowicie wyznaczane przez ten stan. Punkty powierzchni
nie mogą niezależnie przesunąć bańki.

### Czujniki powierzchni

Powierzchnia jest uporządkowanym, cyklicznym zbiorem czujników. Każdy czujnik
przechowuje:

- stały kąt materiałowy w lokalnym układzie bańki;
- bieżącą długość radialną;
- bieżącą prędkość zmiany długości albo równoważny stan tłumienia;
- docelową długość radialną;
- chwilowy nacisk kontaktowy;
- parametry sprężystości i tłumienia, domyślnie dziedziczone z materiału bańki.

Czujnik nie ma masy, pozycji świata ani niezależnej prędkości liniowej. Jego
pozycja świata jest zawsze obliczana jako:

`środek + kierunek(orientacja + kąt materiałowy) * długość radialna`.

Długość radialna nie może być ujemna. Dzięki stałej kolejności kątów kontur nie
może odwrócić orientacji ani sam się przeciąć.

## Dynamika powierzchni

Każdy czujnik jest nieliniową sprężyną radialną. Przy braku kontaktu wraca do
długości docelowej. Przy nacisku jego długość maleje. Opór powinien rosnąć
nieliniowo wraz ze zbliżaniem się długości do zera, ale model nie wprowadza
dodatniego minimalnego promienia: dostatecznie duża siła może teoretycznie
ścisnąć fragment bańki niemal do środka.

Sąsiednie czujniki wymieniają część naprężenia przez lokalny operator
wygładzający. Jego rolą jest rozprowadzanie nacisku po membranie i eliminacja
ostrych zębów, a nie zachowywanie pola powierzchni. Pole bańki może swobodnie
maleć pod naciskiem.

Aktualizacja radialna musi być stabilna dla skrajnego ściśnięcia. Powinna używać
ustalonego kroku czasu, jawnego ograniczenia energii numerycznej oraz tłumienia.
Nie wolno rozwiązywać sprężyn w kolejności, która uzależnia wynik od numeracji
czujników.

## Kontakty i ruch środka masy

Kolizja jest wykrywana pomiędzy odcinkami konturu a inną bańką, ścianą lub
wielokątem sztywnym. Każdy kontakt dostarcza:

- punkt kontaktu;
- normalną;
- głębokość penetracji;
- względną prędkość powierzchni;
- identyfikator czujnika lub interpolację pomiędzy dwoma czujnikami.

Reakcja kontaktowa ma dwa skutki:

1. lokalnie ściska odpowiednie czujniki powierzchni;
2. generuje impuls albo siłę przyłożoną do centralnej masy.

Wszystkie siły kontaktowe są sumowane przed aktualizacją centralnej masy.
Siła przesuwa środek, a iloczyn ramienia i siły generuje moment obrotowy.
Niesymetryczny nacisk może więc obrócić bańkę, natomiast symetryczne ściśnięcie
nie powinno tworzyć sztucznego obrotu.

Kontakt nie zapisuje dowolnego przesunięcia punktu konturu. Zmienia radialny stan
powierzchni i stan centralnego ciała, zachowując integralność bańki.

## Narodziny, wzrost, łączenie i dzielenie

Nowa bańka powstaje z długościami radialnymi równymi lub bardzo bliskimi zeru.
Jej docelowe długości rosną w kontrolowanym czasie do wartości wynikającej z
rozmiaru. Wzrost podlega tym samym kontaktom i oporom co pozostała symulacja,
więc bańka od początku rozpycha otoczenie, ale nigdy nie pojawia się jako gotowy
okrąg nachodzący na inne obiekty.

Zmiana rozmiaru modyfikuje docelowe długości sprężyn, nie skaluje natychmiast
geometrii. Łączenie tworzy nową bańkę w stanie ściśniętym, z zachowanym pędem
liniowym i momentem pędu wejść. Dzielenie tworzy ściśnięte obiekty potomne z
kontrolowanym rozdzieleniem. Szczegółowa kinetyka łączenia i dzielenia nie należy
do pierwszego etapu implementacji, lecz interfejs stanu nie może jej blokować.

## Adaptacyjna liczba czujników

Liczba `N` wynika z aktualnego obwodu i maksymalnej dopuszczalnej odległości
między próbkami. Nie ma arbitralnego górnego limitu `N` w modelu domenowym.
Implementacja może zgłosić brak zasobów zamiast bezgłośnie pogarszać jakość.

Zmiana `N` zachodzi wyłącznie na granicy klatki. Stan radialny, jego prędkość i
nacisk są resamplowane okresowo po kącie materiałowym. Dodanie lub usunięcie
czujnika nie może zmienić środka masy, pędu, orientacji ani całkowitej energii w
sposób widoczny dla gracza.

Podczas narodzin można używać małego `N`, ponieważ bieżący obwód jest mały.
Wraz ze wzrostem bańki pojawiają się kolejne czujniki.

## GPU i układ obliczeń

Stan centralny i radialny są przechowywane w buforach GPU. Jedna klatka składa
się logicznie z następujących faz:

1. predykcja pozycji i orientacji centralnych mas;
2. wyznaczenie pozycji czujników z aktualnego stanu radialnego;
3. broad phase obiektów;
4. generowanie kontaktów konturów, ścian i wielokątów;
5. deterministyczna redukcja nacisków, sił i momentów;
6. aktualizacja centralnych mas;
7. równoległa aktualizacja sprężyn radialnych i wygładzenie sąsiedzkie;
8. ewentualny remeshing na granicy klatki;
9. ponowne wyznaczenie pozycji konturu do renderowania.

Fazy redukcji nie mogą zależeć od kolejności atomowych zapisów zmiennoprzecinkowych.
Jeżeli używane są atomiki stałoprzecinkowe, zakres i skalowanie muszą mieć testy
przepełnienia.

## Renderowanie

Renderer otrzymuje zawsze uporządkowany kontur. W pierwszym prototypie wnętrze
może być triangulowane wachlarzem od środka, ponieważ dodatnie promienie i stała
kolejność kątowa gwarantują kształt gwiaździsty względem środka.

Etykieta liczby jest zakotwiczona w centralnej masie i obraca się zgodnie z
orientacją bańki. Jej skala może zależeć od średniej lub lokalnie dostępnej
średnicy, ale nie od pojedynczego skrajnie ściśniętego czujnika.

## Etapy walidacji

### Etap 1: jedna bańka

- narodziny od niemal zerowego promienia;
- swobodne rozprężenie bez obrotu i bez utraty symetrii;
- ściskanie przez każdą krawędź planszy;
- przyszpilenie w rogu przez kinematyczny wielokąt;
- powrót po zwolnieniu nacisku;
- niesymetryczny nacisk generujący przewidywalny obrót;
- brak samoprzecięć z definicji modelu;
- stabilność długiego przebiegu i brak wartości niefinitywnych.

### Etap 2: mała scena kontaktowa

- dwie bańki o podobnym rozmiarze;
- mała bańka naciskająca dużą;
- duża bańka przeciskająca kilka małych;
- wypełnianie miejsca zwolnionego przez ruchomy wielokąt;
- brak sztucznego wirowania i skoków energii.

### Etap 3: scena docelowa

- 40 zróżnicowanych baniek do oceny wizualnej;
- 300 baniek na iPhonie X;
- pomiary p50, p95, liczby czujników, par i kontaktów;
- test dużej bańki o rozmiarze docelowym większym od planszy;
- test długotrwałego maksymalnego ściśnięcia.

## Kryteria akceptacji pierwszego prototypu

Pierwszy prototyp jest zaakceptowany, gdy jedna bańka:

- pozostaje jednym spójnym ciałem;
- rośnie od środka bez natychmiastowego nachodzenia na scenę;
- widocznie i lokalnie deformuje się pod naciskiem;
- przesuwa środek zgodnie z sumą nacisków;
- obraca się tylko pod wpływem niezerowego momentu;
- odzyskuje kształt bez gwałtownych oscylacji;
- może zostać silnie ściśnięta bez błędu numerycznego;
- zachowuje się tak samo przy różnej kolejności czujników i kontaktów.

Ocena wiarygodności wizualnej na fizycznym iPhonie X pozostaje decyzją CEO.

## Poza zakresem pierwszego prototypu

- finalna oprawa graficzna i dźwiękowa;
- mechanika łączenia liczb;
- pełne 300 baniek;
- optymalizacja broad phase ponad potrzeby sceny jednej bańki;
- inne typy materiałów, pękanie i lepkość;
- zgodność z macOS jako wymaganie produktu.
