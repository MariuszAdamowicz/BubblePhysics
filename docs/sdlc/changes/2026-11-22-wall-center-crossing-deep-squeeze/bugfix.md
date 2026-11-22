# Bugfix: Środek za krawędzią wejścia przy mocnym docisku (3.0.2)

**Date:** 2026-11-22
**Artifact:** bugfix
**Status:** Approved
**Template version:** default/0.5.5

**Plugin version:** 0.7.11
**Agent Sessions:** claude-code: 192b6d4f-ba6c-4d50-a0f9-4837c40e32cf

## Root cause analysis

**Objaw (gra 2KBubbles na 3.0.1, tag `v3.0.1` = 1c51657).** Bramka przeciskania 4×10 pada losowo (ziarno 1: 5 z 8 przebiegów, ziarno 5: 1 z 6; na 3.0.0 0 z 12): krok odrzucony z `solverGuard` / `SolverGuardCause.centerCrossing`, gra powtarza te same wejścia aż do `stepsRejected`. Źródła: `/Users/adamowim/priv/ios/2KBubbles-iOS/docs/benchmarks/stage-0/v3.0.1/engine-3.0.2-input.md` i diagnoza ze śladami `.../v3.0.1/guard-seed1/README.md`. Ślad (`seed1-base301-repB`): bańka r 74,1337 (c = 0,04003) przy prawej ścianie x ∈ [360, 408], niechwycona, dociśnięta przez tłum siłą 2222 w stronę ściany (pięć kontaktów, Σ F·n_x). Sprężyna ściany utrzyma środek przed krawędzią tylko do F = r_ref / c₀ = 1852 (ε = c₀·F/r_ref = 1, dla każdego r), więc równowaga to ε = 1,2: środek za krawędzią. Krok 138: start 359,997986, wynik solvera 360,000031, po strażniku 359,997986. Krok 139 (odrzucony): wynik solvera dokładnie **360,000000**, po strażniku (360,000000; y + 0,0020066), bity 2|8 z warunku `:270` (8 z 8 awarii).

**Decyzja autora (2026-11-22):** środek za krawędzią to dozwolony stan modelu (mocno zgnieciona bańka). Krawędź wejścia odpycha go liniowo, bańka staje w ε = c₀·F/r_ref także dla ε > 1; bez twardnienia sprężyny i bez dwustronnych krawędzi z 2.3.0.

**Przyczyna — dwie części, obie z reguły krawędzi wejścia 3.0.1:**

1. **Krawędź wejścia działa tylko w kroku przecięcia.** `nativePolygonEdgeFeature` (`Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source:657-669`) daje cechę 1 środkowi za prostą tylko wtedy, gdy środek z początku kroku (`position.zw`) był przed prostą (`previousSide >= 0`, `:665`). Gdy środek zostaje za krawędzią dłużej niż krok, `previousSide < 0` → cecha 0 → rekord odpada w kompaktowaniu (`:710`), kontakt znika i nic już nie odpycha. Dziś ten stan nigdy nie trwa, bo strażnik (punkt 2) zawsze cofa środek przed krawędź — to cofanie jest jedynym, co trzyma bańkę przed przebiciem ściany.
2. **Strażnik środka cofa środek i degeneruje się na samej krawędzi** (`Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`):
   - `:199-202` — przejście krawędzi z zewnątrz do środka (`nativeForbiddenCenterCrossing`) jest cofane `nativeReturnToOriginalSide` na krawędź − margines (margines = 2·contactTolerance = 0,002), więc ε nie przekracza ≈ 1;
   - wynik dokładnie na prostej: `nativeCenterCrossing` nie zgłasza przejścia (znak powierzchni 0), a `nativeInsideOwner` (`:123-138`) liczy punkt na lewej krawędzi prostokąta jako wnętrze (ostre `p.x < x` w `:134`, parzystość 1);
   - rzut CD-D-17 (`:216-244`): odległość do krawędzi 0 albo szum, więc `outward = (q − p) / distance` w `:229` (próg `FLT_MIN`) wskazuje wzdłuż krawędzi; kandydat dalej leży na prostej;
   - `:270`: `testedInside` → `nativeSafetyFailure(safety, 2 | 8)`, krok odrzucony; świat wraca do stanu sprzed kroku i odrzucenie się powtarza.
   - Bez znaczenia dla tego przypadku, ale istotne dla poprawki: `:62` pomija kontrolę przejścia, gdy start leży we wnętrzu właściciela, więc wyjście środka z wnętrza przez inną (tylną) krawędź nie jest dziś sprawdzane.

