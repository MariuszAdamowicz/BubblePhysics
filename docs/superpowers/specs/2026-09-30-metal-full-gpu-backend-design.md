# Pełny backend Metal dla BubblePhysics

## Cel

Biblioteka `BubblePhysics` ma otrzymać docelowy, iOS-only backend Metal, w którym
cały stan symulacji i cały krok fizyki pozostają na GPU. Celem nie jest wyłącznie
obsłużenie odświeżonego 2KBubbles, lecz stworzenie zapasu wydajności dla kolejnych,
bardziej wymagających gier mobilnych.

Pierwszy twardy cel: na iPhonie X, w konfiguracji Release, scenariusz 300
deformowalnych baniek musi mieć p95 czasu całej fizyki nie większe niż 8 ms.

## Ustalone decyzje

- Pierwsza wersja obsługuje tylko iOS. macOS jest możliwym, lecz niewymaganym
  rozszerzeniem.
- CPU i GPU mają zachowywać się fizycznie porównywalnie; bitowa zgodność
  klatka-po-klatce nie jest wymagana.
- Docelowy backend wykonuje cały krok na GPU, włącznie z broad phase.
- Broad phase nie używa jednolitej siatki, ponieważ bańki mogą mieć skrajnie
  różne rozmiary. Zostanie użyte LBVH oparte na AABB.
- Kontakty są rozwiązywane przez buforowanie i redukcję poprawek, nie przez
  równoległe, nieskoordynowane zapisy do tych samych cząstek.
- Nie ma stałego limitu liczby punktów obwodu ani kontaktów. Bufory mają
  zmienną pojemność i rosną bezpiecznie między krokami.
- Obecny solver CPU pozostaje backendem referencyjnym, testowym i awaryjnym.

## Granice odpowiedzialności

`BubbleWorld` pozostaje publicznym API gry. Przyjmuje polecenia, zarządza
tożsamościami baniek i wielokątów, udostępnia diagnostykę oraz wybiera backend.

Nowy moduł `BubblePhysicsMetal` jest dostępny wyłącznie dla iOS i posiada:

- `MetalBubbleSolver`, który utrzymuje trwałe zasoby `MTLBuffer`;
- kod Metal Shading Language dla etapów symulacji;
- adapter poleceń CPU do kompaktowego bufora wejściowego GPU;
- asynchroniczny odczyt telemetrii i mechanizm zwiększania pojemności buforów.

CPU przesyła jedynie polecenia gry, np. chwyt, siłę, zmianę rozmiaru,
połączenie, podział i transformację wielokąta. Normalna klatka nie kopiuje
pozycji cząstek z GPU do CPU. Renderer wykorzystuje ten sam bufor pozycji,
który aktualizuje solver.

## Układ danych GPU

Pamięć GPU używa układu structure-of-arrays:

- cząstki: bieżąca pozycja, poprzednia pozycja, masa odwrotna, przynależność;
- bańki: indeks środka, zakres punktów obwodu, pole spoczynkowe;
- ograniczenia: sprężyny promieniowe, obwodowe, przekątne i ograniczenia pola;
- obiekty sztywne: wierzchołki, krawędzie, trójkąty, transformacje i prędkości;
- broad phase: AABB, klucze Mortona, węzły LBVH i pary kandydatów;
- narrow phase: rekordy kontaktów, rekordy poprawek i indeksy redukcji;
- telemetria: liczniki, flagi przepełnienia i flagi błędów numerycznych.

Bufory są alokowane długotrwale. Stan kroku używa buforów wejścia i wyjścia,
więc przepełnienie nie uszkadza ostatniego zatwierdzonego stanu. Jeżeli GPU
zgłosi przepełnienie par, kontaktów lub poprawek, bieżący krok kończy się bez
cichego pominięcia danych, a CPU przed następnym krokiem zwiększa odpowiedni
bufor i ponawia krok z niezmienionego bufora wejścia. Pojemność nie jest
traktowana jako limit projektowy.

