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
| 40 | Sweep | 0,6615 | 0,7167 | 0,0027 | 0,0519 | 0,6485 | 32 | 48 | 5,09325 | 30 | 0 | 0 | nie |
| 40 | AABB tree | 0,6601 | 0,7873 | 0,0200 | 0,0456 | 0,7313 | 32 | 48 | 5,09325 | 30 | 0 | 0 | nie |
| 300 | Sweep | 8,5955 | 8,7828 | 0,0717 | 0,5603 | 8,1640 | 721 | 566 | 3,11850 | 30 | 0 | 0 | nie |
| 300 | AABB tree | 8,8079 | 9,0064 | 0,3063 | 0,5796 | 8,1816 | 721 | 566 | 3,11850 | 30 | 0 | 0 | nie |
| 1000 | Sweep | 24,7797 | 26,0664 | 0,2474 | 2,1002 | 23,7781 | 2257 | 1164 | 0,83170 | 30 | 0 | 0 | nie |
| 1000 | AABB tree | 26,2650 | 28,3957 | 1,1855 | 2,2112 | 24,9226 | 2257 | 1164 | 0,83170 | 30 | 0 | 0 | nie |

Oba indeksy zwróciły identyczne liczniki kandydatów i kontaktów. Sweep-and-prune był szybszy we wszystkich trzech lokalnych scenach. Po naprawieniu ponownego wyznaczania kontaktów wewnątrz iteracji każda z mierzonych klatek wykorzystała limit 12 iteracji. To świadomie widoczny koszt poprawności solvera referencyjnego, a nie wynik docelowego backendu. Przed implementacją Metal trzeba ocenić na urządzeniu zarówno zachowanie układu, jak i potrzebną strategię zbieżności.

Wyniki pomiaru na fizycznym iPhonie X nie zostały jeszcze wpisane.