**Verified:**

- *API publiczne* (scena `CrowdScene` jak w `Tests/BubblePhysicsRuntimeTests/WallImpactTests.swift`, c₀ 0,0108, r_ref 20, ζ_c 5, gumka K 30, F_max = F, cel (−2000, 0), start 20 od ściany): ε po 6 s (r 24) albo 30 s (r 74):

  ```
  REPRO r=24.0 F=1200.0 expected=0.648   final=0.6475131  issues=0 guard=0
  REPRO r=24.0 F=2222.0 expected=1.19988 final=0.99991673 issues=0 guard=0
  REPRO r=74.0 F=1200.0 expected=0.648   final=0.6246981  (jeszcze nie osiadła)
  REPRO r=74.0 F=2222.0 expected=1.19988 final=0.999973   issues=0 guard=0
  ```

  Strażnik trzyma środek na krawędzi − margines (0,002/24 → 0,99992; 0,002/74 → 0,99997), zamiast ε = 1,2.

- *Jądro strażnika uruchomione bezpośrednio* (`nativeApplyCenterGuards` skompilowane ze źródeł jak `ContainmentKernelFixture` w `Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift:30-65`; prostokąt statyczny (360,−500)…(408,500), owner 9, `NativeSolverSegment.fixed`; bańka r 74,1337, start `position.zw` = (359,998; 81,7546), prędkość (0,069; 1,036); `thresholds` = (4; 0,5; 0,001; 0,002); wynik solvera `positions` = (x; 81,7742)):

  ```
  GUARD -3ulp    end=(359.9999, 81.7742)  -> (359.9999, 81.7742) bits=0
  GUARD -1ulp    end=(359.99997, 81.7742) -> (359.99997, 81.7742) bits=0
  GUARD exact    end=(360.0, 81.7742)     -> (360.0, 500.002)    bits=10
  GUARD +1ulp    end=(360.00003, 81.7742) -> (359.998, 81.7742)  bits=0
  GUARD +3ulp    end=(360.0001, 81.7742)  -> (359.998, 81.7742)  bits=0
  GUARD +0.5     end=(360.5, 81.7742)     -> (359.998, 81.7742)  bits=0
  GUARD deep14.8 end=(374.8, 81.7742)     -> (359.998, 81.7742)  bits=0
  ```

  Dokładnie na krawędzi: środek przerzucony wzdłuż krawędzi i bity 2|8 (= 10) — odrzucenie, deterministycznie. Każdy wynik za krawędzią: cofnięcie na 359,998.

- *Hipoteza „wystarczy nie cofać”* (tymczasowo w `nativeGuardCenter`: pominięte cofanie i kontrola przejścia dla krawędzi z `flags.w & 1`, wyłączony rzut CD-D-17 i warunek `:270`; cofnięte): r 74, F 2222 — środek mija prostą (ε 1,0003, vx −1,36), w kolejnym kroku kontakt ze ścianą znika i bańka przyspiesza w głąb (vx −3,96 → −6,34 → … → −21,9 przy ε 1,039), aż opuszcza świat (`frame.objects[id]` = nil). To potwierdza część 1: bez pamięci krawędzi wejścia między krokami sama rezygnacja z cofania przebija ścianę.

**Otwarte warunki wstępne:**

- Pamięć z cache kontaktów (BF-D-1) zakłada, że `frame` w `contactControl.limits.x` rośnie o 1 na zaakceptowany krok i że rekord kontaktu z cechą 1 trafia do opublikowanego cache (`state.contactCache`) z `response.w` = 1. Do sprawdzenia w zadaniu 5; jeśli licznik rośnie inaczej, warunek „widziany w poprzednim kroku” trzeba oprzeć na tym, jak liczy go `nativeMatchContactCache` (`NativeXPBDKernels.metal-source:187-212`).
- Częstość awarii w grze (małe próby, A kontra B nierozstrzygnięte) i brak powtarzalności bit w bit na GPU — nie wpływają na diagnozę, poza zakresem 3.0.2.

**Wykluczone:**

- Zmiana A z 3.0.1 (tłumienie bez progu): sama na 3.0.0 nie odtwarza awarii (0 z 11), sama B tak (2 z 10) — diagnoza z gry.
- Błąd modelu: stan wejściowy (2222 > 1852) jest prawdziwym stanem modelu, nie szumem.
- Kontrola przejścia `:261` i jednostronny odcinek `:264`: nie zapalają się w żadnej awarii; krawędzie statycznych wielokątów mają `flags.z` = 0 (`Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift:60-69`).

