# BubblePhysics — czysty rdzeń sprężystego konturu i laboratorium jednej bańki

## Status i pierwszeństwo

Dokument opisuje zatwierdzoną architekturę nowego, minimalnego rdzenia fizyki
oraz osobnej aplikacji diagnostycznej. Powstaje po serii prototypów, które
ujawniły błędy modelu, a nie tylko niewłaściwe parametry.

W zakresie nowego `BubblePhysicsCore` i `BubblePhysicsLab` niniejsza
specyfikacja zastępuje wcześniejsze dokumenty dotyczące radialnego pola
deformacji, obwiedni kontaktów i solvera równowagi naprężeń. Poprzedni kod i
dokumenty pozostają w historii Git jako materiał badawczy, lecz nie są bazą
implementacyjną ani wymaganiem zgodności.

## Cel

Pierwszy etap ma zweryfikować jeden mechanizm: czy swobodna bańka z dynamicznym
środkiem masy i bezmasowym, sprężystym konturem zachowuje się wiarygodnie pod
naciskiem sztywnego wielokąta i ścian komory.

Za wiarygodne zachowanie uznajemy łącznie:

- miejscową, gładką deformację w chwili nacisku;
- przeniesienie niezrównoważonej reakcji sprężystej na środek masy;
- szybki i stabilny powrót konturu do okręgu po zwolnieniu nacisku;
- brak przenikania konturu i środka przez sztywny wielokąt lub ściany;
- wyczuwalny opór wielokąta sterowanego palcem;
- płynne wygaszanie swobodnego ruchu bez nagłego wirowania;
- stabilne, skończone wyniki obliczeń.

Nie celem tego etapu są setki baniek, łączenie i dzielenie, pełna gra 2KBubbles,
optymalizacja Metal ani ostateczna oprawa. Te funkcje mogą powstać dopiero po
potwierdzeniu podstawowej fizyki.

## Odcinamy poprzednią implementację

Powstaną dwa czyste moduły:

- `BubblePhysicsCore` — model, solver i geometria niezależne od interfejsu;
- `BubblePhysicsLab` — mała aplikacja iOS służąca wyłącznie do obserwacji i
  ręcznego testowania rdzenia.

Stare tryby (`CPU`, `Radial`, `40`, `300`), stare panele, cząsteczkowy backend
konturu, radialne wgniecenia oraz dotychczasowy solver nie będą kompilowane do
nowego laboratorium. Nie przenosimy kodu tylko dlatego, że już istnieje.
Dozwolone jest ponowne użycie małych, sprawdzonych narzędzi matematycznych po
osobnej ocenie, lecz nie całych starych przepływów.

## Model bańki

Bańka składa się z:

1. jednego dynamicznego środka masy;
2. naturalnego promienia `r`;
3. uporządkowanego, zamkniętego konturu z `N` bezmasowych punktów;
4. sprężyn radialnych łączących środek z punktami konturu;
5. sprężyn sąsiednich utrzymujących regularny odstęp punktów;
6. ograniczenia krzywizny wygładzającego lokalne załamania.

Punkty konturu nie posiadają masy, prędkości ani niezależnej bezwładności.
Opisują chwilową równowagę geometryczną powierzchni pod działaniem sprężyn i
kontaktów. Dzięki temu kontur nie powinien falować jak galareta ani zachowywać
trwałej deformacji bez nacisku.

Środek posiada masę, położenie i prędkość liniową. W pierwszej wersji nie
potrzebujemy niezależnej dynamiki obrotowej bańki. Ewentualny kąt etykiety może
być w przyszłości wyprowadzany ze stabilnego stanu bańki, ale nie może wpływać
na walidację deformacji.

### Naturalny kształt

Bez kontaktu jedynym minimum energii konturu jest okrąg o promieniu `r`,
wyśrodkowany w środku masy, z równomiernie rozłożonymi punktami. Nie istnieje
pamięć dawnego wgniecenia ani kierunkowa mapa deformacji utrzymywana po ustaniu
kontaktu.

### Adaptacyjna liczba punktów

`N` wynika z obwodu i maksymalnego dopuszczalnego odstępu między sąsiednimi
punktami. Nie wprowadzamy sztywnego górnego limitu `N`. Zmiana `N` ma zachować
kolejność konturu i możliwie wiernie przepróbkować jego bieżący kształt.

W pierwszym laboratorium jedna bańka ma wartość `2` i naturalny promień `22 pt`
(średnica `44 pt`), aby była sensownym przyszłym celem dotyku. Docelowa skala
wartości jest ciągła według:

```text
r(v) = 22 · sqrt(v / 2)
```

Daje to w przybliżeniu promienie: `2 → 22`, `4 → 31`, `8 → 44`, `16 → 62`,
`32 → 88`, `64 → 124`, `128 → 176`, `256 → 249`, `512 → 352`, `1024 → 498`,
`2048 → 704 pt`. Naturalny rozmiar może przekraczać ekran; później taka bańka
ma być ściskana przez komorę, a nie sztucznie zmniejszana.

