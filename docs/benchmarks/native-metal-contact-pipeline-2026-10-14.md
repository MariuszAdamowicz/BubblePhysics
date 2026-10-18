# Optymalizacja pipeline kontaktów native-metal — 2026-10-14

GPU Maca: Apple M2 Pro, Mac14,12, macOS 26.6.2. Kompilacja Release przez `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer`. Pomiary wykonano kolejno, po zakończeniu testów GPU. Każda scena: seed `2842869`, warmup 30, measured 300, pełna macierz `4/8/12/16`.

Surowy stdout programu benchmarkowego, bez przepisywania wartości:

- [interactive-24](native-metal-contact-pipeline-mac-interactive-24-2026-10-14.txt)
- [stress-300](native-metal-contact-pipeline-mac-stress-300-2026-10-14.txt)

## Zmiana

Budowa adjacency emituje końce rzeczywistych rekordów cache do unikalnych slotów sąsiadów. Stabilna kompakcja zachowuje kolejność ID używaną przez solver i eliminuje około 92 100 wyszukiwań binarnych dla 300 baniek. Redukcje reszty i największego promienia korzystają z threadgroup 256 i pamięci lokalnej; maksima i całkowitoliczbowe sumy są deterministyczne.

Argumenty indirect dispatch powstają na GPU po aktualizacji liczników kandydatów, aktywnych kontaktów i cache. Etapy kontaktowe oraz wszystkie poziomy skanów uruchamiają rzeczywistą liczbę grup zamiast pojemności 270 336 rekordów. Pojemność bezpieczeństwa i odrzucanie overflow pozostają zachowane. Pusty zakres uruchamia jedną grupę z kontrolą granic.

Runner potwierdza publikację wyniku do świata gry. Ta publikacja staje się bazą następnego porównania zmian CPU: normalna klatka nie wysyła ponownie 300 baniek i nie koduje 300 dodatkowych operacji blit. Zewnętrzna edycja, również cofnięcie bańki do wcześniejszego stanu, nadal jest wysyłana. Bezpośredni solver zachowuje kontrakt kontynuacji trwałego GPU przy niezmienionym wejściu.

## Wyniki na Macu

| Scena | Iteracje | Pełna klatka p95 ms | Cały command buffer GPU p95 ms |
|---|---:|---:|---:|
| interactive-24 | 4 | 1.2183 | 0.7365 |
| interactive-24 | 8 | 1.9386 | 1.5545 |
| interactive-24 | 12 | 2.3441 | 1.7966 |
| interactive-24 | 16 | 2.3389 | 1.8834 |
| stress-300 | 4 | 3.4661 | 2.2060 |
| stress-300 | 8 | 1.8756 | 1.2063 |
| stress-300 | 12 | 3.7207 | 2.5532 |
| stress-300 | 16 | 2.3469 | 1.8483 |

Wszystkie osiem wariantów: 330 klatek native GPU, zero fallbacków, containment i non-finite; dokładnie jeden command buffer i dwa encodery w każdej klatce; pełny `native_quality_envelope=pass`. Powtórzone sekwencje mają identyczne hashe z odpowiadającymi im pierwszymi sekwencjami. Bramka obejmuje także spoczynek, powrót konturu i porównanie penetracji z CPU tego samego scenariusza.

Dla stress-300 / 4 encoding hosta p95 wynosi `0.1725 ms`. Osobna wcześniejsza próba tego samego nowego kodu dała pełne p95 `2.7009 ms`, GPU p95 `2.0427 ms`. Rozrzut między uruchomieniami i nieliniowy porządek limitów nie uzasadniają wyboru limitu 8 jako szybszego profilu fizyki; sceny ewoluują odmiennie, a harmonogram GPU i zegary wpływają na czas.

Diagnoza przed zmianą na M2 Pro raportowała GPU p95 `5.9520 / 6.2011 / 6.1223 ms` w krótszych próbach 30 zmierzonych klatek. Nowe pomiary potwierdzają spadek kosztu, ale te serie różnią się długością i nie są podstawą dokładnego współczynnika przyspieszenia.

## Weryfikacja i następna bramka

- Pełne `swift test`: 590 testów, zero błędów, jeden standardowy skip `ReferenceBenchmarkTests.testPrintLocalBaselineWhenRequested`, 343.9 s.
- Następny kompletny zestaw `BubblePhysicsNativeMetalTests`, obejmujący trzy dodatkowe regresje dopisane w czasie pełnego testu: 96/96 bez błędów. Sprawdza m.in. kontakt na indeksach 298/299, 17 baniek, pusty świat, kasowanie adjacency, poprawną liczbę korekcji, zewnętrzne edycje, insert/removal ID i zero ponownych uploadów 300 baniek.
- Wszystkie shadery skompilowane offline jako `ios-metal2.3`, target iOS 16.0 przez Xcode 26.6. Redukcje korzystają ze zwykłej pamięci threadgroup, bez intrinsics nowszych rodzin GPU.
- Końcowe twarde sprawdzenie containment i mechanizm odrzucania całej niepoprawnej klatki pozostają aktywne.

Ostatni pomiar iPhone'a X przed tą zmianą wynosił `19.0684 ms` pełnej klatki p95. Ta optymalizacja wymaga niezależnego review, a następnie pomiaru `stress-300`, limit 4, 30/300 na iPhonie przez Xcode 26.6. Wyniki Maca nie oznaczają jeszcze zaliczenia docelowych 10 ms na iPhonie ani oceny wizualnego „fun”.