## Fix design

### Why & what

Środek bańki dociśniętej do ściany siłą F > r_ref/c₀ staje za krawędzią w ε = c₀·F/r_ref, odpychany liniowo przez krawędź, przez którą wszedł; strażnik go nie cofa i nie odrzuca kroku, a nadal łapie przebicie bryły.

- [ ] Wynik solvera na kratce float32 od −3 do +3 ulp wokół każdej krawędzi prostokątnej ściany (cztery ściany, środek dociśnięty z zewnątrz, krawędź wejścia aktywna) nie zapala bitów 2|8 i nie przesuwa środka wzdłuż krawędzi; środek dokładnie na krawędzi bez krawędzi wejścia wychodzi wzdłuż normalnej zewnętrznej, bez odrzucenia · `verify: swift test --filter NativeMetalCenterGuardEdgeTests` — przed poprawką przypadek „dokładnie na krawędzi” daje bity 10 i (360; 500,002), po poprawce zielone
- [ ] Bańka r 24 i r 74 dociśnięta gumką F 2222 (c₀ 0,0108, r_ref 20, ζ_c 5) staje w ε = 1,2 ± 2 %, środkiem za krawędzią, bez `lastAdvanceIssue` i `lastSolverGuardCause` w żadnym kroku · `verify: swift test --filter DeepSqueezeWallTests` — przed poprawką ε ≈ 0,9999
- [ ] Środek dociśnięty za krawędź wejścia, który doszedłby do tylnej krawędzi cienkiej ściany, zostaje po wewnętrznej stronie tylnej krawędzi (tylna − margines), krok przyjęty; środek wchodzący do bryły bez krawędzi wejścia jest dalej cofany/rzutowany jak w 3.0.1 · `verify: swift test --filter DeepSqueezeWallTests`
- [ ] Kryteria 3.0.1 bez regresji: ε 0,648 przy F 1200, szczyt bez przeregulowania, tylna krawędź nie odpycha, skośne wejście nad narożnikiem, rzuty CD-D-17 (P-B-40, P-B-41), przenikanie konturów 0 · `verify: swift test --filter "WallImpactTests|StaticPolygonEdgeTests|NativeMetalSafetyTests|CrowdCompressionTests"` zielone
- [ ] Wydanie 3.0.2 opisane, cały zestaw testów zielony · `verify: swift test` — 0 failures

### How - Program design

**Pamięć krawędzi wejścia (BF-D-1).** `nativeBuildContacts` (`NativeGeometryKernels.metal-source:671`) dostaje poprzedni opublikowany cache kontaktów (`state.contactCache`, liczba rekordów `contactControl.limits.w`; posortowany po kluczu kind/bańka/odcinek). W `nativePolygonEdgeFeature` (`:657-669`) gałąź `previousSide < 0` (środek był już za prostą na początku kroku) zwraca 1, gdy w poprzednim cache jest rekord (kind 1, bańka, ten odcinek) z `response.w` = 1, widziany w poprzednim kroku (`metadata.z`), a rzut środka na prostą leży we wnętrzu odcinka (0 < t < 1, nie za jego końcem — jak w gałęzi `centerSide >= 0`). Wyszukiwanie binarne po pełnym kluczu jak `nativeCacheLowerBound`/`nativeCacheSame` (`NativeXPBDKernels.metal-source:174-185`); źródła shaderów są sklejane w jedną bibliotekę, więc funkcja jest dostępna albo zostaje przeniesiona do `NativeGeometryKernels`. Host: dodać bufor w `dispatchContacts("nativeBuildContacts", …)` (`Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift:675-676`). Cecha 1 daje normalną zewnętrzną i wgniecenie r − dot(center − start, outward) > r — bez zmian w solverze.

**Strażnik (BF-D-2, BF-D-3).** `nativeApplyCenterGuards` (`NativePostSolveKernels.metal-source:275`; host `NativeMetalSolver.swift:761-763`) dostaje bieżący `state.workingCache` (liczba rekordów jak w `nativeInvalidateSafetyCache`, `contacts.counts.z`). W `nativeGuardCenter` (`:189-273`) krawędź statycznego wielokąta e jest „krawędzią wejścia w tym kroku”, gdy `workingCache` ma rekord (kind 1, bańka, e) z `response.w` = 1 i `metadata.z` równym bieżącej klatce. Dla takiej krawędzi i jej właściciela P:

