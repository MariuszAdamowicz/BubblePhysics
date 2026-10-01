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
| 40 baniek | — | — | — | — | — | oczekuje na pomiar urządzenia |
| 300 baniek | — | — | — | — | — | oczekuje na pomiar urządzenia |

## Kryterium

- brak overflow i non-finite;
- p95 pełnej klatki nieprzekraczające 16,67 ms dla celu 60 FPS;
- brak eksplozji układu przy gwałtownym geście;
- czytelna deformacja, opór i spokojny powrót po puszczeniu.
