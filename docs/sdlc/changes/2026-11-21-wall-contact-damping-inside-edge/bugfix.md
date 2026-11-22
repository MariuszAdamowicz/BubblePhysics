# Bugfix: Mała bańka dociśnięta gumką wpada środkiem w ścianę (silnik 3.0.1)

**Date:** 2026-11-21
**Artifact:** bugfix
**Status:** Approved
**Template version:** default/0.5.5
**Plugin version:** 0.7.11
**Agent Sessions:** claude-code: d85033ae-083e-4d83-9b45-0d8a2f18711d

## Root cause analysis

**Objaw (gra 2KBubbles na 3.0.0, `main` 2e07451).** Najmniejsza bańka („2”, r 24) dociśnięta gumką do ściany pełną siłą 1200 zostaje na stałe w ε 0,9999 (środek na krawędzi ściany) zamiast w ε = c₀ · F / r_ref = 0,648. Bańki „3”–„5” mają szczyt 0,74–0,92 i wracają do 0,648. Strojenie gry: c₀ 0,0108, r_ref 20, ζ_c 5, gumka K_band 30, F_max 1200, γ 5,0 / 1,3 / 0,6. Pełny opis wejściowy: `/Users/adamowim/priv/ios/2KBubbles-iOS/docs/benchmarks/stage-0/v3.0.0/engine-3.0.1-input.md`.

Rachunek: ściana to sprężyna K = 1/c dociśnięta skokowo stałą siłą F; bez tłumienia δ_max = 2 · δ_eq (ε 1,30), a przy uderzeniu z prędkością v jeszcze więcej. Bez tłumienia kontaktu każde ε_eq > 0,5 daje przejście środka za krawędź, więc strojeniem gry nie da się tego obejść.

**Przyczyna 1 — tłumienie kontaktu wyłącza się przy szybkim zderzeniu.** `nativeDampContactNormalMotion` liczy `restSpeed = max(40, 2r)` (Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source:1070) i dla `abs(normalVelocity) > restSpeed` pomija dashpot ζ_c (`continue`, :1090). Bańka r 24 uderza z ok. 173 j/s przy progu 48, więc całe zderzenie jest nietłumione (tylko γ materiału), a szczyt dochodzi do ε 1. Próg pochodzi z `e6cfa55 fix: stabilize native contact relaxation`; komentarz (:1067-1069) uzasadnia go szybkim ruchem kinematycznej przeszkody. Próg jest tylko w ścieżce natywnej (grep `restSpeed` w `Sources` daje wyłącznie te dwie linie).

**Przyczyna 2 — krawędź przestaje odpychać, gdy przewidziany środek jest za nią.** `nativePredict` zapisuje środek z początku kroku w `position.zw` (NativeGeometryKernels.metal-source:172) i przesuwa środek o `v · dt` (:178), a `nativeBuildContacts` (:661) buduje kontakty z tej przewidzianej pozycji. `nativePolygonEdgeFeature` (:651-658) daje wnętrze krawędzi (cecha 1) tylko przy `dot(center − start, outward) ≥ 0` (:657). Gdy bańka jedzie w ścianę szybciej, niż jej środek jest od krawędzi w jednym kroku, przewidziany środek leży za krawędzią → cecha 0 → `penetration = −FLT_MAX` (:698) → rekord odpada w kompaktowaniu, a rekord z cache jest wyłączany w `nativeEmitAdjacency` (NativeXPBDKernels.metal-source:299-302). Strażnik środka (`nativeApplyCenterGuards`, NativePostSolveKernels.metal-source:275) cofa środek na krawędź, ale ściana już nie odpycha, gumka dalej pcha, więc bańka stoi w ε ≈ 1, a jej prędkość w stronę ściany rośnie (−65 → −106 j/s w śladzie niżej). Kolejny krok zaczyna się z tym samym stanem — błąd jest trwały.

**Verified:** tymczasowy test `ZZReproWallTests` (niżej, usunięty z drzewa), `swift test --filter ZZReproWallTests`, trzy przebiegi:

Przebieg A — kod 3.0.0 bez zmian:

