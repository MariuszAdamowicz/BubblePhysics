# BubblePhysics — optymalizacja referencyjnego GPU dla 300 baniek

## Cel i zatwierdzony zakres

Rozwijać referencyjny model kontaktowy na Metal jako bibliotekę wielokrotnego użytku na iPhone’ach spełniających minimum iOS 16 oraz Macach z Apple Silicon i macOS 13 lub nowszym. `stress-300` ma działać na fizycznym iPhonie X w budżecie `10 ms p95` pełnej klatki i zachowywać fizycznie wiarygodny ruch znany z CPU `interactive-24`. CEO zatwierdził skupienie aplikacji benchmarkowej na CPU jako wzorcu i na tym backendzie GPU. Historyczne ekrany `Radial`, `40` oraz stare `300` mają zniknąć z aplikacji; ich biblioteki, historia i testy pozostają dostępne w repozytorium. CPU reference i jego wizualizacja pozostają wyrocznią, fallbackiem i narzędziem oceny zachowania.

To kolejna iteracja kierunku GPU zatwierdzonego po benchmarku CPU. Nie zmienia parametrów fizyki, deterministycznych scen, zadanego limitu Newtona ani limitu PCG. Nie wprowadza adaptacyjnego budżetu czasu. Zachowuje atomową publikację klatki, pełnoklatkowy fallback CPU i fatalny latch po błędach Metal. Wsparcie platformy oznacza działającą ścieżkę CPU i — przy dostępności Metal — rzeczywistą ścieżkę GPU; nie oznacza jednak gwarancji `10 ms p95` na każdym obsługiwanym urządzeniu.

## Dowód i hipotezy kosztu

Smoke Release na iPhonie X z iOS 16.7.16, `interactive-24`, limit Newtona 4, seed 2842869, 30 klatek warmup i 300 mierzonych, ukończył `330/330` klatek Metal bez fallbacku. Raport: `1284.8055 ms p95` pełnej klatki, `399.5981 ms p95` sumy command bufferów; CPU baseline pełnej klatki wynosi `1.9065 ms p95`. Penetracja p95 wzrosła z `35.3938` do `38.3238`, a maksimum niezbieżnych komponentów z 8 do 9. Źródła: `docs/benchmarks/reference-gpu-smoke-iphone-2026-10-05.txt` oraz `docs/benchmarks/reference-convergence-iphone-2026-10-04.txt`.

Aktualny host wysyła, przy `maximumEventGroups=8` i limicie Newtona 4, do `1 + 17 × (3 × 4 + 1) + 16 + 4 = 242` command bufferów na klatkę; po każdym czeka na zakończenie. W każdym slocie planuje też pełne pętle PCG i sześć prób line search, nawet jeśli sterowanie GPU zamraża już nieaktywną pracę. To potwierdzony koszt architektury, ale obecny raport nie przypisuje mu liczbowo całej różnicy między p95 GPU i p95 pełnej klatki. `referenceEmitCandidatePairs`, `referenceFindTOI` i `referenceLabelComponents` działają w jednym wątku oraz skanują pary/kontakty; ich udział czasowy wymaga pomiaru. Wniosek o przyczynie regresji jakości wymaga diagnostyki pierwszej rozbieżnej klatki.

## Podejścia

1. **Zalecane: pętla na Macu, profilowanie, ograniczenie pustego harmonogramu i równoległe operatory.** Najpierw uruchomić ten sam produkcyjny backend Metal na Macu z Apple Silicon i zmierzyć czas oraz liczbę wywołań etapów. Potem kończyć planowanie nieaktywnych slotów, grupować zależne encodery bez pośrednich oczekiwań CPU tam, gdzie mieści się to w watchdogu, usunąć seryjne skany geometrii i zbudować listy kontaktów przypisane do baniek. Każda zmiana przechodzi test zgodności i pomiar na Macu; iPhone pozostaje bramką ryzyka i akceptacji.
2. **Monolityczny kernel GPU.** Ogranicza liczbę submissionów, lecz wcześniejszy `referenceAdvanceWorld` wywołał hang, a globalne redukcje Newton/PCG utrudniają bezpieczne zrównoleglenie. Nie jest pierwszym krokiem.
3. **Powrót do optymalizacji CPU.** Utrzymuje prostszą wyrocznię, ale baseline `stress-300` wynosi `92.9683 ms p95`; bez zmiany dominującego kosztu solvera nie ma dowodu na osiągnięcie 10 ms. Pozostaje osobnym kierunkiem, jeśli kolejna bramka GPU nie wykaże poprawy.

