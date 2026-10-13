# BubblePhysics — GPU-native solver elastycznych baniek

## Cel i decyzja

Biblioteka ma dostarczać stabilną, wiarygodną wizualnie fizykę elastycznych baniek 2D dla szybkich gier mobilnych. CPU reference pozostaje wyrocznią scen, testów jakości i pełnoklatkowym fallbackiem. Nowy backend Metal nie ma odtwarzać jego trajektorii liczba-po-liczbie: ma zachowywać te same reguły fizyczne i dawać ten sam odczuwalny efekt — sprężyste zderzenia, lokalną deformację konturu, płynny powrót do kształtu, brak przenikania i containment.

CEO wybrał zgodność fizyczną ponad ścisłą zgodnością numeryczną z CPU. Dla tego samego seeda i wejść backend GPU ma być powtarzalny na tym samym urządzeniu, lecz może wyznaczać inną trajektorię, jeśli pozostaje stabilny i spełnia bramki jakości.

Aktualny port Newton/PCG pozostaje artefaktem referencyjnym i diagnostycznym. Nie jest podstawą nowego solvera: jego setki małych command bufferów, sterowanie z hosta i globalne redukcje uczyniły go wielokrotnie wolniejszym od CPU. Nowy backend powstaje obok niego, bez usuwania istniejących bibliotek, testów ani CPU reference.

## Kryteria sukcesu

Docelowa bramka wydajności jest mierzona wyłącznie w Release na fizycznym iPhonie X z iOS 16.7.16 lub równoważnym skonfigurowanym urządzeniu referencyjnym:

- scena `stress-300`, 30 klatek warmup i 300 mierzonych, ma pełną klatkę `p95 <= 10 ms`;
- GPU kończy wszystkie mierzone klatki bez fallbacku;
- nie występuje `non-finite`, wieloklatkowe pełne containment ani przejście środka bańki przez odcinek;
- penetracja, niestabilność spoczynku i jakość kontaktów mieszczą się w zatwierdzonych progach względem scen CPU;
- `interactive-24` zachowuje znane z CPU zachowanie: kontakt deformuje bańkę lokalnie, po zwolnieniu kontur płynnie wraca do formy, a przeszkody ruchome nie powodują widocznego drżenia.

Wynik na Macu z Apple Silicon służy wyłącznie szybkiemu profilowaniu i wykrywaniu regresji. Nie jest zamiennikiem bramki iPhone'a.

## Założenia wykonawcze

### Trwały stan na GPU

Stan symulacji pozostaje na GPU między klatkami. Obejmuje on dla każdej bańki pozycję, poprzednią pozycję lub prędkość, masę, promień spoczynkowy, parametry materiału oraz dane deformacji. CPU przesyła wejście gry i zmiany świata, ale nie odczytuje pośrednich stanów solvera. Pakiet do renderowania i telemetria są publikowane dopiero po ukończeniu całej klatki.

Każdy kontakt ma trwały klucz: para identyfikatorów baniek albo identyfikator bańki wraz z identyfikatorem prymitywu przeszkody. Rekord cache zawiera klucz, mnożnik/korektę XPBD, wiek i metadane ważności. Dopasowanie bieżących kontaktów do cache jest deterministyczne i ograniczone pojemnością; przepełnienie nie publikuje częściowej klatki.

### Warm-start i unieważnianie cache

Po wygenerowaniu kontaktów solver przenosi wyłącznie dopasowaną, nadal ważną korektę z poprzedniej klatki. Nowy kontakt startuje od zera. Cache jest unieważniany dla właściwego kontaktu lub zakresu świata, gdy:

- kontakt zniknął na więcej niż dozwoloną liczbę klatek;
- zmienił się prymityw przeszkody albo nastąpił reset sceny;
- bańka została teleportowana lub przeszła ponad bezpieczny próg przemieszczenia;
- CCD wykryło szybkie zdarzenie, głęboką penetrację albo ryzyko containment;
- guard numeryczny wykrył wynik niepoprawny.

Warm-start jest optymalizacją startu iteracji, nie źródłem prawdy: każda klatka ponownie sprawdza geometrię kontaktu i ogranicza wielkość zastosowanej korekty.