```
REPRO r=24.0 γ=5.0 ζ=5.0 gap=150.0: impact≈172.79599 peak ε=0.99991673 @75 final ε=0.99991673
REPRO trace 62:-0.031/v-173 63:0.088/v-171 64:0.204/v-167 65:0.315/v-161 66:0.421/v-153 67:0.521/v-143 68:0.613/v-132 69:0.696/v-121 70:0.772/v-109 71:0.838/v-96 72:0.896/v-83 73:0.944/v-70 74:0.984/v-57 75:1.000/v-65 76:1.000/v-71 77:1.000/v-77 78:1.000/v-82 79:1.000/v-86 80:1.000/v-90 81:1.000/v-93 82:1.000/v-97 83:1.000/v-99 84:1.000/v-102 85:1.000/v-104 86:1.000/v-106
REPRO r=24.0 γ=5.0 ζ=5.0 gap=0.0: impact≈0.0 peak ε=0.64757985 @359 final ε=0.64757985
REPRO r=24.0 γ=5.0 ζ=0.0 gap=0.0: impact≈0.0 peak ε=0.81613284 @26 final ε=0.64800197
REPRO r=40.0 γ=5.0 ζ=5.0 gap=150.0: impact≈62.53457 peak ε=0.49435464 @359 final ε=0.49435464
REPRO r=148.0 γ=0.6 ζ=5.0 gap=50.0: impact≈29.368917 peak ε=0.600612 @3599 final ε=0.600612
```

Przebieg B — hipoteza 1, tylko `:1090` zmienione na `if (record.compliance.x <= 0 && abs(normalVelocity) > restSpeed) continue;`: szybka bańka r 24 osiada w 0,6468 bez przestrzału, reszta bez zmian.

```
REPRO r=24.0 γ=5.0 ζ=5.0 gap=150.0: impact≈172.79599 peak ε=0.6467533 @359 final ε=0.6467533
REPRO r=24.0 γ=5.0 ζ=5.0 gap=0.0: impact≈0.0 peak ε=0.64757985 @359 final ε=0.64757985
REPRO r=24.0 γ=5.0 ζ=0.0 gap=0.0: impact≈0.0 peak ε=0.81613284 @26 final ε=0.64800197
REPRO r=40.0 γ=5.0 ζ=5.0 gap=150.0: impact≈62.53457 peak ε=0.49435464 @359 final ε=0.49435464
REPRO r=148.0 γ=0.6 ζ=5.0 gap=50.0: impact≈29.368917 peak ε=0.600612 @3599 final ε=0.600612
```

Przebieg C — hipoteza 2, tłumienie jak w 3.0.0, w `:657` usunięty warunek `dot(center − start, outward) >= 0`: krawędź odpycha środek za sobą i r 24 wraca do 0,649 — ale bańka r 148 (δ = c · F ≈ 96 > T 48) zostaje wciągnięta w ścianę do ε 1,0, bo tylna krawędź ściany też daje kontakt (środek jest „za” nią) z normalną w głąb ściany. To dowód, że naiwne zniesienie warunku strony przywraca zakazany błąd dwustronny z 2.3.0 (i gorzej):

```
REPRO r=24.0 γ=5.0 ζ=5.0 gap=150.0: impact≈172.79599 peak ε=0.99991673 @75 final ε=0.6491146
REPRO trace 62:-0.031/v-173 ... 74:0.984/v-57 75:1.000/v-13 76:1.000/v-1 77:0.996/v2 78:0.989/v3 79:0.983/v3 80:0.976/v3 ...
REPRO r=148.0 γ=0.6 ζ=5.0 gap=50.0: impact≈29.368917 peak ε=0.99998647 @2091 final ε=0.99998647
```

Test reprodukcji (był w `Tests/BubblePhysicsRuntimeTests/ZZReproWallTests.swift`, ściana lewa ramy `CrowdScene`, T 48):

