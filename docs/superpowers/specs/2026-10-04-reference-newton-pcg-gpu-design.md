# GPU Newton/PCG dla referencyjnego solvera BubblePhysics

## Cel i kontekst

`stress-300` zmierzony w Release na iPhonie z iOS 16.7.16 osiąga `92,97 ms p95` pełnej klatki już przy limicie czterech iteracji Newtona. Newton/PCG zajmuje `87,06 ms p95`, czyli dominuje koszt. CEO zatwierdził port tej części solvera na GPU jako kierunek B po analizie `docs/benchmarks/reference-convergence-2026-10-04.md`.

Celem jest iOS-only backend GPU dla referencyjnego modelu kontaktowego: środki masy baniek, odcinki, granice, ruchome wielokąty, CCD, kontaktowe sprężyny, Newton i PCG. Nie jest to port historycznego punktowo-sprężynowego backendu Metal.

## Kryteria sukcesu

- na fizycznym iPhonie, Release, `stress-300`, pełna część CPU+GPU przygotowująca klatkę ma `p95 <= 10 ms`;
- rezultat nie ma stanów `non-finite`;
- metryki penetracji, końcowej reszty, niezbieżnych komponentów i pełnych zawarć nie są gorsze od ustalonego baseline'u CPU dla tej samej sceny i limitu Newtona;
- `interactive-24` pozostaje stabilne i mieści się w budżecie;
- CPU reference pozostaje dostępny jako implementacja porównawcza, fallback i źródło diagnostyki.

Baseline jakości i czasu jest niezmienionym raportem urządzeniowym `reference-convergence-iphone-2026-10-04.txt`. Pierwszy port używa limitu Newtona `4`; kolejne limity pozostają testem porównawczym, nie polityką adaptacyjną.

## Zakres

W zakresie są trwałe bufory Metal dla baniek referencyjnych, odcinków, kontaktów, komponentów i wektorów układu liniowego; GPU dla tworzenia układu Newtona, iloczynu Jacobianu przez wektor, preconditionera, redukcji skalarów oraz iteracji PCG; GPU dla aktualizacji środka, guardów odcinków i wielokątów oraz wyznaczania konturów; telemetria i porównywalny benchmark urządzeniowy.

Poza zakresem są dynamiczny lub zależny od czasu limit iteracji, zmiana parametrów fizycznych/scen/tolerancji, strojenie konturów jako substytut portu solvera, port macOS, renderer finalnej gry oraz przenoszenie starego punktowo-sprężynowego `BubbleWorld`.

## Architektura

Nowy moduł `BubblePhysicsReferenceMetal` jest prywatnym backendem referencyjnego świata i działa wyłącznie na iOS 16+. `ReferenceWorld` zachowuje publiczny kontrakt i wybór backendu: CPU jest domyślny dla testów i diagnostyki, GPU jest jawnie wybieranym backendem benchmarku i hosta iOS.

Jedna klatka GPU działa w pojedynczym command bufferze:

1. CPU przesyła numer kroku, transformację trójkąta i konfigurację; nie przesyła ani nie odczytuje pozycji między iteracjami.
2. GPU wykonuje predykcję, broad phase, CCD, generację/utrzymanie kontaktów i partycję komponentów.
3. Dla każdej iteracji Newtona GPU buduje resztę i lokalne współczynniki, a następnie wykonuje matrix-free PCG do istniejącego limitu PCG.
4. GPU aktualizuje środki, stosuje guardy, generuje kontury i pakiet render-ready danych.
5. CPU odczytuje wyłącznie mały bufor telemetrii po zakończeniu command bufferu.

Pamięć używa structure-of-arrays. Wektory PCG (`residual`, `searchDirection`, `preconditionedResidual`, `matVec`) są ping-pongowane. Redukcje dot productów i norm mają deterministycznie zdefiniowany porządek bloków. Zgodność bitowa z CPU nie jest wymagana, lecz kontakty zachowują stabilne klucze, a kontakt bańka–odcinek tworzy komponent jednoelementowy, jak w CPU.

## Kontrakty danych i odporność

Bufory rosną między klatkami. Przepełnienie kontaktów, kandydatów, komponentów albo tymczasowych wektorów nie może ucinać danych: GPU ustawia flagę, CPU zachowuje wejście, zwiększa właściwy bufor i ponawia tę samą klatkę. Częściowy krok nie jest publikowany.

Brak Metal, błąd pipeline'u/command bufferu, przepełnienie niemożliwe do odzyskania albo `non-finite` powoduje jawny fallback całej następnej klatki do CPU reference. Telemetria zapisuje powód fallbacku; nie wolno mieszać części wyniku GPU z CPU w jednej opublikowanej klatce.

## Walidacja

1. ABI i redukcje: layout Swift/MSL, klucze, redukcje i wzrost buforów.
2. Operatory solvera: reszta, `J·v`, preconditioner i pojedynczy krok PCG porównane z CPU w tolerancji liczbowej.
3. Zachowanie świata: `interactive-24`, łańcuch kontaktów, segment, wielokąt i CCD — brak `non-finite`, brak przejścia środka i zgodne metryki jakości.
4. Urządzenie: pełna macierz `4/8/12/16` na fizycznym iPhonie, w formacie baseline'u.

Port nie zostaje zaakceptowany na podstawie czasu symulatora ani macOS. Jeśli pierwszy wariant GPU nie spełni jednocześnie budżetu i jakości, sprawa wraca do CEO z raportem różnic; nie zastępuje się tego ukrytym obcięciem iteracji.
