# Prototyp radialnej bańki — odbiór na iPhone X

## Cel

Sprawdzić na fizycznym iPhonie X pierwszą wersję nowego modelu: jeden punkt masy,
bezmasowe czujniki powierzchni, wzrost od stanu całkowicie ściśniętego oraz
kontakt ze ścianami i kinematycznym trójkątem.

## Weryfikacja automatyczna

- test długotrwały: 10 000 kroków obejmujących wzrost, nacisk ściany,
  przytrzymanie trójkątem i zwolnienie;
- warunki: brak przepełnienia bufora, brak wartości niefinitywnych, nieujemne
  długości promieni, ograniczona energia i uspokojenie ruchu po zwolnieniu;
- build iOS: Debug oraz Release dla `generic/platform=iOS` w Xcode 26.6.

## Procedura na urządzeniu

1. Otworzyć `BubblePhysicsBench.xcodeproj` w Xcode 26.6 i wybrać
   `iPhone (Mariusz)`.
2. Uruchomić scenę `Radial` i obserwować ją nieprzerwanie co najmniej 60 sekund.
3. Włączyć `Punkty`, aby sprawdzić uporządkowanie czujników powierzchni.
4. Zatrzymać i wznowić trójkąt przełącznikiem `Pauza △`, następnie użyć `Reset`.
5. Zanotować poniższe wartości po ustabilizowaniu ruchu.

## Wyniki urządzenia

Status techniczny: **proces działał ponad 60 sekund bez zakończenia ani błędu
Metal**. Xcode raportował 60 FPS, 41,7–41,8 MB pamięci i niski wpływ energetyczny.

Status fizyki wizualnej: **oczekuje na pomiar aplikacji i ocenę CEO**.

| Metryka | Wynik |
| --- | --- |
| FPS | 60 (miernik Xcode); wartość z nakładki oczekuje |
| p50 / p95 | — |
| GPU frame | — |
| Liczba czujników | — |
| Promień min. / średni / maks. | — |
| Prędkość środka | — |
| Prędkość kątowa | — |
| Maksymalny nacisk | — |
| Overflow / non-finite | — |

## Ocena jakościowa CEO

| Zachowanie | Ocena |
| --- | --- |
| Wzrost od punktu | oczekuje |
| Ściskanie przez granice | oczekuje |
| Nacisk kinematycznego trójkąta | oczekuje |
| Powrót po zwolnieniu nacisku | oczekuje |
| Przesunięcie punktu masy | oczekuje |
| Obrót etykiety wraz z bańką | oczekuje |

Prototypu nie uznaje się za zaakceptowany fizycznie bez tej oceny wizualnej.