## Krok fizyki GPU

Jeden command buffer zawiera kompletny krok:

1. zastosowanie poleceń i predykcja wszystkich cząstek;
2. redukcja AABB baniek, kodowanie Mortona, sortowanie oraz budowa LBVH;
3. generowanie dokładnych par AABB przez przejście LBVH;
4. osiem iteracji solvera:
   - niezależne ograniczenia kształtu dla każdej bańki,
   - ograniczenia granic świata,
   - generowanie kontaktów dla par,
   - generowanie kontaktów z wielokątami sztywnymi,
   - zapis poprawek kontaktów do oddzielnego bufora,
   - grupowanie oraz redukcja poprawek według indeksu cząstki,
   - zastosowanie zredukowanych poprawek;
5. zapis telemetrii i udostępnienie bufora pozycji rendererowi.

Pary AABB i kontakty są odtwarzane z aktualnego stanu GPU. Nie stosuje się
jednolitej siatki ani stałego maksymalnego promienia. Duża bańka może zatem
mieć prawidłowe kontakty z wieloma małymi bańkami.

Solver kontaktów używa modelu Jacobi dla korekt współdzielonych cząstek.
Wynik jest stabilny i dobrze równolegli się na GPU, choć może różnić się
liczbowo od sekwencyjnego XPBD CPU. Parametry zgodności i liczba iteracji są
strojoną częścią backendu, a nie obietnicą bitowej zgodności.

## Wielokąty, granice i chwyt

Granice świata są rozwiązywane w kernelu kształtu. Wielokąt sztywny jest
reprezentowany przez obrys i triangulację, dzięki czemu ten sam model obejmuje
prostokąty, obiekty wypukłe i wklęsłe oraz obiekty kinematyczne obracające się.
Kontakt bańka-wielokąt produkuje poprawki przez ten sam mechanizm redukcji co
kontakt bańka-bańka.

Chwyt gracza jest poleceniem z docelową pozycją i maksymalną korektą na krok.
Jest stosowany na GPU jako ograniczenie zgodne, więc zachowuje pożądaną oporną
reakcję zamiast teleportowania bańki pod palec.

## Walidacja

Backend Metal jest oceniany na trzech poziomach:

1. Testy danych: poprawna serializacja buforów, stabilne identyfikatory,
   wzrost pojemności oraz brak utraty par i kontaktów przy przepełnieniu.
2. Testy fizyki: brak NaN i wartości nieskończonych, zachowanie pola
   spoczynkowego w tolerancji istniejących testów, rozdzielanie nakładających
   się baniek, granice świata, chwyt oraz wielokąty statyczne i kinematyczne.
3. Testy porównawcze CPU/GPU: te same sceny wejściowe przez wiele kroków,
   porównanie liczby baniek, zachowania pola, finitości stanu i jakościowego
   rozdzielenia kontaktów. Nie wymagają identycznych współrzędnych float.

Benchmark iPhone X raportuje p50, p95, czas etapów GPU, liczbę cząstek,
par i kontaktów oraz flagi przepełnienia. Obejmuje 300 baniek, zróżnicowane
promienie, gęsty układ kontaktów, długą serię kroków oraz obracający się
wielokąt.

## Kryteria akceptacji

- p95 całej fizyki dla scenariusza 300 baniek na iPhonie X w Release wynosi
  nie więcej niż 8 ms;
- benchmark pokazuje krzywą skalowania liczby baniek, promieni i kontaktów,
  a nie wyłącznie jeden punkt pomiarowy;
- żadna testowana scena nie powoduje NaN, nieskończoności, utraty danych przy
  przepełnieniu ani cichego obcięcia liczby punktów lub kontaktów;
- gra może renderować stan bez synchronizacji CPU po każdej iteracji;
- CPU pozostaje uruchamialnym backendem referencyjnym;
- całość nowych plików i zmian jest testowana, commitowana i wypychana do
  publicznego repozytorium `MariuszAdamowicz/BubblePhysics`.
