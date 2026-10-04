# Benchmark zbieżności solvera BubblePhysics — projekt

## Cel

Zbudować deterministyczny benchmark pełnej klatki referencyjnego silnika dla scen 24 i 300 baniek. Benchmark ma jednocześnie mierzyć koszt obliczeń i jakość rozwiązania dla limitów `4`, `8`, `12` oraz `16` iteracji Newtona. Jego raport będzie podstawą osobnej decyzji o zakresie portu GPU i późniejszej polityce adaptacyjnych iteracji.

Benchmark nie zmienia fizyki, parametrów sceny ani konturów. Nie implementuje jeszcze GPU ani automatycznego dobierania liczby iteracji.

## Kryterium użytkowe

Docelowa gra ma działać z częstotliwością 60 klatek na sekundę. Cała klatka trwa `16,67 ms`, ale roboczy budżet części fizycznej wynosi `10 ms p95`, aby pozostawić czas na renderowanie, wejście użytkownika i logikę gry.

Wynik poniżej budżetu nie oznacza automatycznie akceptacji. Solver musi również utrzymywać skończony stan i ograniczać długotrwałe penetracje oraz niezrównoważone komponenty kontaktowe.

## Reprezentatywne sceny

Benchmark obejmuje dwa deterministyczne warianty tej samej komory `375 × 700`:

- `interactive-24`: 24 bańki o zróżnicowanych promieniach i masach oraz trójkąt poruszany po ustalonej, agresywnej trasie;
- `stress-300`: 300 baniek wypełniających komorę oraz ten sam trójkąt wykonujący przeskalowaną trasę.

Każde uruchomienie używa stałego seeda, identycznego stanu początkowego i identycznych celów ruchu trójkąta. Pomiar składa się z rozgrzewki oraz właściwej serii klatek. Kolejne konfiguracje iteracji dostają świeżo utworzony świat, aby wyniki nie zależały od poprzedniego wariantu.

## Zakres pełnej klatki

Pomiar pełnej klatki obejmuje:

1. predykcję ruchu;
2. broad phase;
3. wykrywanie i utrzymywanie kontaktów;
4. zdarzenia CCD;
5. Newton + PCG;
6. zabezpieczenia środka względem odcinków i wielokąta;
7. wyznaczenie konturów wszystkich baniek;
8. przygotowanie danych renderowania możliwe do wykonania bez rzeczywistego prezentowania klatki przez GPU.

Czas samego renderowania Metal nie należy do baseline'u CPU. Będzie mierzony osobno w etapie GPU, żeby nie mieszać kosztu solvera z kosztem prezentacji obrazu.

## Macierz eksperymentu

Dla każdej sceny benchmark uruchamia limity Newtona `4`, `8`, `12` i `16`. Limit PCG oraz wszystkie pozostałe parametry pozostają stałe. Raport musi jawnie zapisać rzeczywistą liczbę wykonanych iteracji, ponieważ solver może zakończyć pracę wcześniej po osiągnięciu tolerancji.

Nie wolno w tym etapie dobierać limitu na podstawie czasu poprzedniej klatki. Taka zależność utrudniłaby porównanie i powodowałaby niedeterministyczne zachowanie fizyki.

## Telemetria czasu

Dla każdej kombinacji scena × limit iteracji raport zawiera:

- `p50`, `p95` i maksimum pełnej klatki;
- `p50`, `p95` i maksimum solvera;
- `p50`, `p95` i maksimum generowania konturów oraz przygotowania renderowania;
- `p95` predykcji, broad phase, kontaktów i CCD;
- liczbę rozgrzewkowych i mierzonych klatek.

Pomiary wykonywane na iPhonie są rozstrzygające. Wyniki z macOS służą wyłącznie do szybkiego wykrywania regresji i nie mogą zatwierdzić budżetu urządzenia.

## Telemetria jakości

Raport agreguje również:

- maksymalną i `p95` penetrację;
- początkową i końcową normę reszty solvera;
- liczbę klatek, które osiągnęły limit Newtona;
- liczbę iteracji Newtona i PCG;
- liczbę niezbieżnych komponentów kontaktowych;
- maksymalną liczbę kolejnych klatek pełnego zawarcia jednej bańki w drugiej;
- kandydatów, aktywne kontakty, zdarzenia TOI i wyczerpania budżetu CCD;
- korekty zabezpieczające środki;
- obecność stanu `non-finite`.

Komponent kontaktowy jest niezbieżny, jeśli po ostatniej wykonanej iteracji jego norma reszty przekracza `stressTolerance`. Metryka ma być liczona per komponent grafu kontaktów, a nie tylko globalnie, aby niezależny trudny układ nie ukrywał się w sumie całej sceny.

## Interfejs benchmarku

Biblioteka udostępni konfigurację pojedynczego przebiegu oraz wynik możliwy do wyświetlenia i zapisania bez zależności od SwiftUI. Istniejący ekran benchmarku iOS otrzyma:

- wybór sceny `24/300`;
- wybór pojedynczego limitu albo uruchomienie całej macierzy;
- postęp rozgrzewki i pomiaru;
- tabelę czasu i jakości;
- kopiowalny raport tekstowy z nazwą urządzenia, wersją systemu i konfiguracją przebiegu.

Uruchomienie benchmarku nie może blokować głównego wątku interfejsu. Anulowanie przebiegu kończy pracę bez publikowania częściowego wyniku jako kompletnego raportu.

## Determinizm i porównywalność

- Wszystkie sceny są tworzone z jawnego seeda.
- Trasa trójkąta zależy od numeru kroku symulacji, nie od czasu prezentacji ekranu.
- Każdy wariant zaczyna od identycznego świata.
- Raport zapisuje wartości wszystkich parametrów wpływających na wynik.
- Zmiana scenariusza lub parametrów wymaga nowej nazwy wersji benchmarku.

## Testy

Testy jednostkowe i integracyjne muszą potwierdzić:

- identyczność stanu początkowego oraz trasy dla dwóch uruchomień;
- wykonanie macierzy dokładnie w kolejności `4/8/12/16`;
- agregację p50, p95 i maksimum z ręcznie sprawdzonych próbek;
- osobne raportowanie czasu konturów;
- wykrycie niezbieżnego komponentu i wieloklatkowego zawarcia;
- anulowanie przebiegu asynchronicznego;
- brak `non-finite` w krótkich przebiegach obu scen.

Testy wydajności nie mogą zawierać twardych progów czasowych na macOS ani w CI. Próg `10 ms p95` jest oceniany wyłącznie na urządzeniu i zapisywany jako wynik, nie jako niestabilny test jednostkowy.

## Decyzja po benchmarku

Raport ma umożliwić wybór jednego z trzech dalszych kierunków:

1. CPU spełnia budżet i jakość — implementujemy adaptacyjne kończenie per komponent bez portu GPU;
2. solver dominuje koszt — przenosimy resztę, Jacobian, PCG i aktualizację komponentów na GPU;
3. kontury lub broad phase dominują koszt — optymalizujemy wskazany etap przed albo równolegle z solverem GPU.

Dopiero po tym pomiarze powstanie osobna specyfikacja portu GPU. Adaptacyjny solver zachowa stałe minimum, zakończy zbieżne komponenty wcześniej i dopuści dodatkowe iteracje trudnych komponentów do stałego maksimum. Budżet czasu będzie bezpiecznikiem całej klatki, a nie mechanizmem zmieniającym fizykę między urządzeniami.

## Poza zakresem

- implementacja solvera GPU;
- automatyczne zmienianie limitu iteracji podczas gry;
- strojenie sprężyn, tłumienia i konturów;
- zmiana publicznego API docelowej biblioteki;
- benchmark renderowania finalnej oprawy gry;
- zatwierdzenie urządzenia minimalnego lub wymagań sprzętowych.
