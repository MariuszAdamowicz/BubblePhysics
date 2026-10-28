# Bugfix: dostępność sterowania benchmarkiem na iPhonie X

**Data:** 2026-10-28

**Status:** Approved

**Artefakt:** `bugfix`

**Wersja pluginu:** 0.1.29

**Sesje agenta:** unknown: UNKNOWN

---

## Analiza przyczyny źródłowej

- **Objaw:** Na fizycznym iPhonie X benchmark pokazuje jedynie fragment tekstu, a przycisk `Start` nie jest widoczny bez przewinięcia.
- **Reprodukcja:** Uruchomiono Release `BubblePhysicsBench` na destination `iPhone (Mariusz)` przez `/Applications/Xcode-26.6.app`; CEO zaobserwował niewidoczny przycisk i obcięty widok.
- **Przyczyna:** `Benchmarks/iOS/BubblePhysicsBench/App/PublicWorldStressView.swift:23` umieszcza w pionowym `ScrollView` stały `StressDrawableView` o wysokości 700 pt przed kontrolkami. Na iPhonie X dostępna wysokość ekranu jest mniejsza od sumy tekstu, postępu, 700 pt drawable, odstępów i przycisków, dlatego kontrolki zaczynają się poza początkowym viewportem.
- **Dowody:** Kod deklaruje kolejność tekst → progress → `.frame(width: 375, height: 700)` → `Start`/`Stop`; obserwacja CEO wystąpiła na docelowym urządzeniu po poprawnym uruchomieniu Release. Właściwy Xcode 26.6 rozpoznaje urządzenie jako `iPhone (Mariusz)`.
- **Wykluczono:** Problem nie wynika z niewłaściwego Xcode ani braku urządzenia: build Release z Xcode 26.6 przeszedł, a aplikacja została uruchomiona na iPhonie X. Nie wynika też z benchmarku Metal — symptom pojawia się przed uruchomieniem pomiaru.
- **Otwarte warunki:** Należy po poprawce potwierdzić na tym samym iPhonie X, że `Start` jest widoczny bez scrollowania i że drawable nadal dostarcza bieżący drawable do pomiaru prezentacji.
- **Zweryfikowano:** Przegląd układu oraz uruchomienie Release na fizycznym urządzeniu 2026-10-28; brak trwałej instrumentacji diagnostycznej.

## Projekt poprawki

### Co ma być prawdą po poprawce

- [ ] B1: Automatyczny test układu dowodzi, że pierwsza widoczna zawartość benchmarku zawiera kontrolkę `Start` niezależnie od rozmiaru drawable i nie wymaga stałej wysokości 700 pt. · `verify: swift test --filter PublicWorldStressViewLayoutTests.testStartControlPrecedesResizableDrawable`
- [ ] B2: Na fizycznym iPhonie X `Start` jest dostępny bez przewijania, a po jego użyciu benchmark nadal otrzymuje drawable i rozpoczyna 1680-klatkowy pomiar. · `verify: manual-device — Release iPhone X, screenshot przed startem oraz raport benchmarku po 1680 klatkach`

### Podejście i granice

- **Miejsce poprawki:** `Benchmarks/iOS/BubblePhysicsBench/App/PublicWorldStressView.swift:15-33`.
- **Minimalne podejście:** Przenieść sterowanie i postęp przed skalowalny drawable oraz dopasować drawable do dostępnego obszaru zamiast wymuszać 375×700, bez zmiany scenariuszy, liczników ani protokołu telemetrycznego.
- **Poza zakresem:** Zmiana silnika fizyki, kontraktu telemetryki, scenariuszy benchmarku, modeli areny oraz UI produktu 2KBubbles.

### Zadania implementacji

1. Dodać i obserwować czerwony test reprodukujący kolejność kontrolki i resizowalność drawable benchmarku. · `verify: swift test --filter PublicWorldStressViewLayoutTests.testStartControlPrecedesResizableDrawable`
2. Wprowadzić minimalną poprawkę SwiftUI, po której test jest zielony, build Release działa, a na iPhonie X `Start` i postęp są widoczne przed drawable. · `verify: DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -configuration Release -destination 'id=e7cdbee72f005b19f554e4c3675383f3dbea4c0c' build`

### Decyzje

| ID | Decyzja | Opcje | Wybór i dowód |
| --- | --- | --- | --- |
| BF-1 | Widoczność sterowania | pozostawić scroll; przenieść kontrolki przed drawable; zmniejszyć stały drawable | Przenieść kontrolki przed resizowalny drawable: usuwa przyczynę na iPhonie X i nie ukrywa sterowania za długim render targetem. |

## Odchylenia implementacji

| # | Zadanie | Typ | Opis | Status |
| --- | --- | --- | --- | --- |

## Dowody implementacji

| Element | Dowód |
| --- | --- |
| Analiza B1 | Obserwacja Release na iPhonie X i kod `PublicWorldStressView.swift:15-33`. |