## Architektura pomiaru

Benchmark zachowuje sceny `interactive-24` i `stress-300`, seed, 30/300 klatek oraz wybór limitu `4/8/12/16`. Raport GPU dodaje oddzielną sekcję z liczbą command bufferów i encoderów na klatkę, czasem GPU per etap (`geometry`, `Newton`, `PCG`, `line search`, `CCD`, `guards`, `contours`, `render`), czasem hosta na kodowanie, oczekiwanie i końcowy readback oraz liczbą rzeczywiście aktywnych solve/CCD. Każdy czas ma p50/p95/max dla 300 ukończonych klatek Metal. Przedziałów percentylowych nie odejmuje się od siebie w celu oszacowania narzutu. Sekcja `gpu_completed` nadal wyklucza fallbacki; raport CPU zachowuje istniejący format.

Produkcyjny `ReferenceMetalWorldRunner` ma wybierać realny `ReferenceMetalSolver` również na macOS, gdy `MTLCreateSystemDefaultDevice()` i kompilacja shaderów są dostępne. macOS otrzymuje prosty uruchamiany z terminala harness benchmarku, korzystający z tych samych scen, runnera, konfiguracji i formatu raportu co aplikacja iOS, bez kopii algorytmu fizyki. Raport podaje platformę, system, model urządzenia/GPU, backend, ukończone klatki Metal i fallbacki. Brak Metal jest raportowany jako brak kwalifikacji GPU, a nie jako wynik wydajności GPU. Testy potwierdzają, że macOS nie wybiera już bezwarunkowo fallbacku CPU i że platformy używają tej samej ścieżki obliczeniowej.

Pomiar profilujący ma mały, jawny narzut. Wariant diagnostyczny i pomiar akceptacyjny używają tej samej fizyki, ale raport określa, czy szczegółowa instrumentacja była włączona. Nie miesza się wyników tych wariantów przy porównywaniu czasu.

## Architektura solvera

1. **Harmonogram.** Sterowanie kończy rzeczywiste planowanie kolejnych nieaktywnych slotów CCD/Newtona/PCG/line search. Semantyka wcześniejszego zakończenia wynika z kryteriów zbieżności CPU, nie z czasu klatki. W obrębie aktywnej grupy encodery mogą być łączone w ograniczone partie command bufferów; granice partii utrzymują diagnostykę i watchdog. Liczba etapów zależy od rzeczywistej pracy, a zadane maksima pozostają górną granicą.
2. **Geometria.** Generowanie kandydatów, testy TOI i powiązanie kontaktów z bańkami korzystają z równoległych przebiegów oraz deterministycznego scalania. Wynik zachowuje pełne ID, kolejność kontaktów, prefiks grup CCD i regułę ostatniego zapisu CPU. Przepełnienie zgłasza wymaganą pojemność i ponawia całą klatkę od niezmienionego wejścia.
3. **Newton/PCG.** Każdy aktywny operator pracuje na buforach GPU bez pełnego skanowania globalnych kontaktów przez każdą bańkę, jeśli lokalna lista kontaktów wystarcza. Redukcje zachowują jawny porządek dla powtarzalności. Scratch nie jest publikowany. Zmiany harmonogramu i operatory są osobnymi bramkami, aby ich wpływ na czas i jakość był rozpoznawalny.
4. **Wynik.** Po zakończeniu wszystkich aktywnych etapów GPU stosuje guardy, generuje kontury i pakiet renderowania. Host sprawdza pełny stan, publikuje go atomowo albo wykonuje pełnoklatkowy fallback CPU. Fatalny błąd Metal odcina dalsze próby w tej sesji.

