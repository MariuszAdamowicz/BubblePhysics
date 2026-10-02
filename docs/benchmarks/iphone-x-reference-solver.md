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

| Bańki | Broad phase | p50 [ms] | p95 [ms] | Broad p95 [ms] | Kontakty p95 [ms] | Solver p95 [ms] | Kandydaci | Kontakty trwałe | Maks. penetracja | Limity / 30 | CCD limity | Korekty strony | Non-finite |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| 40 | Sweep | 0,5980 | 0,6711 | 0,0042 | 0,0469 | 0,6299 | 32 | 48 | 5,09325 | 30 | 0 | 0 | nie |
| 40 | AABB tree | 0,6107 | 0,6794 | 0,0190 | 0,0450 | 0,6285 | 32 | 48 | 5,09325 | 30 | 0 | 0 | nie |
| 300 | Sweep | 7,0906 | 7,2735 | 0,0662 | 0,5486 | 6,6998 | 745 | 542 | 2,62395 | 30 | 0 | 0 | nie |
| 300 | AABB tree | 7,3644 | 7,5336 | 0,2662 | 0,5545 | 6,7503 | 745 | 542 | 2,62395 | 30 | 0 | 0 | nie |
| 1000 | Sweep | 19,5210 | 20,9407 | 0,2533 | 1,9085 | 18,7804 | 2269 | 1162 | 0,58424 | 30 | 0 | 0 | nie |
| 1000 | AABB tree | 20,6855 | 26,0763 | 1,1146 | 2,0590 | 23,2170 | 2269 | 1162 | 0,58424 | 30 | 0 | 0 | nie |

Oba indeksy zwróciły identyczne liczniki kandydatów i kontaktów. Sweep-and-prune był szybszy we wszystkich trzech lokalnych scenach. Po naprawieniu ponownego wyznaczania kontaktów wewnątrz iteracji każda z mierzonych klatek wykorzystała limit 12 iteracji. To świadomie widoczny koszt poprawności solvera referencyjnego, a nie wynik docelowego backendu. Przed implementacją Metal trzeba ocenić na urządzeniu zarówno zachowanie układu, jak i potrzebną strategię zbieżności.

Wyniki pomiaru na fizycznym iPhonie X nie zostały jeszcze wpisane.
