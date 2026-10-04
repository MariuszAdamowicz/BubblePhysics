# BubblePhysicsReference — zdarzeniowo-niejawny solver sprężyn kontaktowych

## Status i zakres

Dokument zastępuje specyfikację `2026-10-03-stress-equilibrium-solver-design.md`
w zakresie równań ruchu i solvera `BubblePhysicsReference`. Zachowujemy sprawne
elementy istniejącego targetu: modele środków i promieni, broad phase, CCD,
identyfikatory kontaktów, scenę wizualną, telemetrię oraz generowanie konturu.

Nie kontynuujemy obecnie implementacji nowego `BubblePhysicsCore`. Dwa ukończone
taski pozostają w historii jako odizolowany kod, ale aplikacja diagnostyczna ma
ponownie używać poprawionego `BubblePhysicsReference`.

## Cel

Solver ma sprawiać wrażenie fizycznie poprawnej, dynamicznej sceny przy wysokiej
wydajności. Nie jest narzędziem naukowym. Kontakt ma być sprężyną działającą
między punktem kontaktu `Q` a środkiem bańki, a Newton ma rozwiązywać
zdyskretyzowane równania ruchu, nie statyczną mapę deformacji.

## Model kontaktu

Dla bańki o środku `C`, naturalnym promieniu `r` i punkcie kontaktu `Q`:

```text
l = |C - Q|
d = max(0, r - l)
n = (C - Q) / |C - Q|
```

Siła normalna działa na środek:

```text
F = (K · d - gamma · vRelativeNormal) · n
```

Siła nie może stać się przyciągająca; jej wartość normalna jest ograniczona od
dołu zerem. Początkowo używamy liniowego prawa Hooke'a. Nieliniowe usztywnienie
jest opcjonalnym późniejszym rozszerzeniem, nie warunkiem pierwszej walidacji.

Nie istnieją osobne „siły konturu” i „siły kontaktu”. Sprężyna kontaktowa jest
jedynym źródłem reakcji normalnej. Dla bańka–bańka ta sama siła działa przeciwnie
na oba środki. Dla sztywnego wielokąta przeciwna reakcja działa na wielokąt.

## Równania ruchu

Dla każdego środka:

```text
dC/dt = v
m · dv/dt = suma(Fkontaktów) - globalDrag · v
```

Krok klatki rozwiązuje niejawnie stan końcowy. Pierwsza implementacja używa
niejawnego punktu środkowego:

```text
C1 = C0 + dt · (v0 + v1) / 2
m · (v1 - v0) = dt · F(Cmid, vmid, tmid)
```

Po eliminacji prędkości powstaje rzadki nieliniowy układ pozycji środków.
Newton aktualizuje `Q`, normalne, ściski i aktywny zbiór po każdej iteracji.
Zlinearyzowany krok rozwiązuje PCG. Warm start korzysta z poprzedniej klatki.

Poprzedni błąd nie może wrócić: składnik bezwładności nie jest statyczną kotwicą
do pozycji po predykcji. Jest dokładnie składnikiem zdyskretyzowanego równania
ruchu, a wynik Newtona określa równocześnie `C1` i `v1`.

## Zdarzenia w obrębie klatki

Klatka obejmuje przedział `[t0, t1]`. Swept broad phase i CCD wyszukują
najwcześniejszy początek nowego kontaktu przed końcem tego przedziału.

1. Do czasu zdarzenia integrujemy aktualny układ kontaktów.
2. Kontakty o czasach różniących się mniej niż tolerancja są grupowane.
3. Dodajemy nowe sprężyny z początkowym ściskiem zero.
4. Rozwiązujemy pozostały czas klatki.
5. Powtarzamy do końca klatki albo do limitu zdarzeń.

Nie planujemy z góry czasu zakończenia kontaktu w gęstej sieci. Kontakt jest
usuwany, gdy ścisk osiągnął zero i prędkość względna jest rozdzielająca.
Analityczna mapa całego zderzenia jest dopuszczalna później wyłącznie jako
optymalizacja odizolowanej, bez-tarciowej pary.

Limit zdarzeń chroni przed drganiami kalendarza. Po jego osiągnięciu pozostały
czas rozwiązuje jeden krok niejawny z konserwatywnie aktywnymi kontaktami, a
telemetria zgłasza przekroczenie.

## Geometria i aktywny zbiór