- pierwsza pętla (`:195-210`) nie cofa przejścia e z jej strony zewnętrznej do środka;
- przejście środka z wnętrza P przez inną krawędź P (tył bryły) jest cofane na wewnętrzną stronę tej krawędzi z marginesem (`nativeReturnToOriginalSide` z ich wnętrzem jako stroną startu) — `:62` dziś to pomija, bo start leży we wnętrzu;
- rzut CD-D-17 (`:216-244`) pomija właściciela P, a walidacja `:270` nie odrzuca dla P. Bez krawędzi wejścia zachowanie jak w 3.0.1.

**Odporność rzutu (BF-D-4).** W `:229`: gdy `distance < margin / 2`, kierunek to normalna zewnętrzna krawędzi — `nativeSegmentNormal(edge.current) * edge.region.z` dla krawędzi statycznych (`region.z` = znak strony zewnętrznej, `NativeMetalBufferLayout.swift:63-66`), a dla krawędzi bez `region.z` ten z ±normal, którego kandydat nie leży we wnętrzu właściciela (`nativeInsideOwner`). CCD (`nativeResolveCCD`, `:102-121`) bez zmian.

**Wydanie (BF-D-6).** `CHANGELOG.md` (sekcja 3.0.2 przed 3.0.1), `README.md:5` „Wersja 3.0.2”, `Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift` (asercja i komentarz wersji). Jeśli zmienią się hashe w `Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift` / `AcceptanceRenderEquivalenceTests.swift` (ściany grubości 1), zapisać nowe z `referenceCommit` i komentarzem o przyczynie, jak przy 3.0.1.

### Plan

1. Test jądra strażnika `Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalCenterGuardEdgeTests.swift` (uprzęż jak `ContainmentKernelFixture`): cztery ściany prostokąta, start środka krawędź − 0,002 po stronie zewnętrznej, wynik solvera od −3 do +3 ulp względem prostej, w `workingCache` rekord cechy 1 dla krawędzi wejścia → brak bitów 2|8, środek nieprzesunięty wzdłuż krawędzi i nie cofnięty; dokładnie na krawędzi bez rekordu → środek wzdłuż normalnej zewnętrznej, brak bitów · `verify: swift test --filter NativeMetalCenterGuardEdgeTests` — czerwony przed zmianą (bity 10 / cofnięcie na krawędź − margines)
2. Test API `Tests/BubblePhysicsRuntimeTests/DeepSqueezeWallTests.swift` (scena jak `WallImpactTests`): F 2222 → ε 1,2 ± 2 % dla r 24 i r 74 (r 74 dłuższy przebieg, ok. 30 s symulacji) bez `lastAdvanceIssue`/`lastSolverGuardCause`; cienka ściana i F, przy którym ε sięgnęłoby tyłu ściany → środek po wewnętrznej stronie tylnej krawędzi, bez odrzuceń · `verify: swift test --filter DeepSqueezeWallTests` — czerwony przed zmianą (ε ≈ 0,9999)
3. Pamięć krawędzi wejścia: `NativeGeometryKernels.metal-source` (`nativePolygonEdgeFeature`, `nativeBuildContacts`) i bufor cache w `NativeMetalSolver.swift:675`; potwierdzić warunek wstępny o liczniku klatek (`limits.x`) · `verify: swift test --filter "StaticPolygonEdgeTests|WallImpactTests"` zielone
4. Strażnik: `NativePostSolveKernels.metal-source` (`nativeGuardCenter`, `nativeApplyCenterGuards`) i bufor `workingCache` w `NativeMetalSolver.swift:761` — krawędź wejścia, tył bryły, rzut i walidacja (BF-D-2, BF-D-3) · `verify: swift test --filter "NativeMetalCenterGuardEdgeTests|DeepSqueezeWallTests"` zielone
5. Odporność rzutu CD-D-17 w `:229` (BF-D-4) · `verify: swift test --filter "NativeMetalCenterGuardEdgeTests|NativeMetalSafetyTests"` zielone (z P-B-40, P-B-41, `testInitiallyContainedCenterCanEscapePolygon`)
6. Regresja 3.0.1 i tłoku · `verify: swift test --filter "WallImpactTests|StaticPolygonEdgeTests|NativeMetalSafetyTests|CrowdCompressionTests|SolverGuardCauseTests"` zielone
7. Wydanie 3.0.2: `CHANGELOG.md`, `README.md`, `MigrationGuideTests.swift`, ewentualnie hashe akceptacyjne z uzasadnieniem · `verify: swift test` — 0 failures

