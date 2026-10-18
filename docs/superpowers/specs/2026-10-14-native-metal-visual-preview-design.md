# Podgląd wizualny GPU-native BubblePhysics

## Cel

Umożliwić CEO ocenę elastyczności i „fun” technicznie zaakceptowanego backendu `native-metal` na fizycznym iPhonie. Ekran ma prezentować dokładnie opublikowany stan `NativeMetalWorldRunner`, a nie historyczny prototyp CPU ani aproksymację konturu.

## Zakres

- Nowy ekran `Wizualizacja GPU native` dostępny z głównego ekranu benchmarku obok zachowanej `Wizualizacji CPU`.
- Domyślna scena `interactive-24`, limit 4; opcjonalnie przełącznik sceny `24/300` oraz pauza, reset i Start/Stop.
- Każdy tick czasu rzeczywistego wywołuje `NativeMetalWorldRunner.step`, rysuje `runner.contours` i używa opublikowanych baniek/kontaktów tego samego kroku.
- Przeciągnięcie steruje tym samym ruchomym wielokątem sceny, co benchmark; nie tworzy alternatywnej fizyki ani osobnego modelu CPU.
- Overlay pokazuje tylko dane istotne do oceny: backend, iteracje, kontakty, fallback reason, containment/non-finite oraz ostatni czas GPU. Fallback jest wyraźnie widoczny.

## Granice

- Nie zmienia solvera, konfiguracji benchmarku, podpisu Xcode ani kontraktu fallbacku.
- Nie tworzy nowego command buffera ani nie dodaje synchronizacji host–GPU poza normalnym `step` runnera.
- Nie jest benchmarkiem: ekran nie raportuje percentyli ani nie służy jako dowód bramki wydajności.
- Historyczny ekran CPU pozostaje dostępny dla porównania, ale jego etykieta musi jasno wskazywać backend.

## Poprawność i testy

- Testy modelu preview sprawdzają domyślny limit 4, przełączenie sceny/reset oraz atomową publikację konturów GPU.
- Test integracyjny sprawdza, że fallback nie jest opisany jako `native-metal` i że overlay zawiera jego powód.
- Build Release iOS wykonywany jest wyłącznie Xcode 26.6 bez modyfikacji ustawień podpisu.

## Kryterium akceptacji

Na iPhonie użytkownik widzi sprężyste kontury oraz ruch przeszkody z aktualnego solvera GPU-native; overlay przez normalną pracę wskazuje `native-metal`, bez fallbacku, containment i non-finite. CEO dokonuje później jakościowej oceny „fun”.