```swift
import BubblePhysics
import XCTest

@MainActor
final class ZZReproWallTests: XCTestCase {
    private func run(radius: Float, gamma: Float, zeta: Float, gap: Float, seconds: Double = 6) async throws {
        let world = try BubbleWorld(configuration: CrowdScene.configuration())
        var setup = try CrowdScene.resources(bubble: CrowdScene.softBubblePhysics(base: 0.0108, referenceRadius: 20, damping: gamma, dampingRatio: zeta))
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        let policy = try BubbleDrivePolicy(bandStiffness: 30, maximumForce: 1200)
        let start = WorldPoint(-CrowdScene.interiorHalfSize.x + radius + gap, 0)
        _ = world.submit(try setup.add(CrowdScene.bubble(1, at: start, radius: radius, drivePolicy: policy))
            .beginPlayerDrive(CrowdScene.id(1), target: WorldPoint(-2000, 0)))
        var peak: Float = -1, peakStep = 0, last: Float = 0, impact: Float = 0
        var trace: [String] = []
        for i in 0..<Int(seconds * 60) {
            let frame = await world.advance(by: CrowdScene.step)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue)
            let s = try XCTUnwrap(frame.objects[CrowdScene.id(1)])
            let eps = CrowdScene.wallDepth(of: s, targetRadius: radius) / radius
            if eps < 0 { impact = abs(s.velocity.x) }
            if eps > peak { peak = eps; peakStep = i }
            last = eps
            if eps > -0.05 && trace.count < 25 { trace.append(String(format: "%d:%.3f/v%.0f", i, eps, s.velocity.x)) }
        }
        print("REPRO r=\(radius) γ=\(gamma) ζ=\(zeta) gap=\(gap): impact≈\(impact) peak ε=\(peak) @\(peakStep) final ε=\(last)")
        print("REPRO trace " + trace.joined(separator: " "))
    }

    func testRepro() async throws {
        try await run(radius: 24, gamma: 5, zeta: 5, gap: 150)
        try await run(radius: 24, gamma: 5, zeta: 5, gap: 0)
        try await run(radius: 24, gamma: 5, zeta: 0, gap: 0)
        try await run(radius: 40, gamma: 5, zeta: 5, gap: 150)
        try await run(radius: 148, gamma: 0.6, zeta: 5, gap: 50, seconds: 60)
    }
}
```

**Otwarte warunki wstępne.** Reguła krawędzi wejścia (BF-D-1) zakłada, że strażnik środka zostawia środek po zewnętrznej stronie krawędzi albo dokładnie na niej (zmierzone: ε 0,99991, środek 0,002 przed krawędzią), tak by w następnym kroku `position.zw` był przed krawędzią. Jeśli strażnik zostawi środek choć trochę za prostą krawędzi, kontakt nie wróci — test z zadania 1 to wykrywa.

**Wykluczone.**
- Backendy referencyjne (`BubblePhysicsReference`, `BubblePhysicsReferenceMetal`): progu `restSpeed` nie mają, a świat publiczny (`BubbleWorld`) używa ścieżki natywnej — poprawka dotyczy tylko `BubblePhysicsNativeMetal`.
- Powolne dochodzenie dużej bańki (r 148: ε 0,601 po 60 s, w grze 0,6375 po 90 s) to fizyka strojenia, nie błąd: przy ζ_c 5 kontakt jest silnie nadkrytyczny i wolny mod pełznie ze stałą τ ≈ 2 · ζ_c · √(m · c) ≈ 2 · 5 · √(54,8 · 0,080) ≈ 21 s, co zgadza się z pomiarem. Uderzenie r 148 (29 j/s) jest poniżej progu, więc przyczyna 1 go nie dotyczy. Poza zakresem (BF-D-3).
- Strojenie gry jako obejście: γ 19 / 4,7 / 0,75 usuwa przejście, ale bańka „2” jedzie 44 j/s i automatyczny gracz nie kończy gry (opis wejściowy).

## Fix design

### Why & what

Model fizyki autora: kontakt miękki to sprężyna z tłumieniem, która tłumi zawsze; środek bańki nigdy nie zostaje za krawędzią bryły sztywnej, a gdyby przewidziany środek ją minął, odpycha go dokładnie jedna krawędź — ta, przez którą wszedł — wzdłuż jej normalnej zewnętrznej, bez powrotu do dwustronnych krawędzi z 2.3.0.