- Bańka–bańka używa linii środków oraz sumy naturalnych promieni.
- Bańka–odcinek używa najbliższego punktu `Q` skończonego odcinka.
- Ruchomy wielokąt pozostaje na razie zbiorem krawędzi tylko w detekcji, ale
  wszystkie krawędzie jednego właściciela mają wspólne wnętrze; punkt wewnątrz
  wielokąta nie może zostać uznany za poprawnie rozdzielony.
- CCD środka względem niepogrubionej powierzchni pozostaje zabezpieczeniem
  topologicznym, nie źródłem zwykłej siły.
- Kandydat z naturalnych promieni jest konserwatywny. Dokładny kontakt może
  zostać usunięty, jeżeli końcowy, wygenerowany kontur nie dosięga sąsiada.

## Kontur

Kontur jest wynikiem stanu kontaktów, nie dodatkowym układem dynamicznych mas.
Każdy aktywny kontakt określa punkt `Q`, kierunek i końcowy ścisk. Pełny kontur
powstaje raz po zakończeniu dynamiki klatki przez interpolację ograniczeń
promienia i wygładzenie krzywizny.

Wiele sąsiednich kontaktów tworzy jedną wspólną, gładką powierzchnię. Promienie
nie są niezależnie odejmowane w sposób pozwalający utworzyć klin o długości
zero. Bez kontaktów jedynym wynikiem jest okrąg naturalny; nie utrzymujemy
trwałej mapy dawnych wgnieceń.

## Co usuwamy z poprzedniego solvera

- minimalizowanie statycznej energii deformacji jako celu samego w sobie;
- czyszczenie i odbudowę `directionalDeformations` wewnątrz każdej iteracji
  Newtona;
- wyznaczanie prędkości wyłącznie jako efektu korekty pozycji;
- skalowanie sceny `mass ~ r²` połączone ze `stiffness ~ 1/r`;
- traktowanie trzech krawędzi trójkąta jako niezależnych powierzchni bez
  wspólnego wnętrza;
- bezpośrednie rozsuwanie środków poza interwencją topologiczną.

## Wydajność

Niewiadomymi Newtona są dwa składniki położenia na bańkę, nie punkty konturu.
Dla 300 baniek układ ma 600 stopni swobody. Każdy kontakt wnosi mały blok do
rzadkiego operatora, więc iloczyn Jacobian–wektor jest liniowy względem liczby
aktywnych kontaktów i nadaje się później do GPU.

Pierwszy cel to maksymalnie 4 zewnętrzne iteracje Newtona, maksymalnie 16
iteracji PCG na krok i maksymalnie 8 grup zdarzeń na klatkę. Limity są jawne w
telemetrii i mogą być dostrojone po pomiarze na iPhonie X.

## Testy akceptacyjne

- Izolowany kontakt liniowej sprężyny zgadza się z analitycznym kierunkiem,
  czasem maksymalnego ścisku i znakiem prędkości po rozłączeniu.
- Jeden krok `dt` jest jakościowo zgodny z dwoma krokami `dt/2`; błąd maleje po
  dalszym podziale czasu.
- Równe przeciwne naciski deformują bańkę bez ruchu środka.
- Niezrównoważony nacisk nadaje środkowi prędkość zgodną z wypadkową siłą.
- Trzeci kontakt powstały podczas trwania pierwszego unieważnia izolowane
  przewidywanie i zmienia wynik całej grupy.
- Łańcuch baniek przekazuje siłę w tej samej klatce solvera.
- Wolny kontakt nie wymaga ochrony topologicznej; szybki ruch nie przenika
  środka ani wielokąta.
- Po rozłączeniu kontur wraca do okręgu bez trwałego wgniecenia.
- Żaden punkt konturu nie pozostaje wewnątrz sztywnego wielokąta.
- Ten sam stan i wejście dają deterministyczny wynik bez `NaN` i nieskończoności.

## Walidacja wizualna

Pierwsza scena używa małej liczby baniek, widocznych ścian i wielokąta
sterowanego palcem. Sprawdzamy kolejno pojedynczy nacisk, przeciwne naciski,
łańcuch trzech baniek, narożnik, ścisk przy ścianie i szybki ruch wielokąta.
Dopiero po wiarygodnym wyniku zwiększamy liczbę obiektów i wracamy do pomiaru
300 baniek.
