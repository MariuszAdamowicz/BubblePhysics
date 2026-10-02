# Benchmark solvera referencyjnego na iPhonie X

## Narzędzia

Na tym Macu używamy `/Applications/Xcode-26.6.app`. Jest to wcześniejsza z dwóch uruchamialnych instalacji Xcode i ta wersja służyła do pracy z iPhonem X z iOS 16.7.16. Nie otwieramy projektu w domyślnym `/Applications/Xcode.app` (Xcode 27.0). Pobrany Xcode 16.4 nie jest zgodny z zainstalowanym macOS 26 i nie może być użyty.

Weryfikacja kompilacji bez podpisu:

```bash
DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer \
  xcodebuild \
  -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj \
  -scheme BubblePhysicsBench \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## Pomiar

1. Otwórz `BubblePhysicsBench.xcodeproj` w Xcode 26.6 i uruchom aplikację na iPhonie X.
2. Wybierz tryb `CPU`, liczbę `300` oraz najpierw `Sweep`.
3. Naciśnij `Start`. Pomiar wykonuje 30 kroków rozgrzewki i 300 mierzonych kroków. Przycisk `Stop` przerywa pracę pomiędzy krokami.
4. Powtórz pomiar dla `AABB tree`.
5. Przekaż oba kompletne raporty: p50/p95 klatki i faz, kandydatów, kontakty, TOI, penetrację, iteracje, limity, korekty strony i `non-finite`.

Publikacja postępu jest ograniczona do czterech aktualizacji na sekundę. Pomiar CPU jest punktem odniesienia poprawności i porównania indeksów, bez progu zaliczenia. Docelowy próg `p95 <= 16,67 ms` dotyczy przyszłego pełnego backendu Metal dla 300 baniek na fizycznym iPhonie X.

## Wyniki

Wyniki pomiaru na urządzeniu nie zostały jeszcze wpisane.