### Decisions

| ID | Title | Context | Options | Choice | Rationale | Source | Consequences |
|----|-------|---------|---------|--------|-----------|--------|--------------|
| BF-D-1 | Pamięć krawędzi wejścia | Bez niej kontakt znika w kroku po przekroczeniu prostej i bańka przebija ścianę (weryfikacja hipotezy) | (a) rekord cechy 1 z poprzedniego opublikowanego cache kontaktów; (b) pole w `NativeBubble` z id odcinka wejścia; (c) reguła bezstanowa, np. najbliższa krawędź wielokąta | (a) | Cache ma już klucz (bańka, odcinek) z pełnymi Int64 i `response.w` z cechą; (b) nie ma wolnego pola na Int64 i ściga się przy dwóch krawędziach; (c) to dwustronne krawędzie 2.3.0 (wypychanie tyłem cienkiej ściany), zakazane przez autora | auto (śledztwo: weryfikacja hipotezy, `NativeXPBDKernels.metal-source:174-212`) | `nativeBuildContacts` czyta dodatkowy bufor; utrata rekordu (pojemność, wygaśnięcie, unieważnienie) cofa do naprawy CD-D-17 jak w 3.0.1 |
| BF-D-2 | Strażnik zostawia środek za krawędzią wejścia | Strażnik cofa środek na krawędź − margines i przy trafieniu w krawędź odrzuca krok | (a) strażnik czyta bieżący `workingCache` i dla właściciela z aktywną krawędzią wejścia nie cofa, nie rzutuje, nie odrzuca; (b) wyłączyć cofanie/rzut/walidację dla wszystkich krawędzi statycznych; (c) zostawić cofanie, naprawić tylko numerykę | (a) | (b) przepuszcza wejście bez krawędzi wejścia i przebicie bryły; (c) przeczy decyzji autora (ε > 1 dozwolone) i dalej trzyma ε ≈ 1 | auto (decyzja autora w zgłoszeniu) | `nativeApplyCenterGuards` dostaje bufor; CCD bez zmian, więc szybkie wejście nadal cofa CCD |
| BF-D-3 | Środek dochodzi do tylnej krawędzi | Krawędź wejścia odpycha liniowo bez twardnienia, więc przy dużej sile środek może dojść do tyłu bryły (ściana 48, r 74: ε ≈ 1,65) | (a) cofnąć na wewnętrzną stronę tylnej krawędzi z marginesem, krok przyjęty; (b) odrzucić krok; (c) nic nie robić | (a) | (b) wraca do pętli `stepsRejected`; (c) to przebicie ściany; (a) zachowuje kontrakt strażnika „poprawiaj, odrzucaj dopiero, gdy poprawka zawiedzie” | user | Kontrola przejścia z wnętrza przez inną krawędź właściciela, dziś pomijana w `:62`, działa dla właściciela z krawędzią wejścia |
| BF-D-4 | Kierunek rzutu CD-D-17 przy środku na krawędzi | `(q − p)/d` przy d z szumu zaokrągleń wskazuje wzdłuż krawędzi (próg `FLT_MIN`) | (a) przy d < margines/2 normalna zewnętrzna krawędzi (`region.z`), dla krawędzi bez `region.z` ±normal z kandydatem poza właścicielem; (b) zmienić regułę brzegową `nativeInsideOwner` (punkt na krawędzi = zewnątrz); (c) bez zmian | (a) | (b) zmienia `nativeContainingOwner`, `nativeFreeCenter` i `:62` naraz, szerszy zasięg niż potrzeba; (c) zostawia odrzucenie dla środka na krawędzi bez krawędzi wejścia | auto (wejście autora: „klasyfikacja nie może zależeć od szumu”) | `nativeInsideOwner` bez zmian |
| BF-D-5 | Bez twardnienia sprężyny i bez dwustronnych krawędzi | Alternatywy utrzymujące środek przed krawędzią | (a) sprężyna liniowa, środek za krawędzią dozwolony; (b) twardnienie przy ε → 1; (c) dwustronne krawędzie z 2.3.0 | (a) | Decyzja autora modelu z 2026-11-22 | user | ε = c₀·F/r_ref obowiązuje także dla ε > 1 |
| BF-D-6 | Zakres wydania 3.0.2 | Poprawka zmienia trajektorie przy ścianach | (a) CHANGELOG, README, test wersji, ewentualnie nowe hashe akceptacyjne z uzasadnieniem; (b) dodatkowo zbadać brak powtarzalności bit w bit na GPU | (a) | Brak powtarzalności nie wpływa na tę przyczynę; wejście autora: „do odnotowania, nie do naprawy” | auto (wejście autora) | Powtarzalność GPU zostaje otwarta |