- [ ] Szybka mała bańka (r 24, strojenie gry, start 150 od ściany, uderzenie ok. 173 j/s) osiada w ε 0,648 ± 2 %, szczyt ε < 1, a żaden krok nie kończy się ze środkiem za krawędzią ściany; przed poprawką test pada (ε 0,9999) · `verify: swift test --filter WallImpactTests — przed poprawką czerwony, po zielony`
- [ ] Bańka, której przewidziany środek mija krawędź (dashpot wyłączony, ζ_c 0, szybkie uderzenie), jest wypychana przez tę krawędź i osiada w c · F, zamiast stać w ε ≈ 1 · `verify: swift test --filter WallImpactTests`
- [ ] Cienka ściana nadal odpycha tylko czołem: bańka r 148 przy T 48 ugina się o c · F jak przy T 400, a szybka bańka r 12 nie kończy kroku w ścianie · `verify: swift test --filter StaticPolygonEdgeTests`
- [ ] Kontakty twarde (c₀ = 0) zachowują się jak w 3.0.0 poza krawędzią wejścia (BF-D-4); pozostałe testy bez zmian oczekiwań poza dwoma wyjątkami zatwierdzonymi przez użytkownika (BF-D-4, BF-D-5) · `verify: swift test — cały zestaw zielony`
- [ ] CHANGELOG ma sekcję `## 3.0.1` opisującą obie poprawki · `verify: grep -n "## 3.0.1" CHANGELOG.md`

### How - Program design

Dwie zmiany w shaderach `BubblePhysicsNativeMetal`, bez zmian ABI.

**Tłumienie (BF-D-2).** W `nativeDampContactNormalMotion` warunek pominięcia dashpotu (NativeXPBDKernels.metal-source:1090) obowiązuje tylko dla kontaktu twardego: `if (record.compliance.x <= 0 && abs(normalVelocity) > restSpeed) continue;`. Kontakt miękki (`compliance.x > 0`) tłumi zawsze, także z kinematyczną przeszkodą — dashpot działa na prędkość względną, więc szybka przeszkoda przekazuje bańce swój ruch zamiast go hamować. Komentarze przy `restSpeed` (:1067-1069) i przy restytucji (:1083-1084) dopisać tak, by mówiły, że próg dotyczy tylko kontaktu twardego, i dlaczego.

**Krawędź wejścia (BF-D-1).** `nativePolygonEdgeFeature` (NativeGeometryKernels.metal-source:651-658) dostaje środek z początku kroku (`a.position.zw`, zapisany w `nativePredict` :172) jako dodatkowy argument. Wnętrze krawędzi (cecha 1) powstaje, gdy rzut przewidzianego środka wypada wewnątrz odcinka (`along > 0 && !nativePastSegmentEnd(...)`, jak dziś) oraz przewidziany środek jest po zewnętrznej stronie prostej krawędzi **albo** środek z początku kroku był po jej zewnętrznej stronie (`dot(previous − start, outward) ≥ 0`). Tylna krawędź cienkiej ściany nie dostaje kontaktu nigdy, bo środek nigdy nie był przed nią. Gałąź wierzchołka wypukłego (cecha 2, :656) bez zmian. Wywołanie w `nativeBuildContacts` (:688) przekazuje `a.position.zw`. Dalszy kod już obsługuje środek za krawędzią: wgniecenie `r − dot(center − start, outward)` (:691, oraz `nativeConstraintGeometry` dla cechy 1, NativeXPBDKernels.metal-source:425-426) staje się większe niż r przy ujemnym iloczynie, z normalną zewnętrzną. Komentarze nad `nativePolygonEdgeFeature` (:648-650) i w `nativeBuildContacts` (:686) uzupełnić o regułę krawędzi wejścia. Strażnik środka (`nativeApplyCenterGuards`, NativePostSolveKernels.metal-source:275) zostaje bez zmian: nadal natychmiast cofa środek na stronę wejścia, więc żaden krok nie kończy się ze środkiem za krawędzią.

**Testy.** Nowy plik `Tests/BubblePhysicsRuntimeTests/WallImpactTests.swift` ze sceną jak w `ZZReproWallTests` (rama `CrowdScene`, `CrowdScene.softBubblePhysics(base: 0.0108, referenceRadius: 20, damping:, dampingRatio:)`, `BubbleDrivePolicy(bandStiffness: 30, maximumForce: 1200)`, cel `(-2000, 0)`, ε = `CrowdScene.wallDepth / r`). Istniejące `StaticPolygonEdgeTests` (`testThinWallDeflectsByTheFrontEdgeOnlyAndTheSameAsAThickWall` :82, `testFastBubbleNeverEndsAStepInsideOrBehindTheWall` :282) pilnują braku regresji dwustronnej.

