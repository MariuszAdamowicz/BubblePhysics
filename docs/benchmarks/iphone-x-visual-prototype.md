# Prototyp wizualny — weryfikacja na iPhonie X

## Uruchomienie

1. Otwórz `Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj` w Xcode 26.6 (nie w Xcode 27).
2. Wybierz schemat `BubblePhysicsBench` i podłączony iPhone X.
3. Uruchom aplikację przyciskiem Run. Projekt zachowuje lokalnie wybrany zespół podpisujący.

## Kontrola sceny 40 baniek

- Przesuń bańkę powoli w wolnej przestrzeni: chwyt powinien reagować szybko, bez skoku.
- Przesuń ją gwałtownie: cel powinien być filtrowany, a plansza nie powinna eksplodować.
- Wciśnij bańkę w skupisko: ruch powinien zwolnić, deformacja i opór powinny być widoczne.
- Puść bańkę: powinna odzyskać kształt bez drgań i wartości non-finite.
- Sprawdź obrót napisów wraz z materialną osią baniek.
- Zatrzymaj i wznów trójkąt; sprawdź wypychanie oraz przekazywanie ruchu.
- Włącz `Punkty` i sprawdź zgodność punktów brzegowych z widocznym konturem.

## Pomiary

Po co najmniej 300 ustabilizowanych klatkach przepisz wartości z ekranu:

| Scena | FPS | p50 [ms] | p95 [ms] | Overflow | Non-finite | Uwagi |
|---|---:|---:|---:|---|---|---|
| 40 baniek — build `6a911d4` | 7 | 137,12 | 880,61 | nie | nie | wynik odrzucony: wycinki kół zamiast konturów, zawieszenie po pewnym czasie; kontur 267,06 ms, render 0,93 ms, 921 punktów, 881 segmentów, 19 kontaktów |
| 300 baniek — build `6a911d4` | — | — | — | — | — | zawieszenie natychmiast po przełączeniu; brak wiarygodnego pomiaru |
| 40 baniek — build po naprawie | — | — | — | — | — | oczekuje na ponowny pomiar urządzenia |
| 300 baniek — build po naprawie | — | — | — | — | — | oczekuje na ponowny pomiar urządzenia |

## Diagnoza pierwszego uruchomienia

- centrum używane przez renderer odrywało się od środka konturu, co tworzyło bardzo długie trójkąty;
- wachlarz trójkątów nie był poprawnym sposobem wypełniania mocno wklęsłych konturów;
- liczenie kontaktów wykonywało zbyt dużo pracy seryjnej, a korekty wielu kontaktów były sumowane bez uśrednienia;
- aplikacja mogła wysłać kilka klatek jednocześnie do tych samych trwałych buforów GPU.

Build do ponownej próby używa równoległego narrow phase, uśrednionych i ograniczonych korekt kontaktów, wypełniania konturów regułą parzystości przez stencil oraz najwyżej jednej klatki w locie.

## Kryterium

- brak overflow i non-finite;
- p95 pełnej klatki nieprzekraczające 16,67 ms dla celu 60 FPS;
- brak eksplozji układu przy gwałtownym geście;
- czytelna deformacja, opór i spokojny powrót po puszczeniu.
