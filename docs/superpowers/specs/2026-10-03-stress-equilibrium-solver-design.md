# BubblePhysics — równowaga naprężeń z deformacją pierwszego rzędu

## Status

Dokument opisuje zatwierdzoną zmianę wnętrza referencyjnego solvera CPU.
Zachowuje istniejący przebieg: wykrywanie kontaktów, iteracyjne szukanie
równowagi, aktualizację aktywnego zbioru i końcowe generowanie konturu.
Zastępuje natomiast bezpośrednie rozsuwanie środków na podstawie penetracji.

Specyfikacja rozwija model opisany w
`2026-10-02-bubble-physics-contact-envelope-design.md`. W razie sprzeczności
w zakresie reakcji na kontakt i wyznaczania równowagi obowiązuje ten dokument.

## Cel

Kontakt ma najpierw deformować powierzchnię bańki. Przesunięcie jej środka jest
konsekwencją niezrównoważonych naprężeń powstałych przy próbie odzyskania
naturalnego kształtu, a nie bezpośrednią korektą głębokości penetracji.

Solver ma szybko znajdować równowagę całej sieci kontaktów, zachowując pozory
fizycznej sprężystości, stabilność i możliwość późniejszego wykonania obliczeń
na GPU.

## Niezmienione elementy architektury

- Fizyka operuje na centralnych punktach masy i docelowych promieniach.
- Kontur jest kierunkowym polem deformacji, nie pierścieniem dynamicznych mas.
- Aktywny zbiór kontaktów jest aktualizowany iteracyjnie i zachowuje histerezę.
- Ściany są jednostronne, a krawędzie przeszkód dwustronne.
- Pełny adaptacyjny kontur powstaje dopiero po zakończeniu solvera.
- CPU pozostaje wzorcem poprawności dla przyszłego backendu Metal.

## Energia i przewidywane położenie

Dla bańki `i` solver najpierw wyznacza położenie przewidywane:

```text
yᵢ = xᵢ + vᵢ · Δt
```

Nowe położenia środków minimalizują sumę energii bezwładności i energii
deformacji:

```text
E(x) = Σ mᵢ/(2·Δt²) · |xᵢ-yᵢ|² + Σ Uc
```

Pierwszy składnik zachowuje ciągłość ruchu i wpływ masy. Nie jest korektą
penetracji. Drugi składnik pochodzi wyłącznie z lokalnych deformacji aktywnych
kontaktów.

Początkowy model energii pojedynczej deformacji ma postać:

```text
U(d) = ½k·d² + ¼k·α·d⁴/r²
p(d) = dU/dd = k·d·(1 + α·d²/r²)
```

`d` jest głębokością deformacji, `r` docelowym promieniem, `k` sztywnością, a
`α` nieliniowym usztywnieniem. Mały ścisk jest łatwy, natomiast dalsze
zmniejszanie promienia wymaga szybko rosnącego nacisku. Nie obowiązuje dodatnie
minimum pola ani promienia; promień podparcia jest geometrycznie ograniczony do
zera i może do niego dojść przy dostatecznie dużej energii.

## Lokalne rozwiązanie kontaktu

Każdy aktywny kontakt zawiera co najmniej:

```text
uczestników
normalną i punkt Q
deformację każdej uczestniczącej bańki
naprężenie
efektywną sztywność
wiek i stan histerezy
```

Dla ustalonych środków kontakt najpierw wyznacza wymagany ścisk powierzchni.
Kontakt dwóch baniek dzieli deformację pomiędzy nie według aktualnej podatności.
Sztywny odcinek nie pochłania deformacji, więc całość przypada bańce.

Nakładające się kierunkowe deformacje jednej bańki wpływają na jej promień
podparcia. Dokładny kontakt jest usuwany, jeżeli po uwzględnieniu tych deformacji
powierzchnie już się nie stykają.

## Równowaga środków

Dla każdej bańki sumowane są wektory naprężeń kontaktowych oraz składnik
bezwładnościowy. Powstaje wektor resztkowy `R`. Równowaga oznacza `R = 0` dla
wszystkich środków.

Dla ustalonego aktywnego zbioru solver liniaryzuje układ:

```text
J · Δx = -R
```

`J` jest dodatnio określonym przybliżeniem Gaussa–Newtona. Każdy kontakt wnosi
mały blok o strukturze zbliżonej do `k_eff · n·nᵀ`; kontakt bańka–bańka dotyczy
dwóch środków, a kontakt z odcinkiem jednego. Macierz jest rzadka i nie musi być
materializowana. Iloczyn `J·v` jest obliczany liniowo po aktywnych kontaktach.

Układ jest rozwiązywany metodą preconditioned conjugate gradient z prostym
preconditionerem blokowo-diagonalnym. Następnie stosowany jest tłumiony krok:

```text
x ← x + λΔx
```

Krok musi zmniejszać energię i nie może naruszyć ochrony topologicznej.
Warm start wykorzystuje kontakty, deformacje i rozwiązanie z poprzedniej klatki.

## Pętla zewnętrzna

Jedna klatka wykonuje:

1. zapamiętanie poprzednich stanów i wyznaczenie `y`;
2. broad phase i ciągłe wykrywanie rozpoczęcia kontaktów;
3. utworzenie lub odświeżenie aktywnego zbioru;
4. lokalne wyznaczenie deformacji i naprężeń;
5. obliczenie reszty `R`;
6. rozwiązanie kroku równowagi przez tłumiony Newton–PCG;
7. ponowne wyznaczenie dokładnych kontaktów i ich deformacji;
8. powtarzanie punktów 4–7 do zbieżności albo limitu;
9. ochronę topologiczną środków;
10. wyznaczenie prędkości, tłumienie oraz ograniczone tarcie;
11. jednorazowe wygenerowanie pełnych konturów.

Zbieżność wymaga jednocześnie stabilnego zbioru kontaktów, małej normy `R`,
małego kroku położeń i braku nierozwiązanej kolizji topologicznej.

## CCD i ochrona topologiczna

Kontakt powierzchniowy wykorzystuje aktualny kierunkowy promień i rozpoczyna
deformację. Nie przesuwa bezpośrednio środka.

Osobny test sprawdza ciągłe przecięcie toru środka z poruszającym się,
niepogrubionym odcinkiem. Uwzględnia ruch środka, translację odcinka i obrót.
Jeżeli przecięcie nastąpiłoby w obrębie skończonego odcinka, środek otrzymuje
minimalną korektę zatrzymującą go po dotychczasowej stronie.

Zmiana strony nieskończonej prostej poza końcem odcinka jest legalna. Dla
jednostronnej ściany dodatkowo obowiązuje dozwolona półpłaszczyzna.

Ochrona topologiczna jest zabezpieczeniem numerycznym, a nie zwykłą reakcją
fizyczną. Jej użycia są zliczane. Dla kontaktów bańka–bańka nie obowiązuje
analogiczny zakaz stron; przy niemal pokrywających się środkach stosowany jest
deterministyczny kierunek zastępczy, minimalny dystans obliczeniowy i ograniczenie
maksymalnego naprężenia.

## Prędkość, tłumienie i obrót

Położenie po rozwiązaniu równowagi jest jedynym źródłem nowej prędkości
pozycyjnej. Krok Newtona nie jest dodawany do prędkości ponownie.

Bez tarcia kontakt normalny nie obraca bańki. Tarcie może przekazać ograniczony
impuls styczny i moment, ale ich wartość nie przekracza wartości wynikającej z
lokalnego nacisku. Zmiana prędkości kątowej uwzględnia moment bezwładności bańki.
Tłumienie liniowe i kątowe wygasza ruch płynnie, także po ustaniu kontaktu.

## Kontur

Po solverze kierunkowe deformacje są interpolowane kątowo i sumowane. Promień
podparcia nie spada poniżej zera. Adaptacyjna liczba próbek wynika z długości
zdeformowanego obwodu oraz maksymalnego odstępu punktów. Wygładzanie renderera
nie zmienia fizyki, kontaktów ani położeń środków.

## Scena diagnostyczna

Tryb `CPU Wiz` pozostaje podstawowym narzędziem oceny. Przed oceną nowego
solvera scena musi zostać poprawiona:

- wartość wyświetlana na bańce jest monotonicznie powiązana z jej docelowym
  promieniem; większa liczba zawsze oznacza większą bańkę;
- żadna bańka nie rozpoczyna wewnątrz trójkąta ani w ogromnej penetracji;
- początkowe położenia są deterministyczne i dostatecznie ciasne, aby szybko
  ujawnić przenoszenie nacisku;
- trójkąt porusza się dość wolno, aby zwykła reakcja sprężysta dominowała nad
  awaryjną ochroną środka.

## Telemetria

Raport klatki zawiera dodatkowo:

```text
liczbę zewnętrznych aktualizacji kontaktów
łączną i maksymalną liczbę iteracji PCG
początkową i końcową normę naprężeń
maksymalną deformację względną
maksymalną pozostałą penetrację powierzchni
liczbę interwencji ochrony środka
liczbę nieudanych kroków tłumionych
non-finite
```

## Testy akceptacyjne

- Pojedynczy nacisk najpierw deformuje kontur i przesuwa środek w kierunku
  zmniejszającym naprężenie.
- Równe przeciwne naciski deformują bańkę bez istotnego ruchu środka.
- Łańcuch baniek przekazuje naprężenie przez cały aktywny graf.
- Bańka dociskana do rogu nie przechodzi przez ściany.
- Bańka większa niż plansza znajduje skończony stan silnego ściśnięcia.
- Ruchomy i obracający się odcinek nie przecina środka.
- Obejście końca odcinka nie wywołuje fałszywej korekty.
- Prawie całkowite ściśnięcie pozostaje skończone i nie generuje `NaN`.
- Brak tarcia nie zmienia prędkości kątowej.
- Tarcie wywołuje ograniczony, płynny obrót.
- Rozwiązanie Newton–PCG dla małej sceny zgadza się z dokładnym rozwiązaniem
  tego samego zlinearyzowanego układu.
- Warm start zmniejsza lub zachowuje liczbę iteracji w prawie statycznej scenie.
- Ta sama sekwencja wejść daje deterministyczny wynik.

## Kryterium pierwszego etapu

Referencyjny CPU ma przede wszystkim potwierdzić fizykę i zbieżność. Scena
`CPU Wiz` musi wyglądać wiarygodnie: natychmiastowa deformacja, spokojne
przesuwanie środków, szybki lecz nieoscylacyjny powrót konturu, brak nagłego
wirowania i brak przechodzenia trójkąta przez środki. Dopiero po tej walidacji
ten sam model zostanie przeniesiony do backendu Metal.