**Wydanie.** `CHANGELOG.md`: nowa sekcja `## 3.0.1` z podsekcją `### Naprawione` nad `## 3.0.0`.

### Plan

1. Test czerwony: `Tests/BubblePhysicsRuntimeTests/WallImpactTests.swift` — (a) r 24, γ 5, ζ_c 5, start 150 od ściany: końcowe ε 0,648 ± 2 % po 6 s, szczyt < 1, w każdym kroku środek przed krawędzią (`CrowdScene.wallDepth < r`); (b) to samo z ζ_c 0 i r 24: końcowe ε 0,648 ± 2 % po 6 s (wymaga krawędzi wejścia, bo bez dashpotu przewidziany środek mija krawędź) · `verify: swift test --filter WallImpactTests — oba testy czerwone na kodzie 3.0.0 (ε ≈ 0,9999)`
2. Tłumienie zawsze dla kontaktu miękkiego: `NativeXPBDKernels.metal-source:1090` i komentarze :1067-1069, :1083-1084 · `verify: swift test --filter WallImpactTests — test (a) zielony`
3. Krawędź wejścia: `nativePolygonEdgeFeature` z argumentem środka z początku kroku, wywołanie w `nativeBuildContacts`, komentarze (`NativeGeometryKernels.metal-source:648-658`, :686-688) · `verify: swift test --filter WallImpactTests — oba zielone; swift test --filter StaticPolygonEdgeTests — zielone`
4. Regresja: `swift test --filter "ContactComplianceTests|BandDriveTests|CrowdCompressionTests|ContactContourTests|MotionDampingTests"`, potem cały zestaw · `verify: swift test — 0 failures; każdą zmianę oczekiwań w istniejącym teście opisać w tabeli odstępstw z powodem`
5. `CHANGELOG.md`: sekcja `## 3.0.1` / `### Naprawione` — tłumienie ζ_c kontaktu miękkiego niezależne od prędkości zbliżania; krawędź wielokąta statycznego odpycha środek, który przeszedł przez nią w kroku (krawędź wejścia, jedna) · `verify: grep -n "## 3.0.1" CHANGELOG.md`

### Decisions