### Solver GPU-native

Nowy solver używa ograniczeń pozycyjnych XPBD/PBD dla kontaktów bańka–bańka, bańka–odcinek, ścian i ruchomych wielokątów. Parametry compliance, tłumienia i napięcia powierzchniowego pozostają jawne w konfiguracji sceny; nie wolno ukrywać degradacji jakości w czasowym limicie iteracji.

Ograniczenia są rozwiązywane metodą Jacobi. Dla każdej bańki wątek odczytuje niezmienny stan bieżącej iteracji, przechodzi wyłącznie po jej kontaktach incydentnych, sumuje korekty i zapisuje własny wynik do osobnego bufora. Pozwala to uniknąć wyścigów zapisu i atomików zmiennoprzecinkowych. Lokalna lista kontaktów dla bańki ma deterministyczny porządek kluczy.

Liczba iteracji jest małą, jawną stałą jakości na konfigurację — dobraną przez testy referencyjne, a nie automatycznie obcinaną przez czas klatki. Warm-start ma zmniejszać potrzebę kolejnych iteracji w typowym ruchu. Trudne przypadki obsługuje selektywny CCD i guardy, a nie powrót do tysiąca mikro-kroków.

### Broad phase i CCD

Broad phase korzysta z równoległej jednolitej siatki przestrzennej. Bańki są przypisywane do komórek, a narrow phase bada tylko pary z własnej i sąsiednich komórek. Kompaktacja kandydatów, klucze i listy incydencji są stabilne oraz mają sprawdzaną pojemność.

CCD nie jest wykonywane dla całego świata w każdej klatce. Jest aktywowane dla kandydatów spełniających kryterium szybkiego ruchu, nowego kontaktu po dużym przesunięciu lub ochrony przed przejściem środka przez odcinek. Wykrycie takiego przypadku może wyzerować warm-start kontaktu i wymusić ochronną korektę przed publikacją klatki.

### Kontur i elastyczność

Kontur jest częścią wyniku fizycznego, a nie nakładką kosmetyczną. Dane kontaktów wyznaczają lokalne naciski i ograniczenia przeszkód; GPU buduje punkty konturu, nakłada napięcie powierzchniowe i wygładzanie, a następnie pakuje dane renderowania. Po zaniku kontaktu lokalna deformacja wygasa zgodnie z parametrami materiału, co zapewnia widoczny, płynny powrót do promienia spoczynkowego.

## Harmonogram klatki

Host koduje jeden ograniczony command buffer dla normalnej klatki, a GPU wykonuje kolejno większe etapy. Dopuszczalne są wielokrotne compute encoder w tym samym command bufferze tam, gdzie wymagana jest globalna synchronizacja między iteracjami, ale host nie czeka i nie podejmuje decyzji między etapami.

```text
wejście gry
  -> predykcja pozycji
  -> siatka broad phase i kontakty
  -> dopasowanie oraz warm-start cache
  -> stała liczba iteracji XPBD/PBD
  -> selektywny CCD i guardy
  -> kontury i pakiet renderowania
  -> atomowa publikacja ukończonej klatki
```

Pojedynczy completion handler rozstrzyga wynik całej klatki. Błąd Metal, overflow lub naruszenie guardów nie publikuje scratcha: runner zachowuje ostatnią kompletną klatkę i uruchamia pełnoklatkowy fallback CPU zgodnie z dotychczasowym kontraktem. Fatalne błędy nadal latchują sesję do CPU.

## Kontrakt jakości

Backend GPU jest oceniany przez inwarianty i sceny, nie przez zgodność każdego float z CPU:

| Obszar | Wymóg |
| --- | --- |
| Stabilność | Brak `NaN`, `infinity`, częściowej publikacji i nieobsłużonego overflow. |
| Kolizje | Brak pełnego containment utrzymującego się przez więcej niż jedną klatkę; środek bańki nie przechodzi przez odcinek. |
| Spoczynek | Długi kontakt nie powoduje rosnącego dryfu ani widocznego drżenia. |
| Elastyczność | Nacisk powoduje lokalną deformację, a jej zanik przywraca kontur płynnie do formy spoczynkowej. |
| Powtarzalność | Ten sam seed i sekwencja wejść dają identyczny wynik na tym samym urządzeniu/wersji backendu. |
| Wydajność | Bramka `stress-300` na iPhonie X wynosi `p95 <= 10 ms` pełnej klatki, bez fallbacków. |

CPU reference dostarcza sceny porównawcze i bazę liczbową. Dla tej samej sceny, seeda i konfiguracji GPU musi spełnić następujący envelope:

- `containment == 0` i `non_finite == no`;
- penetracja p95 nie większa niż `max(cpuP95 * 1.10, cpuP95 + 0.5)`, a maksimum nie większe niż `max(cpuMax * 1.15, cpuMax + 1.0)`;
- po 120 klatkach sceny spoczynku maksymalne przesunięcie środka każdej niepobudzanej bańki przez kolejne 30 klatek jest mniejsze niż `0.1%` jej promienia na klatkę;
- po usunięciu kontrolowanego nacisku kontur osiąga średni błąd promienia mniejszy niż `2%` promienia spoczynkowego w ciągu 30 klatek i nie oscyluje rosnącą amplitudą;
- powtórzenie identycznej sekwencji wejść na tym samym urządzeniu daje identyczny hash stanu opublikowanej klatki.

Te progi nie są luzowane, aby zaliczyć benchmark GPU.

## Strategia weryfikacji

1. Testy jednostkowe kluczy kontaktów, dopasowania cache, wygasania i każdego powodu unieważnienia.
2. Testy deterministycznych scen dla kontaktów, segmentów, ścian, wielokątów ruchomych, szybkiego ruchu, containment i długiego spoczynku.
3. Porównanie właściwości CPU/GPU: inwarianty, metryki jakości, odpowiedź konturu i brak regresji bezpieczeństwa — bez wymagania identycznej trajektorii.
4. Krótkie profile Release na Macu po zmianach rdzenia oraz krótkie smoke `stress-300` na iPhonie X. Pełna macierz urządzeniowa następuje dopiero, gdy smoke jest blisko budżetu i przechodzi jakość.
5. Dopiero po przejściu automatycznych bramek powstaje jeden końcowy build demonstracyjny dla CEO do oceny odczucia gry.

## Zakres i granice

W zakresie jest nowy, izolowany backend GPU-native dla iOS 16+ i macOS 13+ na urządzeniach z Metal, zachowujący CPU fallback i istniejące sceny benchmarkowe. Aplikacja benchmarkowa nie jest teraz przepisywana; pozostaje narzędziem uruchomienia i raportowania.

Poza zakresem są: kolejny port Newton/PCG, ukryty dynamiczny limit jakości, usuwanie historycznych bibliotek/testów, zmiana ustawień podpisu Xcode oraz deklarowanie wydajności na urządzeniach niezmierzonych. Nie ma też iteracyjnej oceny przez CEO niedojrzałych buildów; ocena wizualnego „funu” następuje dopiero po technicznym przejściu bramek.

## Ryzyka i odpowiedzi

| Ryzyko | Odpowiedź |
| --- | --- |
| Jacobi wymaga więcej iteracji niż referencyjny CPU | Warm-start, lokalne listy kontaktów i jawna walidacja spoczynku; nie podnosimy iteracji bez pomiaru. |
| Dynamiczna siatka lub cache traci stabilność kluczy | Kanoniczne klucze, stabilna kompaktacja, testy resetu i atomowa publikacja. |
| CCD staje się dominującym kosztem | Selekcja tylko kandydatów szybkiego ruchu; osobne profile normalnej i trudnej ścieżki. |
| Kontur wygląda dobrze, lecz fizyka jest niestabilna | Kontur jest liczony z zatwierdzonego stanu po guardach; inwarianty kolizji blokują publikację. |
| Mac ukrywa problem iPhone'a | Mac jest wyłącznie pętlą diagnostyczną; każda bramka akceptacyjna wymaga iPhone'a X. |