## Aplikacja benchmarkowa

Ekran główny udostępnia wizualizację CPU reference oraz benchmark porównawczy CPU/GPU. Benchmark wybiera scenę 24/300, jeden limit lub macierz 4/8/12/16, pokazuje postęp, Start/Stop i kopiowalny raport. Historyczne prototypy `Radial`, `40` i stare `300` nie są uruchamiane ani prezentowane przez aplikację. Ich kod nie jest kasowany z bibliotek i testów. Oczyszczenie celu Xcode nie zmienia ustawień podpisu użytkownika.

## Zgodność fizyczna i kryteria bramki

Krótki deterministyczny przebieg porównuje CPU i GPU krok po kroku: ID/kolejność kontaktów, grupy CCD, pozycje i prędkości, penetrację, resztę i liczbę niezbieżnych komponentów. Testy mikroprzypadków obejmują zderzenia bańka–bańka, bańka–odcinek, ściany, ruchomy wielokąt, containment, wzrost buforów i fallback po błędzie. Pierwszy rozbieżny krok jest raportowany z przyczyną; tolerancje liczbowe pochodzą z istniejących kontraktów testowych i nie są luzowane dla wyniku benchmarku.

Bramka wydajności wymaga Release na tym samym fizycznym iPhonie X, zero fallbacków oraz obu macierzy `4/8/12/16` dla `interactive-24` i `stress-300`, każda po 30 klatkach rozgrzewki i 300 mierzonych. Pierwszym celem implementacyjnym jest limit 4; pozostałe limity pozostają obowiązkowym porównaniem przed akceptacją. `stress-300` musi osiągnąć `p95 <= 10 ms` pełnej klatki, bez `non-finite` i bez wieloklatkowego pełnego zawarcia. Penetracja, reszta i niezbieżne komponenty nie mogą być gorsze od CPU baseline dla tej samej sceny i limitu; `interactive-24` nie może utracić stabilności ani jakości CPU. Przekroczenie budżetu lub regresja jakości blokuje akceptację, nawet gdy `gpu_measurement=eligible`.

Bramka kompatybilności jest odrębna: pakiet i testy muszą budować się na iOS 16+ oraz macOS 13+; na dostępnym Macu z Apple Silicon benchmark Metal musi raportować ukończone klatki GPU bez bezwarunkowego fallbacku; na iPhonie X ścieżka Metal i fallback CPU muszą działać zgodnie z kontraktem. Nie deklaruje się zmierzonej wydajności ani działania na wszystkich modelach iPhone’a/Maca bez osobnych pomiarów na tych urządzeniach. Minimalne wersje platform pochodzą z `Package.swift` i nie są w tej iteracji obniżane.

## Etapy i zatrzymanie

Najpierw włącza się produkcyjny runtime Metal na macOS i zapisuje profil obecnej gałęzi na Macu mini. Potem osobno oceniane są: uproszczenie aplikacji i raportu, harmonogram, geometria oraz lokalne operatory kontaktów. Po każdej zmianie testy i porównanie CPU↔GPU wykrywają regresję, a benchmark Release na Macu daje szybką pętlę profilowania. Na iPhonie X robi się krótkie kontrole po zmianach grożących błędami sterownika, hangiem lub zmianą semantyki; pełne macierze akceptacyjne pozostają na koniec. Liczby czasu z Maca nie są prognozą czasu iPhone’a ani podstawą do uznania bramki `10 ms p95`. Jeżeli smoke `interactive-24` na iPhonie X nadal wisi albo jest skrajnie poza budżetem, nie uruchamia się kosztownej macierzy `stress-300` bez naprawy i nowego smoke. Wyniki surowe są przechowywane bez ręcznego przepisywania.

Specyfikacja nie zatwierdza automatycznie backendu do gry. Końcowy raport pokazuje osiągnięte czasy, jakość oraz nierozwiązane różnice, a decyzja o dalszej integracji należy do CEO.
