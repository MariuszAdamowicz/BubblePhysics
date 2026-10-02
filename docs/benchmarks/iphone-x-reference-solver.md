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

Lokalny baseline wykonano w konfiguracji Release na Macu mini: 10 kroków rozgrzewki i 30 kroków pomiarowych na wariant. Nie jest to wynik iPhone'a ani próg akceptacji.

| Bańki | Broad phase | p50 [ms] | p95 [ms] | Broad p95 [ms] | Kontakty p95 [ms] | Solver p95 [ms] | Kandydaci | Kontakty trwałe | Maks. penetracja | Limity / 30 | Korekty strony | Non-finite |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| 40 | Sweep | 0,0446 | 0,0721 | 0,0065 | 0,0264 | 0,0435 | 64 | 15 | 0,00352 | 2 | 0 | nie |
| 40 | AABB tree | 0,0582 | 0,0748 | 0,0206 | 0,0242 | 0,0385 | 64 | 15 | 0,00352 | 2 | 0 | nie |
| 300 | Sweep | 0,6973 | 0,7408 | 0,0689 | 0,3360 | 0,3472 | 673 | 106 | 0,07568 | 28 | 52 | nie |
| 300 | AABB tree | 0,8696 | 0,9122 | 0,2633 | 0,3389 | 0,3504 | 673 | 106 | 0,07568 | 28 | 52 | nie |
| 1000 | Sweep | 2,4792 | 2,5353 | 0,2580 | 1,4237 | 0,9090 | 2211 | 286 | 0,67939 | 28 | 108 | nie |
| 1000 | AABB tree | 3,2345 | 3,4888 | 1,1291 | 1,4398 | 0,9153 | 2211 | 286 | 0,67939 | 28 | 108 | nie |

Oba indeksy zwróciły identyczne liczniki kandydatów i kontaktów. Sweep-and-prune był szybszy we wszystkich trzech lokalnych scenach. Częste osiąganie limitu 12 iteracji przy 300 i 1000 bańkach jest jawnie raportowaną cechą obecnego solvera referencyjnego; przed implementacją Metal trzeba ocenić wizualnie stan na urządzeniu i zdecydować, czy tolerancja/zbieżność wymaga korekty.

Wyniki pomiaru na fizycznym iPhonie X nie zostały jeszcze wpisane.