| ID | Title | Context | Options | Choice | Rationale | Source | Consequences |
|----|-------|---------|---------|--------|-----------|--------|--------------|
| BF-D-1 | Która krawędź odpycha środek za krawędzią | Przewidziany środek za krawędzią daje cechę 0 i brak kontaktu; trzeba wybrać dokładnie jedną krawędź | (a) krawędź wejścia: środek z początku kroku (`position.zw`) był przed krawędzią; (b) krawędź z historii kontaktu w `nativeMatchContactCache` (zmiany w budowie, kompaktowaniu i dopasowaniu); (c) najbliższa krawędź wielokąta (wymaga wszystkich krawędzi w jądrze, na cienkiej ścianie przy głębokości > T/2 wypycha na drugą stronę); (d) samo usunięcie warunku strony | (a) | Bezstanowa, w jednej funkcji; tylna krawędź nie działa nigdy. (d) zmierzone w przebiegu C: r 148 wciągnięta w ścianę T 48 do ε 1,0 (błąd dwustronny). (b) daje ten sam wynik kosztem trzech jąder, (c) łamie się na cienkiej ścianie | user (Q1; dodał: środek nie może minąć krawędzi, ma być natychmiast wycofany — strażnik środka zostaje) | Zależy od strażnika zostawiającego środek po stronie wejścia (otwarty warunek); środek, który nigdy nie był przed krawędzią (np. wstawiony w bryłę), nadal nie dostaje kontaktu od krawędzi |
| BF-D-2 | Zakres zniesienia progu `restSpeed` | Dashpot ζ_c pomijany powyżej max(40, 2r) robi szybkie zderzenie nietłumionym | (a) wszystkie kontakty miękkie, także z kinematyczną przeszkodą, twarde bez zmian; (b) miękkie ze statyczną ścianą i bańką, z kinematyczną próg zostaje; (c) wszystkie kontakty, także twarde | (a) | Model autora: sprężyna z tłumieniem tłumi zawsze; dashpot działa na prędkość względną, więc szybka przeszkoda nie jest hamowana. Przebieg B: r 24 osiada w 0,6468 bez przestrzału. (c) zmieniłoby kontakty `.hard` względem 3.0.0 | user (Q2) | Bańka przy szybkiej kinematycznej przeszkodzie przejmuje jej prędkość normalną szybciej niż dotąd; kontakty twarde bez zmian |
| BF-D-3 | Powolne dochodzenie dużej bańki | r 148 osiąga 0,601 po 60 s zamiast 0,648 | (a) poza zakresem, opisane z rachunkiem τ; (b) badać szybsze dochodzenie w silniku | (a) | τ ≈ 2 · ζ_c · √(m · c) ≈ 21 s dla ζ_c 5 zgadza się z pomiarem; to strojenie gry, nie kod | user (Q3) | Testy tej poprawki sprawdzają małe bańki po czasie ≫ τ; gra może obniżyć ζ_c, teraz bezpiecznie |
| BF-D-4 | Krawędź wejścia także dla kontaktów twardych | Reguła BF-D-1 obejmuje każdą krawędź statycznego wielokąta, więc scena akceptacyjna (bańki twarde, ściany grubości 1) zmienia hashe stanu, konturów i pikseli | (a) dla wszystkich kontaktów, nowy wzorzec hashy; (b) tylko kontakty miękkie, twarde bit w bit jak 3.0.0 | (a) | reguła „środek nigdy nie zostaje za krawędzią bryły” nie zależy od podatności; bańka twarda ma ten sam błąd; cofnięcie warunku przywraca hashe 3.0.0, więc zmiana wynika tylko z BF-D-1 | user | `AcceptanceEquivalenceTests` i `AcceptanceRenderEquivalenceTests` z `referenceCommit` f65b13c; CHANGELOG wymienia zmianę dla kontaktów twardych |
| BF-D-5 | Test zawartej pary przy tłumieniu zawsze | Przy ζ_c 1 dashpot (BF-D-2) krytycznie tłumi rozprężenie pary P-B-30: mała bańka dochodzi do przeszkody najwyżej na 52,4 zamiast ≤ 32,5 | (a) test na ζ_c 0 z tym samym oczekiwaniem; (b) ζ_c 1 i nowe oczekiwanie | (a) | test sprawdza rozprężenie i stabilność świata, nie tłumienie; zachowanie przy ζ_c 1 jest zgodne z modelem „tłumi zawsze” | user | `CrowdCompressionTests.testSoftContainedPairReleasesWithoutBreakingTheWorld` używa `dampingRatio: 0`, z komentarzem |

## Implementation deviations

> *Guidance:* Left empty by bugfix; light-implement adds one row per deviation, or "None."

| #   | Task | Type (change/gap) | Description | Date |
| --- | ---- | ----------------- | ----------- | ---- |
| 1 | 1 | gap | W teście (a) asercje „szczyt < 1” i „żaden krok ze środkiem za krawędzią” przechodziły już na 3.0.0 (strażnik zostawiał ε 0,99992); czerwony był warunek końcowego ε 0,648 ± 2 % w obu testach (ε 0,99991673) | 2026-11-22 |
| 2 | 4 | change | Hashe wzorca `AcceptanceEquivalenceTests` (stan, kontury, z limitem λ pary i bez) i `AcceptanceRenderEquivalenceTests` (piksele) zmienione, `referenceCommit` f65b13c: krawędź wejścia działa też dla kontaktów twardych; kryterium kontaktów twardych poprawione za zgodą użytkownika (BF-D-4) | 2026-11-22 |
| 3 | 4 | change | `CrowdCompressionTests.testSoftContainedPairReleasesWithoutBreakingTheWorld` (P-B-30) na `dampingRatio: 0`: tłumienie zawsze (BF-D-2) krytycznie tłumi rozprężenie przy ζ_c 1 (52,4 > 32,5); za zgodą użytkownika (BF-D-5) | 2026-11-22 |