## Energia i deformacja konturu

Kontur rozwiązuje trzy współdziałające rodzaje więzów:

- sprężyny radialne dążą do naturalnej długości `r`;
- sprężyny sąsiednie dążą do naturalnego odstępu wynikającego z obwodu;
- energia krzywizny przeciwdziała ostrym rogom i samoprzecięciom.

Charakterystyka sprężyn jest monotoniczna i nieliniowo usztywniająca: niewielkie
odkształcenia są łatwe, a dalsze ściskanie wymaga szybko rosnącej siły. Nie narzucamy dodatniego
minimalnego promienia ani pola. Teoretycznie bańkę można ścisnąć niemal do
punktu, ale koszt energetyczny musi rosnąć bardzo gwałtownie.

Kontakt nie tworzy osobnego „wgniecenia radialnego”. Ogranicza położenia
rzeczywistych punktów wspólnego konturu. Nacisk rogu wielokąta obejmuje kilka
sąsiednich punktów przez więzy sąsiednie i krzywiznę, zamiast zerować pojedynczy
promień.

## Sztywny wielokąt i komora

Przeszkoda jest jednym sztywnym wielokątem opisanym przez uporządkowane
wierzchołki, pozycję, kąt oraz poprzednią i bieżącą transformację. Ma jednoznaczne
wnętrze i zewnętrze. Nie jest zbiorem niezależnych, dwustronnych odcinków.

Ściany komory korzystają z tego samego mechanizmu kontaktu, ale są statycznymi,
jednostronnymi granicami. Rysowana linia granicy jest dokładnie tą samą geometrią,
której używa fizyka.

### Kontakt punktu konturu

Dla każdego punktu konturu wykrywamy wejście w niedozwolony obszar. Punkt
znajdujący się wewnątrz wielokąta jest ograniczany do najbliższego punktu jego
powierzchni. Analogicznie punkt poza dozwoloną półpłaszczyzną ściany wraca na
granicę. Reakcja ograniczenia uczestniczy w rozwiązaniu sprężyn i wypadkowej
siły działającej na środek.

Po zakończeniu kroku żaden punkt konturu nie może pozostawać we wnętrzu
wielokąta ani poza komorą w granicach tolerancji numerycznej.

### Ochrona topologii środka

Środek nie jest powierzchnią kontaktową. Osobny, awaryjny test ciągły sprawdza,
czy w trakcie kroku trajektoria środka przecięła powierzchnię poruszającego się
wielokąta. Test obejmuje cały wielokąt oraz jego poprzednią i bieżącą
transformację i znajduje najwcześniejsze przecięcie.

Jeżeli takie przecięcie występuje, środek pozostaje po fizycznie poprawnej
stronie powierzchni z minimalnym odsunięciem numerycznym. Ominięcie wierzchołka
bez przecięcia powierzchni jest legalne. Ochrona środka nie zastępuje reakcji
sprężystej i powinna uruchamiać się wyjątkowo.

## Sterowanie wielokątem

Wielokąt jest jedynym obiektem sterowanym palcem w pierwszym laboratorium.
Nie teleportuje się do pozycji dotyku. Cel palca zasila serwomechanizm o
ograniczonej sile i prędkości. Reakcja bańki działa na wielokąt przeciwnie, więc
przy wolnej przestrzeni podąża on szybko, a pod naciskiem wyraźnie zwalnia.

Nie ma automatycznego ruchu ani automatycznego obrotu. Dzięki temu każdy test
jest kontrolowany przez użytkownika i można zatrzymać nacisk w wybranym miejscu.

## Obliczenia pojedynczej klatki

Jedna klatka wykonuje następujący przepływ:

1. odczytuje cel dotyku dla wielokąta;
2. wyznacza ograniczony napęd, prędkość i przewidywaną transformację wielokąta;
3. przewiduje położenie środka bańki z prędkości i oporu ruchu;
4. w razie potrzeby adaptuje `N` i przepróbkowuje zamknięty kontur;
5. wyznacza naturalne położenia punktów na okręgu wokół przewidywanego środka;
6. wykrywa punkty konturu naruszające ściany lub wnętrze wielokąta;
7. iteracyjnie rozwiązuje sprężyny radialne, sprężyny sąsiednie, krzywiznę i
   ograniczenia nieprzenikania;
8. sumuje reakcje sprężyn radialnych jako wypadkową działającą na środek;
9. aktualizuje prędkość i położenie środka, uwzględniając masę i tłumienie;
10. ponownie rozwiązuje kontur względem zaktualizowanego środka;
11. wykonuje ciągłą ochronę topologii środka dla całego wielokąta;
12. przekazuje przeciwną reakcję na sterowany wielokąt;
13. renderuje dokładnie rozwiązany kontur i granice używane przez fizykę.

Solver kończy iteracje po spełnieniu tolerancji pozycyjnej i energetycznej albo
po osiągnięciu jawnego limitu bezpieczeństwa. Osiągnięcie limitu jest widoczne
w diagnostyce i nie może prowadzić do `NaN`, nieskończoności ani pozostawienia
punktów wewnątrz przeszkody.