## Implementation deviations

> *Guidance:* Left empty by bugfix; light-implement adds one row per deviation, or "None."

| #   | Task | Type (change/gap) | Description | Date |
| --- | ---- | ----------------- | ----------- | ---- |
| 1   | 4    | change            | Krawędź wejścia w strażniku (BF-D-2) wymaga oprócz rekordu cechy 1 z bieżącej klatki, by bańka była miękka (c > 0), a jej przewidziany środek (`position.xy`) leżał za prostą krawędzi (`nativeEntryEdge`). Zwykły docisk od zewnątrz też daje cechę 1; bez tego warunku P-B-15 (`SolverGuardCauseTests`) przestawał odrzucać krok, a twarde testy narożnika i tłoku w `CrowdCompressionTests` gubiły bańki. Przejście wywołane samymi kontaktami w solverze, przy przewidzianym środku przed prostą, dalej jest cofane jak w 3.0.1. | 2026-11-22 |
| 2   | 3, 4 | gap               | BF-D-3 wymagał także zmiany w kontaktach, nie tylko w strażniku: gdy przewidziany środek minął tylną krawędź, dostawała ona zwykłą cechę 1 i wypychała środek za ścianę. Reguła wyjścia: krawędź, którą środek wychodzi z bryły pamiętającej krawędź wejścia, nie daje kontaktu (`nativePolygonEdgeExit`, `nativeOwnerRemembersEntry`); `nativeBuildContacts` dostaje `state.control` (bufor 6) dla liczby odcinków. | 2026-11-22 |
| 3   | 3, 4 | change            | Pamięć krawędzi wejścia i reguła wyjścia obejmują tylko bańki miękkie (b03d8e5). Bańka twarda ma ε = c·F/r_ref = 0, więc zachowuje się jak w 3.0.1; inaczej twarde bańki przy ścianach grubości 1 zmieniały hashe akceptacyjne. | 2026-11-22 |
| 4   | 3    | change            | `nativeCacheLess`, `nativeCacheLowerBound` i `nativeCacheSame` przeniesione z NativeXPBDKernels do NativeGeometryKernels (plan to dopuszczał), żeby `nativeBuildContacts` mógł z nich korzystać. | 2026-11-22 |
| 5   | 6    | gap               | Dwa istniejące testy regresji sprawdzały dawny niezmiennik „środek nigdy za czołem ściany”, który BF-D-5 znosi. `StaticPolygonEdgeTests.testFastBubbleNeverEndsAStepInsideOrBehindTheWall`: próg z −1e−3 na −r/10 (zmierzone 0,2, ε ≈ 1,02, szybka bańka po CCD). `CrowdCompressionTests`, tłok miękki B = 2,5: zamiast pustego `outsideFrame` limit `deepestCenterBehindFrame` < 0,5·r (zmierzone 0,18·r). Przebiegi twarde zachowują próg 0. **Do potwierdzenia przez autora.** | 2026-11-22 |
| 6   | 2    | change            | Przebieg r 74 trwa 60 s symulacji zamiast 30 s: po 30 s ε = 1,159 jeszcze nie osiadło w ±2 %. | 2026-11-22 |
| 7   | 2    | gap               | Kryterium „wejście bez krawędzi wejścia dalej cofane” sprawdzone na poziomie jądra (`NativeMetalCenterGuardEdgeTests` i P-B-40/41), nie w `DeepSqueezeWallTests`: brak czystego scenariusza API. Przypadek z gry (docisk tłumu w solverze przy przewidzianym środku przed prostą) nie ma testu z asercją ε > 1. Pokrywa go tylko pomiar w teście tłoku. | 2026-11-22 |
| 8   | —    | gap               | Ryzyko szczątkowe, bez zmiany: środek miękkiej bańki, który traci krawędź wejścia we wnętrzu ściany (zsuwa się za koniec krawędzi w obszarze narożnika), wraca do rzutu CD-D-17 jak w 3.0.1 i teoretycznie mógłby wyjść inną krawędzią. Test miękkiego narożnika przechodzi. | 2026-11-22 |