## Ruch środka i opór

Swobodna bańka zachowuje pęd, lecz delikatny opór powierzchniowy stopniowo ją
zatrzymuje. Ten sam opór działa łagodząco na układ wielu baniek w przyszłości:
przepchnięcie kilku obiektów będzie wymagało pokonania sumy ich oporów.

Przesunięcie środka jest skutkiem niezrównoważonych reakcji sprężystego
konturu. Sam fakt wykrycia penetracji nie przesuwa środka bezpośrednio, poza
minimalną korektą ochrony topologicznej. Bańka zdeformowana przy ścianie ma
zatem sama odsunąć swój środek podczas odzyskiwania naturalnego kształtu.

## BubblePhysicsLab

Laboratorium jest osobnym, czystym targetem iOS. Ekran zawiera:

- wyraźnie narysowaną, zamkniętą komorę z widocznymi czterema granicami;
- jedną swobodną bańkę `2` o promieniu `22 pt`;
- jeden sztywny wielokąt sterowany przeciągnięciem palca;
- przyciski `Reset` i `Dane` o obszarze dotyku co najmniej `44 × 44 pt`;
- opcjonalne przełączniki widoku środka i naturalnego okręgu.

Panel nie może zasłaniać komory. Szczegółowe dane są domyślnie ukryte i
pokazywane poza obszarem obserwacji albo w osobnym widoku. Reset odtwarza
identyczny stan początkowy.

W pierwszej scenie nie ma wielu baniek ani ruchomego automatycznie trójkąta.
Bańka pozostaje całkowicie swobodna — nie jest przywiązana sprężyną do punktu
sceny.

## Diagnostyka

Tryb `Dane` pokazuje co najmniej:

- czas klatki i liczbę iteracji solvera;
- liczbę punktów konturu i aktywnych ograniczeń kontaktowych;
- maksymalną penetrację po solverze;
- błąd względem naturalnego okręgu po ustaniu kontaktu;
- normę wypadkowej reakcji na środek;
- liczbę interwencji ochrony topologii;
- flagi przekroczenia limitu, `non-finite` i samoprzecięcia konturu.

Diagnostyka ma pomagać wyjaśniać zachowanie, a nie zmieniać parametry fizyki.

## Testy automatyczne

Rdzeń musi mieć deterministyczne testy obejmujące:

1. swobodny kontur zbiega do okręgu;
2. po usunięciu przeszkody błąd względem okręgu maleje aż do tolerancji;
3. nacisk płaską krawędzią tworzy szerokie, gładkie spłaszczenie;
4. nacisk rogiem nie tworzy promienia zerowego, ostrego rozdarcia ani
   samoprzecięcia;
5. po solverze żaden punkt konturu nie leży wewnątrz wielokąta;
6. środek nie przechodzi przez powierzchnię poruszającego się wielokąta;
7. bańka ściśnięta przy ścianie odsuwa środek pod wpływem własnej sprężystości;
8. swobodny ruch jest stopniowo wygaszany;
9. wielokąt pod oporem nie osiąga natychmiast celu palca;
10. reset daje bitowo lub w ramach ścisłej tolerancji ten sam przebieg;
11. wszystkie wartości pozostają skończone;
12. rysowana granica pokrywa się z granicą używaną w kolizjach.

## Ręczna walidacja na iPhonie X

Ocena odbywa się w ustalonej kolejności:

1. swobodna bańka i jej powrót do idealnego okręgu;
2. powolny nacisk płaską krawędzią;
3. nacisk wierzchołkiem wielokąta;
4. ściśnięcie bańki między wielokątem i ścianą;
5. szybki ruch palca sprawdzający ciągłe wykrywanie i brak przenikania.

Etap jest zaakceptowany dopiero wtedy, gdy wszystkie scenariusze wyglądają
wiarygodnie i przechodzą odpowiadające im testy. Dopiero potem dodajemy drugą
bańkę. Testy wielu baniek, 300 obiektów i backend Metal są osobnymi późniejszymi
etapami, aby wydajność nie maskowała ponownie błędu modelu.

## Kryteria ukończenia pierwszego etapu

- aplikacja uruchamia się na iPhonie X przy użyciu zgodnego toolchainu;
- interfejs pozwala łatwo wykonać pięć scenariuszy ręcznych;
- kontur jest gładki, zamknięty i nie przenika sztywnej geometrii;
- reakcja następuje bez widocznego opóźnienia, a powrót do okręgu jest szybki i
  nieoscylacyjny;
- środek porusza się wskutek reakcji konturu, nie wskutek arbitralnego
  rozsuwania obiektów;
- sterowany wielokąt ujawnia opór bańki;
- wszystkie testy automatyczne przechodzą;
- brak `non-finite`, zawieszeń i trwałych deformacji po zwolnieniu nacisku.

Spełnienie tych kryteriów potwierdza model fizyczny, ale nie zatwierdza jeszcze
skalowania do setek baniek ani implementacji GPU.
