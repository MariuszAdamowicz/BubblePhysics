# Plan: BubblePhysics v2.3.0 — gumka siłowa, ρ bez opóźnienia, kontur z bieżących kontaktów, fizyczna dynamika kontaktu

> **For agentic workers:** REQUIRED PHASE COMMAND: Run `/tt-agentic-sdlc:implement` with this file's path to execute this plan. It runs one slice per session, and only a slice with tasks. The program design below is binding: build the call trees as drawn, and turn each behaviour into a failing test before you write the code.

**Date:** 2026-11-19
**Artifact:** plan
**Design:** [change-design.md](change-design.md)
**References:** specyfikacja autora `2KBubbles-iOS/docs/benchmarks/stage-0/v2.3.0-engine-spec.md` (commit 6092ec3 w repo gry); gałąź bazowa PR #6 `feature/crowd-review-followups` ([CD-D-12](change-design.md#cd-d-12))
**Strategy:** slices
**Test command:** `swift build --build-tests && swift test`
**Status:** Approved
**Template version:** default/0.3.3

**Plugin version:** 0.7.10
**Agent Sessions:** claude-code: 226bb044-4b96-41a6-9190-fa96c346d482
**Agent Sessions:** claude-code: 3876e97f-1419-40b6-9aa5-ac4ae637033c
**Agent Sessions:** claude-code: a214cbd1-7fb2-4c88-bdc9-d8f67cfc7c5e

---

## Program design

### R0 — Headline

Gra dostaje chwyt „siłą w stronę palca”: opcjonalna gumka w `BubbleDrivePolicy` daje siłę zamiast narzucać prędkość, więc bańka przy ścianie nie jest miażdżona. Kontakt miękki działa jak sprężyna: ugięcie c · F, bańka w spoczynku stoi, tłumienie wynika ze sprężyny i mas. Sprężyna twardnieje w tym samym kroku, a kontur pokazuje tylko bieżące kontakty.

### R1 — The whole flow

```mermaid
flowchart LR
    subgraph legend["legend"]
      direction LR
      L1["unchanged"]:::same
      L2["added"]:::added
      L3["modified"]:::changed
      L4["removed"]:::removed
      L1 ~~~ L2 ~~~ L3 ~~~ L4
    end

    stage["TransactionStager<br/>walidacja K·dt²/m &lt; 1,<br/>limit celu gumki"]:::changed
    prep["MotionControllers.prepare<br/>.playerDriven: siła gumki → v"]:::changed
    predict["nativePredict"]:::same
    rho["nativeUpdateContactRho<br/>ρ z pozycji przewidzianych"]:::changed
    prev["kontur poprzedniej klatki<br/>+ wygładzanie 0,25"]:::removed
    jacobi["nativeApplyWarmStart + 8 iteracji Jacobiego<br/>zapisują sumę przesunięć do contactCorrection"]:::changed
    guards["CCD, strażniki, finalizacja"]:::same
    vel["nativeUpdateVelocities<br/>bańka miękka: pełna korekta XPBD"]:::changed
    damp["nativeDampContactNormalMotion<br/>czynnik 2·ζ_c·ω na kontakt miękki"]:::changed
    acc["nativeAccumulateContactPressure<br/>wartość = bieżące wgniecenie"]:::changed
    rec["recovered: e^(−12·dt)<br/>deformationRecoveryRate"]:::removed
    mat["PhysicsMaterial.contactDampingRatio<br/>→ NativeBubble.contact.z"]:::added

    stage --> prep --> predict --> rho --> jacobi --> guards --> vel --> damp --> acc
    prev -.-> rho
    rec -.-> acc
    mat --> damp

    classDef same fill:#f6f8fa,stroke:#8c959f,stroke-width:1px,color:#24292f
    classDef added fill:#dafbe1,stroke:#2da44e,stroke-width:3px,color:#24292f
    classDef changed fill:#fff8c5,stroke:#bf8700,stroke-width:3px,color:#24292f
    classDef removed fill:#ffebe9,stroke:#cf222e,stroke-width:2px,stroke-dasharray:4 3,color:#24292f
```

Jedna zmiana po stronie hosta (gumka i jej walidacja) i trzy w kroku natywnym. Kolejność kroku się nie zmienia. Warm start i `nativeSolveJacobi` dopisują tylko swoje przesunięcie do nowego bufora, bo przeguby i bryły działają w tej samej pętli, a pełną korektę w prędkości dostają tylko kontakty XPBD ([CD-D-16](change-design.md#cd-d-16), wiersz odstępstwa niżej).

### R2 — Seams — where the change attaches to existing code

```diff
  Sources/BubblePhysicsPublic/Model/
+   Motion.swift                     # BubbleDrivePolicy: bandStiffness, bandDamping, maximumForce + walidacja w init (slice 3)
+   Resources.swift                  # PhysicsMaterial.contactDampingRatio (domyślnie 1, odrzucany dla .rigid jak contactCompliance) (slice 1)
+   WorldFrame.swift                 # komentarz effectiveRadius: minimum odległości konturu od środka (slice 3)
  Sources/BubblePhysicsRuntime/
+   MotionControllers.swift          # gałąź siłowa .playerDriven; siła globalna i pola jak w .dynamic (slice 3)
+   TransactionStager.swift          # validateBandStability przy add/replace/merge/split; requireDriveMagnitude celu gumki (slice 3)
  Sources/BubblePhysicsNativeMetal/
+   NativePublicWorld.swift          # NativePublicProperties.contact(of:override:radius:dampingRatio:) wpisuje ζ_c do lane .z zawsze (także bańka twarda) (slice 1)
+   NativeSolverInput.swift          # bez deformationRecoveryRate w NativeSolverConfiguration (slice 2)
+   NativeMetalBufferLayout.swift    # komentarze: contact.z = ζ_c, rho.x/y bez wygładzania, shape.y zarezerwowane
+   NativeMetalSolver.swift          # bufor contactCorrection wiązany do warm startu, Jacobiego i velocities (slice 1); nowe wiązania rho, shape.y = 0 (slice 2)
    Shaders/
+     NativePostSolveKernels.metal-source  # nativeUpdateContactRho z geometrii kroku; bez kNativeContactRhoSmoothing, (slice 2)
+                                          #   nativePreviousContourRatio; nativeAccumulateContactPressure bez recovered
+     NativeXPBDKernels.metal-source       # warm start i Jacobi zapisują contactCorrection; nativeUpdateVelocities: korekta XPBD + reszta·s; damping na kontakt;
+                                          #   limit λ pary tylko dla rho.z = 0 w nativePrepareSolverContacts i nativeUpdateContactMultipliers (slice 1)
+     NativeGeometryKernels.metal-source   # komentarz NativeBubble.contact (slice 1), nativeSeedStructuralContours (slice 2)
  Sources/BubblePhysicsNativeMetalDiagnostics/
+   ReferenceSolverInputAdapter.swift      # bez przekazania deformationRecoveryRate (slice 2)
  Tests/BubblePhysicsPublicTests/
+   ModelValidationTests.swift       # walidacja contactDampingRatio (slice 1)
+   MotionCommandTests.swift         # walidacja pól gumki, limit celu w trybie gumki (slice 3)
  Tests/BubblePhysicsRuntimeTests/
+   BandDriveTests.swift             # NEW: G1 przez publiczny świat (prędkość ustalona, masy, ściana, puszczenie, ramki) (slice 3)
+   MotionControllersPrepareTests.swift  # gałąź siłowa: siła globalna i pola, tłumienie gumki (slice 3)
+   TransactionStagerTests.swift     # odrzucenie K·dt²/m ≥ 1 (wstawienie, zamiana, scalenie, podział) (slice 3)
+   ContactVelocityCorrectionProbeTests.swift  # przepisana na ugięcie c·F i v ≈ 0 (slice 1)
+   ContactDynamicsTests.swift       # NEW: oscylator kontaktu (ściana, para), ζ_c = 0 / 0,2 / 1 (slice 1)
+   ContactComplianceTests.swift     # nagłówek bez „Jacobiego”, granica liniowości przeliczona (slice 1)
+   ContactRhoHistoryTests.swift     # NEW: świat A vs świat B (P-B-11) (slice 2)
+   RhoGridReportTests.swift         # NEW: raport siatki c₀ × kc (opt-in, zapis do docs/benchmarks) (slice 3)
+   CrowdCompressionTests.swift      # NEW test: miękka para rozsuwa się z zawierania bez skoku > 0,25·min r (slice 1)
+   PairLambdaCeilingProbeTests.swift  # łańcuch: równowaga przy każdej sile, bez opt-in; pchnięcie wprost bez zmian (slice 1)
    CrowdSceneSupport.swift          # sceny dociśnięcia do ściany (pressedBubble, wallDepth) — reużywane
  Tests/BubblePhysicsNativeMetalTests/
+   NativeMetalShaderABITests.swift  # testHostComputesContactComplianceForBubbleRecord: lane .z = ζ_c także dla bańki twardej (slice 1)
  Tests/BubblePhysicsNativeMetalDiagnosticsTests/
+   NativeMetalXPBDTests.swift       # ρ rekordu: ściana d/r, para z podziałem c, nowy rekord ρ_prev = 1 (slice 2)
+   NativeMetalContourTests.swift    # kontur = bieżące wgniecenie; test relaksacji 30 klatek zastąpiony (slice 2)
+   NativeMetalRestDampingTests.swift # oczekiwania tłumienia przeliczone dla ζ_c (slice 1)
  docs/
+   integration-guide.md             # tryb gumki, ζ_c, zakres K_band, rigidifies: false, migracja z maximumSpeed (slice 3)
+   benchmarks/v2.3.0-rho-grid-<data>.md  # raport siatki (P-B-14) (slice 3)
+ CHANGELOG.md                       # ## 2.3.0 (slice 3)
```

Krok hosta. Gałąź siłowa zastępuje nadpisanie prędkości tylko przy `bandStiffness != nil`:

```diff
 BubbleWorld.advance(by:)                                 # BubbleWorld.swift:245
 └── stepLoop, na krok stały
     ├── TransactionStager.stageBatch → StagingContext.apply
     │   ├── .add / .replace       → validate, validatePlacement, validateWorstAlpha
+    │   │                         → validateBandStability(object)            # K·dt²/m < 1, masa z BubbleDescriptor.mass
     │   ├── .mergeBubbles → merge → validateWorstAlpha(merged)
+    │   │                         → validateBandStability(merged)
     │   ├── .splitBubble  → split → validateWorstAlpha(a), (b)
+    │   │                         → validateBandStability(a), (b)            # podział zmniejsza masę
     │   └── .beginPlayerDrive / .updatePlayerDrive → requireFinite(target)
+    │                             → requireDriveMagnitude(target)           # tylko gdy drivePolicy.bandStiffness != nil
     └── NativeCompleteStepper.completeStep → performStep
         ├── MotionControllers.prepare(&state, duration:)
         │   └── prepare(object, fields:, globalForce:, dt:)
         │       └── case .playerDriven
-        │           └── velocity = velocity(to: target, speed: bubbleDriveSpeed(...))
+        │           ├── bandStiffness == nil → velocity(to:speed:)           # bez zmian, v2.2.0
+        │           └── bandStiffness = K → F = clamp(K·(target − position), maximumForce)
+        │                                    + globalForce + fieldForce(...)
+        │                                v = (v + F/m·dt) · e^(−bandDamping·dt/m)
         ├── native.step(...)                                                # NativeMetalSolver, niżej
         └── MotionControllers.feedback(...)                                 # DriveFeedback.target / achievedPoint
```

Krok natywny (`NativeMetalSolver.swift:605-792`). Przeguby i bryły działają wewnątrz pętli iteracji (`:723-751`), więc migawka pozycji po pętli zawierałaby ich korekty. Dlatego `nativeApplyWarmStart` inicjalizuje `contactCorrection` swoim przesunięciem, a `nativeSolveJacobi` dopisuje do niego swoje `correction` w każdej iteracji, przed przegubami. Nie ma nowego kernela ani dodatkowego dispatchu:

```diff
 nativePredict                                                               # bubbles[].position.xy = przewidziane
 nativeBuildContacts → nativeMatchContactCache → nativeCompactContactCache
-nativeUpdateContactRho(bubbles, cache, control, contactControl, contour, previousBubbles, previousDeformation, previousCounts, structuralHeaders)
+nativeUpdateContactRho(bubbles, segments, cache, control, contactControl)    # ściana: clamp(d/r); para: podział c z ρ rekordu
 nativeEmitAdjacency → nativePrepareSolverContacts                           # rho.z = c_a(ρ_a) + c_b(ρ_b), bez zmian
+    └── ograniczenie warm startu pary: rho.z > 0 → r / (m⁻¹ · stopień) z v2.1.0; rho.z = 0 → nativePairLambdaLimit (CD-D-17)
 nativeApplyWarmStart                                                        # solverPositionsPing = predicted + warm start
+    └── contactCorrection[i] = correction                                   # warm start to też korekta kontaktów XPBD
 for 0..<solverIterationCount {
     nativeUpdateContactMultipliers
+        └── min(next, nativePairLambdaLimit) tylko dla pary z rho.z = 0     # para miękka: bez limitu (CD-D-17)
     nativeSolveJacobi(input → output)
+        └── contactCorrection[i] += correction                              # ta sama wartość, którą kernel już liczy
     swap, przeguby, bryły
 }
 nativeCapturePositions(→ diagnosticPostSolver)                              # diagnostyka, bez zmian
 nativeResolveCCD → nativeApplyCenterGuards → nativeFinalizeSolverContacts
-nativeUpdateVelocities(bubbles, finalPositions, control)
+nativeUpdateVelocities(bubbles, finalPositions, control, contactCorrection) # contact.x > 0: X/dt + (final − pred − X)·s/dt, X = contactCorrection
 nativeDampContactNormalMotion(bubbles, segments, cache, control, contactControl, adjacency, degrees)
+    └── na kontakt: rho.z > 0 → 1 − e^(−2·ζ_c·ω·dt), ω = √((m_a⁻¹ + m_b⁻¹)/rho.z); rho.z = 0 → contactDamping
-nativeAccumulateContactPressure: value = max(deficit, recovered)
+nativeAccumulateContactPressure: value = deficit                            # bańka z publicFlags.x: max(deficit, pressure·softness)
 nativeSeedStructuralContours                                                # bez zmian: pierwsza klatka scalenia/podziału
```

Dane, które trzeba znać: `NativeBubble.contact` (x = c₀(r/r_ref)^s, y = kc, z = ζ_c, w wolne), `NativeContactCache.rho` (x, y = ρ końców, z = suma podatności, 0 = kontakt twardy), `NativeContourControl.shape.y` (zarezerwowane, 0). Rozmiary struktur się nie zmieniają, więc testy ABI zmieniają tylko oczekiwanie lane `.z`. Szew testów jądra: `NativeMetalSolver.cachedContacts` i `executeFrame(input:scenarioStep:)`, jak w `NativeMetalXPBDTests`.

Miejsce do obejrzenia dwa razy: `nativeUpdateVelocities` — bańka twarda zostaje przy `(final − predicted)·s/dt` bit w bit, a dla miękkiej skala s dotyczy wszystkiego poza sumą przesunięć Jacobiego (przeguby, bryły, CCD, strażniki).

### R3 — Behaviour

Gumka (G1). Kryteria bezwzględne ([G1-AC3](change-design.md#g1-ac3)) wymagają dynamiki kontaktu z G4.

| P-B-ID | Situation | Result | Proves |
|---|---|---|---|
| <a id="p-b-1"></a>P-B-1 | Bańka bez kontaktów, γ > 0, stałe naciągnięcie s, D = 0 i D > 0 | prędkość ustalona K·s/(m·γ + D) ±10 %, poniżej `maximumLinearSpeed` | [G1-AC1](change-design.md#g1-ac1) |
| <a id="p-b-2"></a>P-B-2 | Dwie bańki o różnych masach, to samo s, D = 0, osobne światy | stosunek prędkości = odwrotność stosunku mas ±10 % | [G1-AC2](change-design.md#g1-ac2) |
| <a id="p-b-3"></a>P-B-3 | Bańka kc = 0 dociśnięta gumką do ściany, pięć naciągnięć | poniżej limitu ugięcie/c = K·s ±10 %; powyżej limitu ta sama równowaga ±0,5 jedn. | [G1-AC3](change-design.md#g1-ac3) |
| <a id="p-b-4"></a>P-B-4 | `endPlayerDrive` po napędzie gumką | prędkość w ramce po puszczeniu ≈ prędkość przed | [G1-AC4](change-design.md#g1-ac4) |
| <a id="p-b-5"></a>P-B-5 | `BubbleDrivePolicy` z K ≤ 0 / ∞, D < 0 / ∞, maximumForce ≤ 0 / ∞, D ≠ 0 lub maximumForce bez K | `valueOutOfRange` z nazwą pola (`drive.bandStiffness`, `drive.bandDamping`, `drive.maximumForce`) | [G1-AC5](change-design.md#g1-ac5) |
| <a id="p-b-6"></a>P-B-6 | Wstawienie, zamiana, scalenie, podział dają bańkę z K·dt²/m ≥ 1 | transakcja odrzucona `valueOutOfRange("drive.bandStiffness")`, świat bez zmian | [G1-AC5](change-design.md#g1-ac5), [CD-D-9](change-design.md#cd-d-9) |
| <a id="p-b-7"></a>P-B-7 | `beginPlayerDrive` / `updatePlayerDrive` w trybie gumki z celem 1e38 | odrzucone jak siła `MotorDrive`; w trybie prędkościowym bez zmian | [G1-AC5](change-design.md#g1-ac5) |
| <a id="p-b-8"></a>P-B-8 | Gumka, D = 0, γ = 0, cel stały, jeden krok na ramkę | Δv między ramkami = K·(target − achievedPoint)/m·dt z `DriveFeedback` ramki N, ±1 % | [G1-AC6](change-design.md#g1-ac6) |
| <a id="p-b-9"></a>P-B-9 | Gumka z siłą globalną i polem kierunkowym | do siły gumki dodane siła globalna i pola, jak w `.dynamic` | [CD-D-10](change-design.md#cd-d-10) |
| <a id="p-b-10"></a>P-B-10 | Polityka bez `bandStiffness` | testy napędu v2.2.0 przechodzą bez zmian | [G5-AC1](change-design.md#g5-ac1) |

Twardnienie i kontur (G2, G3).

| P-B-ID | Situation | Result | Proves |
|---|---|---|---|
| <a id="p-b-11"></a>P-B-11 | Świat A dociska bańkę do ściany do położenia P; świat B dostaje nową bańkę w P z tą samą prędkością | po jednym kroku to samo położenie i kontur ±1e-3 | [G2-AC1](change-design.md#g2-ac1) |
| <a id="p-b-12"></a>P-B-12 | Kontakt bańki ze ścianą w kroku | ρ rekordu = clamp(d/r, 0, 1) z przewidzianego środka ±1e-4 | [G2-AC2](change-design.md#g2-ac2) |
| <a id="p-b-13"></a>P-B-13 | Para baniek w kontakcie; nowy rekord; wynik scalenia lub podziału | ρ końca = (r − nakładanie·c_self/(c_self + c_other))/r z c z ρ poprzedniego kroku; nowy rekord i wyniki: ρ_prev = 1 | [G2-AC2](change-design.md#g2-ac2) |
| <a id="p-b-14"></a>P-B-14 | Siatka c₀ × kc, bańka m = 1,36 dociągana gumką w nasyceniu | raport `docs/benchmarks/v2.3.0-rho-grid-<data>.md`: maksimum przejściowe, równowaga, wzór, wzór z poprawką F·dt²/(m·r) | [G2-AC3](change-design.md#g2-ac3) |
| <a id="p-b-15"></a>P-B-15 | Kontakt znika | w tej samej ramce wgniecenie w jego kierunku = 0 (kontur kołowy bez innych kontaktów) | [G3-AC1](change-design.md#g3-ac1) |
| <a id="p-b-16"></a>P-B-16 | Pierwsza klatka wyniku scalenia lub podziału | kontur z seeda źródeł jak dotąd; od drugiej klatki tylko z kontaktów | [G3-AC1](change-design.md#g3-ac1), [CD-D-13](change-design.md#cd-d-13) |
| <a id="p-b-17"></a>P-B-17 | Bańka przy ścianie i para w kontakcie | wgniecenie konturu ≥ wgniecenie geometryczne w każdej próbce; po uspokojeniu bez przenikania ±0,5 | [G3-AC2](change-design.md#g3-ac2) |
| <a id="p-b-18"></a>P-B-18 | Kod po zmianie | `deformationRecoveryRate`, `nativePreviousContourRatio`, `kNativeContactRhoSmoothing` nie występują w `Sources/BubblePhysicsNativeMetal*` | [CD-D-8](change-design.md#cd-d-8) |

Dynamika kontaktu miękkiego (G4). Warunki z [G4-AC1](change-design.md#g4-ac1): kc = 0, `damping` = 0, restytucja 0, prędkości poniżej `restSpeed`.

| P-B-ID | Situation | Result | Proves |
|---|---|---|---|
| <a id="p-b-19"></a>P-B-19 | Bańka dociśnięta `MotorDrive` do ściany, m ∈ {1, 4}, dt ∈ {1/60, 1/120}, ζ_c ∈ {0,2, 1} | ugięcie = c·F ±10 %, różnica między ζ_c < 10 %, moduł prędkości < 0,1 | [G4-AC5](change-design.md#g4-ac5), [CD-D-16](change-design.md#cd-d-16) |
| <a id="p-b-20"></a>P-B-20 | Wariant ściany: wychylenie z równowagi | ζ_c = 0,2: dekrement 2π·ζ_c/√(1 − ζ_c²) ±10 %; ζ_c = 1: bez przestrzelenia | [G4-AC1](change-design.md#g4-ac1) |
| <a id="p-b-21"></a>P-B-21 | Wariant pary: dwie masy ściskane polami kierunkowymi z filtrem ID | jak [P-B-20](#p-b-20), ω z masy zredukowanej, ζ_c średnie | [G4-AC1](change-design.md#g4-ac1), [CD-D-6](change-design.md#cd-d-6) |
| <a id="p-b-22"></a>P-B-22 | ζ_c = 0, puszczenie z wychylenia | co najmniej dwa przestrzelenia równowagi | [G4-AC2](change-design.md#g4-ac2) |
| <a id="p-b-23"></a>P-B-23 | Kontakty twarde, bańki twarde | tłumienie `contactDamping` i korekta ·s jak w v2.2.0; testy kontaktów twardych bez zmian | [G4-AC3](change-design.md#g4-ac3), [CD-D-7](change-design.md#cd-d-7) |
| <a id="p-b-29"></a>P-B-29 | Łańcuch: sąsiadka r = 20 przy ścianie, bańka środkowa r = 12, m = 0,36 bez własnej siły, pchacz pchany `MotorDrive` siłą 2 000 / 3 500 / 4 500 / 6 000 | nakładanie pary środkowa–sąsiadka = (c_a + c_b)·F ±10 % przy każdej sile, jak bez `pairCorrectionLimit` (sonda c11034b: dziś przy 4 500 i 6 000 jest 19,0 i 22,0) | [G4-AC6](change-design.md#g4-ac6), [CD-D-17](change-design.md#cd-d-17) |
| <a id="p-b-30"></a>P-B-30 | Bańka r = 12 w całości wewnątrz miękkiej r = 40 w (6, 0), przeszkoda r = 20 w (100, 0), wszystkie c₀ = 1e-3, `damping` = 0, `maximumLinearSpeed` = 600, 300 kroków | żaden krok nie jest odrzucony; prędkość każdej bańki ≤ `maximumLinearSpeed` (tol. wzgl. 1e-3); nakładanie ze ścianą < promień; mała bańka dotyka przeszkody (odległość środków ≤ 32,5), a jej rzut na oś wystrzału nie mija rzutu przeszkody; para przestaje być zawarta i od tego kroku `containedBubblePairCount` = 0; bez progu przesunięcia w kroku; `testHardCrowdBalance1SeparatesAllContainedPairs` bez zmian | [G4-AC7](change-design.md#g4-ac7), [CD-D-17](change-design.md#cd-d-17), [CD-D-18](change-design.md#cd-d-18) |
| <a id="p-b-24"></a>P-B-24 | `PhysicsMaterial` z ζ_c < 0 / ∞; materiał `.rigid` z ζ_c ≠ 1 | `valueOutOfRange`; domyślnie 1 | [G4-AC4](change-design.md#g4-ac4), [CD-D-15](change-design.md#cd-d-15) |

Zgodność (G5).

| P-B-ID | Situation | Result | Proves |
|---|---|---|---|
| <a id="p-b-25"></a>P-B-25 | Nagłówek `ContactComplianceTests` | bez współczynnika 3,85 i „Jacobiego”; granica liniowości F przeliczona dla nowej dynamiki | [G5-AC2](change-design.md#g5-ac2) |
| <a id="p-b-26"></a>P-B-26 | Cały zestaw na końcu zmiany | `swift test` przechodzi; opis PR wymienia każdy test o zmienionych oczekiwaniach z powodem | [G5-AC2](change-design.md#g5-ac2) |
| <a id="p-b-27"></a>P-B-27 | Perf guard | `swift run -c release BubblePhysicsPerfGuard` przechodzi z progami `docs/benchmarks/perf-guard.json` | [G5-AC3](change-design.md#g5-ac3) |
| <a id="p-b-28"></a>P-B-28 | Dokumentacja | komentarz `effectiveRadius` bez „odbudowy”; przewodnik: gumka, ζ_c, zakres K_band, `rigidifies: false`, migracja; CHANGELOG 2.3.0 | [G5-AC4](change-design.md#g5-ac4) |

Niezmiennik zastępowanego kodu: przy `bandStiffness == nil` napęd liczy bit w bit jak w v2.2.0 ([P-B-10](#p-b-10)), a bańka twarda dostaje tę samą korektę prędkości ([P-B-23](#p-b-23)).

### Test strategy

| Level | What it proves | Behaviours |
|---|---|---|
| unit (model, bez GPU) — `BubblePhysicsPublicTests` | walidacja pól polityki i materiału | [P-B-5](#p-b-5), [P-B-24](#p-b-24) |
| unit (runtime) — `MotionControllersPrepareTests`, `TransactionStagerTests`, `MotionCommandTests` | całkowanie siły gumki, sumowanie sił, odrzucenia transakcji i celu | [P-B-6](#p-b-6), [P-B-7](#p-b-7), [P-B-9](#p-b-9) |
| integracja przez publiczny świat (Metal) — `BubblePhysicsRuntimeTests` | dynamika gumki, kontaktu i historii ρ end to end | [P-B-1](#p-b-1)–[P-B-4](#p-b-4), [P-B-8](#p-b-8), [P-B-10](#p-b-10), [P-B-11](#p-b-11), [P-B-19](#p-b-19)–[P-B-22](#p-b-22), [P-B-25](#p-b-25), [P-B-29](#p-b-29), [P-B-30](#p-b-30) |
| jądro natywne — `BubblePhysicsNativeMetalDiagnosticsTests`, `BubblePhysicsNativeMetalTests` | ρ rekordu, kontur, ABI, tłumienie twarde | [P-B-12](#p-b-12), [P-B-13](#p-b-13), [P-B-15](#p-b-15)–[P-B-17](#p-b-17), [P-B-23](#p-b-23) |
| raport (opt-in, zapis pliku) | siatka twardnienia dla autora, bez progu | [P-B-14](#p-b-14) |
| static check (grep, diff dokumentacji) | usunięty kod i dokumentacja | [P-B-18](#p-b-18), [P-B-28](#p-b-28) |
| pełny zestaw + perf guard | brak regresji | [P-B-26](#p-b-26), [P-B-27](#p-b-27) |

**Where:** `Tests/BubblePhysicsPublicTests/`, `Tests/BubblePhysicsRuntimeTests/` (sceny z `CrowdSceneSupport.swift`), `Tests/BubblePhysicsNativeMetalTests/`, `Tests/BubblePhysicsNativeMetalDiagnosticsTests/`. Testy wymagają lokalnego GPU Metal (macOS). Perf guard nie jest częścią `swift test`: `swift run -c release BubblePhysicsPerfGuard` na bezczynnym Macu (M1 Pro, jak baseline). Brak lintera w repozytorium.

**Test command:** `swift build --build-tests && swift test`

## Slice Status

| Slice | Name | Delivers | Seams | Behaviours | Status |
|-------|------|----------|-------|------------|--------|
| 1 | Fizyczna dynamika kontaktu miękkiego | ugięcie kontaktu miękkiego c·F, bańka w spoczynku stoi, tłumienie z `contactDampingRatio` (G4, nagłówek `ContactComplianceTests` z G5-AC2) | `PhysicsMaterial.contactDampingRatio`, `NativePublicProperties.contact`, bufor `contactCorrection` w warm starcie i Jacobim, `nativeUpdateVelocities`, `nativeDampContactNormalMotion`, limit λ pary tylko dla par twardych, sondy, `ContactDynamicsTests`, `CrowdCompressionTests` | [P-B-19](#p-b-19)–[P-B-25](#p-b-25), [P-B-29](#p-b-29), [P-B-30](#p-b-30) | wip |
| 2 | ρ bez opóźnienia i kontur z bieżących kontaktów | sprężyna twardnieje w tym samym kroku, kontur bez pamięci poprzedniej klatki (G2-AC1, G2-AC2, G3) | `nativeUpdateContactRho`, `nativeAccumulateContactPressure`, usunięcie `deformationRecoveryRate`, `ReferenceSolverInputAdapter`, testy ρ i konturu | [P-B-11](#p-b-11)–[P-B-13](#p-b-13), [P-B-15](#p-b-15)–[P-B-18](#p-b-18) | unplanned |
| 3 | Gumka siłowa i wydanie | gra chwyta bańkę siłą; raport siatki, perf guard, przewodnik, CHANGELOG 2.3.0 (G1, G2-AC3, G5-AC1, G5-AC3, G5-AC4, końcowe G5-AC2) | `BubbleDrivePolicy`, `MotionControllers`, `TransactionStager`, `BandDriveTests`, `RhoGridReportTests`, dokumentacja | [P-B-1](#p-b-1)–[P-B-10](#p-b-10), [P-B-14](#p-b-14), [P-B-26](#p-b-26)–[P-B-28](#p-b-28) | unplanned |

Wycinek 1 sam naprawia model kontaktu miękkiego (ugięcie c·F zamiast 3,85·c·F, zero prędkości w spoczynku), ale ρ dalej twardnieje z opóźnieniem, a kontur pamięta poprzednią klatkę. Wycinek 2 usuwa obie historie, lecz gra nie ma jeszcze chwytu siłą. Wycinek 3 dodaje gumkę, której kryteria bezwzględne i raport siatki wymagają obu poprzednich, oraz zamyka wydanie.

## Slice 1: Fizyczna dynamika kontaktu miękkiego

**Delivers:** kontakt miękki działa jak sprężyna o podatności c z tłumieniem ζ_c, kontakty twarde bez zmian.

1. Dodać `PhysicsMaterial.contactDampingRatio` (domyślnie 1, bez walidacji) i napisać w `ModelValidationTests` testy `testContactDampingRatio…` dla [P-B-24](#p-b-24) · verify: `swift build --build-tests && ! swift test --filter ModelValidationTests`
    ```text
    # faza czerwona minęła w 762d484; stan zielony @85188bc:
    $ swift test --skip-build --filter ModelValidationTests
    Executed 24 tests, with 0 failures (0 unexpected)
    ```
2. Walidować `contactDampingRatio` w `PhysicsMaterial.init` według wzorca `BubbleContactCompliance.validate(for:)`, pokrywając [P-B-24](#p-b-24) · verify: `swift test --filter ModelValidationTests`
    ```text
    $ swift test --filter ModelValidationTests
    Executed 24 tests, with 0 failures (0 unexpected)
    ```
3. Przepisać `ContactVelocityCorrectionProbeTests` na oczekiwania [P-B-19](#p-b-19) i napisać `ContactDynamicsTests` (ściana; para z dwoma polami `.directional` filtrowanymi na ID; ζ_c = 0, 0,2 i 1) dla [P-B-20](#p-b-20)–[P-B-22](#p-b-22) · verify: `swift build --build-tests && ! swift test --filter "ContactVelocityCorrectionProbeTests|ContactDynamicsTests"`
    ```text
    # faza czerwona minęła w df6e004; stan zielony @85188bc:
    $ swift test --skip-build --filter "ContactVelocityCorrectionProbeTests|ContactDynamicsTests"
    Executed 6 tests, with 0 failures (0 unexpected) in 9.688 (9.689) seconds
    ```
4. Dodać parametr `dampingRatio` do `NativePublicProperties.contact(of:override:radius:)` i wpisywać ζ_c każdej bańki do lane `.z`, także twardej; poprawić komentarze `contact` w `NativeMetalBufferLayout.swift` i `NativeGeometryKernels.metal-source` oraz oczekiwanie `testHostComputesContactComplianceForBubbleRecord` · verify: `grep -q "contactDampingRatio" Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift && swift test --filter NativeMetalShaderABITests`
    ```text
    $ grep -c "contactDampingRatio" Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift
    1
    $ swift test --filter NativeMetalShaderABITests
    Executed 9 tests, with 0 failures (0 unexpected)
    ```
5. Dodać bufor `contactCorrection` (`SIMD2<Float>`), który `nativeApplyWarmStart` inicjalizuje swoim `correction`, a `nativeSolveJacobi` powiększa o swoje `correction`, oraz rozdział korekt w `nativeUpdateVelocities` dla `contact.x > 0`, z bańką twardą bez zmian, pokrywając [P-B-19](#p-b-19) i [P-B-23](#p-b-23) · verify: `swift test --filter "ContactVelocityCorrectionProbeTests|CrowdCompressionTests.testHard"`
    ```text
    $ swift test --filter "ContactVelocityCorrectionProbeTests|CrowdCompressionTests.testHard"
    Executed 4 tests, with 0 failures (0 unexpected) in 20.184 (20.185) seconds
    ```
6. Przenieść czynnik tłumienia `nativeDampContactNormalMotion` do pętli po kontaktach (miękki: 2·ζ_c·ω ze średnią ζ_c pary; twardy: `contactDamping`), pokrywając [P-B-20](#p-b-20)–[P-B-23](#p-b-23) · verify: `swift test --filter "ContactDynamicsTests|ContactVelocityCorrectionProbeTests|CrowdCompressionTests.testHard"`
    ```text
    $ swift test --filter "ContactDynamicsTests|ContactVelocityCorrectionProbeTests|CrowdCompressionTests.testHard"
    Executed 9 tests, with 0 failures (0 unexpected) in 37.581 (37.585) seconds
    ```
7. Przepisać `PairLambdaCeilingProbeTests.testChain…` na [P-B-29](#p-b-29) (równowaga przy każdej sile, bez bramki `BUBBLE_PHYSICS_PAIR_CEILING_PROBE`; pchnięcie wprost zostaje jako test bez bramki) i napisać w `CrowdCompressionTests` test `testSoftContainedPairSeparatesWithoutAJump` (po CD-D-18 przepisany na scenę z przeszkodą i przemianowany na `testSoftContainedPairReleasesWithoutBreakingTheWorld`) dla [P-B-30](#p-b-30) · verify: `swift build --build-tests && ! swift test --filter PairLambdaCeilingProbeTests.testChain`
    ```text
    # faza czerwona minęła w e3675c6; filtr `Klasa.test` nie dopasowuje żadnego testu w swiftpm (0 tests), więc całą klasą @85188bc:
    $ swift test --skip-build --filter PairLambdaCeilingProbeTests
    Test Case '-[...PairLambdaCeilingProbeTests testChainThroughAMiddleBubbleKeepsEquilibriumAtEveryForce]' passed (3.330 seconds).
    Executed 2 tests, with 0 failures (0 unexpected) in 6.409 (6.410) seconds
    ```
8. Ograniczyć `nativePairLambdaLimit` do par z `rho.z == 0` w `nativePrepareSolverContacts` (para miękka: ograniczenie warm startu r / (m⁻¹ · stopień) z v2.1.0) i w `nativeUpdateContactMultipliers` (para miękka bez limitu), pokrywając [P-B-29](#p-b-29) i [P-B-30](#p-b-30). Kryterium [P-B-30](#p-b-30) jest to z [CD-D-18](change-design.md#cd-d-18): bez progu przesunięcia w kroku i bez ograniczania przyrostu prędkości od kontaktu (kierunki (a) i (b) odrzucone) · verify: `swift test --filter "PairLambdaCeilingProbeTests|CrowdCompressionTests.testSoftContainedPair|CrowdCompressionTests.testHard|NativeMetalXPBDTests"`
    ```text
    $ swift test --filter "PairLambdaCeilingProbeTests|CrowdCompressionTests.testSoftContainedPair|CrowdCompressionTests.testHard|NativeMetalXPBDTests"   # @85188bc
    Executed 18 tests, with 0 failures (0 unexpected) in 1.547 (1.549) seconds   # NativeMetalXPBDTests
    Executed 2 tests, with 0 failures (0 unexpected) in 4.656 (4.657) seconds    # PairLambdaCeilingProbeTests
    Executed 24 tests, with 0 failures (0 unexpected) in 22.040 (22.043) seconds
    # P-B-30 według CD-D-18: testSoftContainedPairReleasesWithoutBreakingTheWorld (007fb17) przechodzi
    ```
9. Przepisać nagłówek `ContactComplianceTests` bez współczynnika 3,85 i „Jacobiego”, przeliczyć granicę liniowości F ([P-B-25](#p-b-25)) i zmienić oczekiwania testów miękkich zmienionych przez G4 (np. `NativeMetalRestDampingTests`, `CrowdCompressionTests`, oraz trzy testy par twarda–miękka `ContactComplianceTests.testHard*`, w których ugina się miękka bańka: przy c₀ = 1e-3 i F = 300 δ spada z ok. 1,16 do 0,3, więc progi `wallDepth > 0.5` i `softRadius < 19.7` trzeba przeliczyć albo zwiększyć c₀ ok. 3,85×), każdy z powodem w commicie i we wpisie `Testy o zmienionych oczekiwaniach (slice 1):` w tym pliku, bez zmian w testach kontaktów twardych · verify: `! grep -q "Jacobiego" Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift && grep -q "^Testy o zmienionych oczekiwaniach (slice 1):" docs/sdlc/changes/2026-11-19-engine-v2-3-0/plan.md && swift build --build-tests && swift test`
    ```text
    $ ! grep -q "Jacobiego" Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift   # Jacobiego absent
    $ grep -c "^Testy o zmienionych oczekiwaniach (slice 1):" docs/sdlc/changes/2026-11-19-engine-v2-3-0/plan.md
    1
    $ swift build --build-tests && swift test   # @85188bc
    Executed 1426 tests, with 1 test skipped and 0 failures (0 unexpected) in 567.956 (568.107) seconds
    ```

Testy o zmienionych oczekiwaniach (slice 1):
- `ContactComplianceTests` (5 testów: `testCompressionExponentMakesDoubledForceDentLessThanTwice`, `testOverrideOfBaseComplianceInDescriptorBendsOnlyThatBubble`, `testOverrideOfBaseComplianceInMergeResultBendsOnlyThatResult`, `testOverrideOfBaseComplianceInSplitPartsBendsOnlyThatPart`, `testRadiusLawWithExponent0DentsTheSmallerBubbleMoreInRelativeTerms`): kontakt miękki ugina się o pełne c · F zamiast 3,85 · c · F (CD-D-16), więc ich c₀ = 1e-3 dawało δ = 0,3 zamiast 1,16 i progi nie przechodziły. Wspólne `base` przeliczone na 3,85e-3 (δ = 1,155 jak dawniej). Pary B1 i CD-D-12 mają osobne `pairBase` = 4e-3 jak w v2.2.0. Nagłówek bez współczynnika 3,85 i „Jacobiego”; granica liniowości zmierzona sondą: δ / (c · F) = 1,000 do F = 2 500 (dawna F ≈ 600 wynikała z prędkości spoczynkowej wyłączającej tłumik, której już nie ma).
- `CrowdCompressionTests.testSoftCrowdBalance2_5KeepsStepsAcceptedAndOverlapsMoreThanHard` przemianowany na `testSoftCrowdBalance2_5KeepsStepsAcceptedAndCompressesContoursUnlikeHard` (2 asercje zastąpione): dawny rozkład nakładania wynikał z częściowej korekty prędkości i limitu λ pary; sprężynowy kontakt w gęstym tłoku daje 670 par wobec 729 i maksimum 93,3 wobec 81,2 (c₀ = 3,85e-3). Dowodem działania materiału jest kontur: średni promień efektywny / docelowy < twardy − 0,1 (probe 0,16 wobec 1,00). `CrowdScene.softCrowdPhysics` ma c₀ = 3,85e-3.
- `NativeMetalRestDampingTests` i `ContactComplianceTests.testHard*` przeszły bez zmian oczekiwań (pełny zestaw @007fb17 nie wykazał ich w porażkach); `testHard*` używają wspólnego `base` = 3,85e-3 przy niezmienionych progach.

## Deviations from Design

| ID | Type | Status | Design updated? | Note |
|----|------|--------|-----------------|------|
| [CD-D-16](change-design.md#cd-d-16) | change | approved | yes, Architecture §4a i CD-D-16 edited 2026-11-19 | Projekt każe przechwycić pozycje `nativeCapturePositions` „po iteracjach Jacobiego, przed przegubami, bryłami”, ale przeguby i bryły działają w tej samej pętli (`NativeMetalSolver.swift:723-751`), więc takiej chwili nie ma. Plan sumuje przesunięcie warm startu i samego Jacobiego w każdej iteracji w buforze `contactCorrection`, zapisywanym przez `nativeApplyWarmStart` i `nativeSolveJacobi` (bez nowego kernela i dispatchu), i liczy X/dt + (final − predicted − X)·s/dt. To ten sam wzór co w projekcie przy solved = predicted + X, z korektami przegubów i brył ze skalą s, jak chciał projekt. |
| [G2-AC3](change-design.md#g2-ac3) | change | approved | yes, G2-AC3 i Components edited 2026-11-19 | Raport siatki powstaje w teście opt-in `RhoGridReportTests` w `BubblePhysicsRuntimeTests` przez publiczny świat, a nie jako scenariusz w `BubblePhysicsNativeMetalDiagnostics`: ten moduł nie zależy od runtime, w którym działa gumka (`Package.swift:49`), a żaden kod w repo nie zapisuje dziś raportów do `docs/benchmarks/`. |
| [CD-D-17](change-design.md#cd-d-17) | change | approved | yes, G4-AC6, G4-AC7, Architecture §4c, Components, CD-D-17 i Key facts edited 2026-11-19 | Przegląd planu przewidział sufit siły pary po CD-D-16, a sonda `PairLambdaCeilingProbeTests` (c11034b) potwierdziła go tylko dla siły przenoszonej przez bańkę środkową: ok. 3 888 dla r = 12, m = 0,36. Pierwotny test P-B-29 pchał małą bańkę wprost i by tego nie wykrył; teraz to łańcuch. Autor wybrał (a): limit λ pary tylko dla par twardych, z bramką P-B-30 dla miękkiego zawierania. |

## Replan log

| Slice | Assumed | Found | Plan change | Date |
|-------|---------|-------|-------------|------|
|       |         |       |             |      |

## Implementation deviations

| # | Slice | Task | Type (change/gap) | Description | Status | Date |
|---|-------|------|-------------------|-------------|--------|------|
| 1 | 1 | 5 | change | Bufor z planu `contactCorrection` po stronie hosta nazywa się `NativeMetalPersistentState.bubbleContactCorrection` (`SIMD2<Float>` na bańkę; w shaderach parametr `contactCorrection`: buffer(7) w `nativeApplyWarmStart`, buffer(10) w `nativeSolveJacobi`, buffer(3) w `nativeUpdateVelocities`), żeby nie kolidował z istniejącym buforem kontaktów `contactCorrections`. | approved | 2026-11-19 |
| 2 | 1 | 3 | change | `CrowdScene.softBubblePhysics` w `Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift` dostał parametr `dampingRatio` (domyślnie 1); R2 wymienia ten plik tylko jako reużywany. | approved | 2026-11-19 |
| 3 | 1 | 3 | change | Testy oscylatora `ContactDynamicsTests` używają c₀ = 0,174, F = 0,6, dt = 1/120 (ω·dt ≈ 0,02), a nie scen z c₀ = 1e-3: przy sztywnym kontakcie test mierzyłby tłumienie numeryczne kroku, nie ζ_c. Zmierzony dekrement 1,358 (ściana) i 1,332 (para) wobec 1,283, czyli +6 % i +4 %. | approved | 2026-11-19 |
| 4 | 1 | 3 | gap | `ForceFieldDescriptor`, którego okrąg wychodzi poza obszar symulacji, sprawia, że cała transakcja znika bez potwierdzenia i bez `lastRejectionReason`. Test pary używa promienia pola 100. Błąd istniejący wcześniej, poza celem tej zmiany. | approved | 2026-11-19 |
| 5 | 1 | 7 | change | Test łańcucha `PairLambdaCeilingProbeTests` zachowuje świat kontrolny bez limitu (`pairCorrectionLimit: false`) obok świata z limitem, żeby sprawdzać samą scenę; pchnięcie wprost działa bez bramki środowiskowej, jak w planie. | approved | 2026-11-19 |
| 6 | 1 | 8 | gap | Bramka P-B-30 (G4-AC7) nie przechodzi: maks. przesunięcie środka małej bańki w kroku 15,3 przy progu 3 (12,0 przed zmianą limitu λ, 3,30 w v2.2.0 @312ef58). Sonda: brak limitu λ dla pary miękkiej daje korektę 10,3 w pierwszym kroku przy nakładaniu 46, a pełna korekta w prędkości (CD-D-16) rozpędza bańkę do `maximumLinearSpeed`. Cofnięcie samego podziału korekty nie pomaga (10,3) i psuje G4-AC5; ograniczenie przyrostu prędkości od kontaktu do 0,25·min r pary przechodzi na styk (2,988), bez zachowania pędu pary. Test zacommitowany jako czerwony (e3675c6); zadanie 9 nie zaczęte. Zgodnie z zadaniem 8 decyzja wraca do change-design. Autor wybrał 2026-11-19 kierunek (c): przepisać G4-AC7 na rozsuwanie bez odrzuconego kroku, bez przenikania przez ściany i inne bańki, z prędkością nie większą niż `maximumLinearSpeed`; wystrzał z głębokiego zawierania jest pożądany (zachowanie jak najbardziej poprawne fizycznie). Rozwiązane: G4-AC7 przepisane w [CD-D-18](change-design.md#cd-d-18), change-design zatwierdzony @079cba4; P-B-30 i zadania 7–8 zaktualizowane. | approved | 2026-11-19 |
| 7 | 1 | 9 | change | `CrowdCompressionTests.testSoftCrowdBalance2_5KeepsStepsAcceptedAndOverlapsMoreThanHard` przemianowany na `testSoftCrowdBalance2_5KeepsStepsAcceptedAndCompressesContoursUnlikeHard`, a jego dwie asercje rozkładu nakładania zastąpione asercją konturu (średni promień efektywny / docelowy wyraźnie poniżej twardego; próg zaostrzony po przeglądzie końcowym). Plan mówił tylko o zmianie oczekiwań; przy kontakcie sprężynowym miękki tłok nakłada się mniej par niż twardy (670 wobec 729), więc dawna asercja „więcej nakładania niż twardy” nie opisuje już materiału. | pending | 2026-11-19 |
| 8 | 1 | 9 | change | Zamiast przeliczać progi testów miękkich podniesiono c₀ ok. 3,85× (opcja dopuszczona w zadaniu 9): wspólne `base` w `ContactComplianceTests` = 3,85e-3 (dotyczy też czterech `testHard*` przy niezmienionych progach), nowa stała `pairBase` = 4e-3 dla par B1 i CD-D-12 (wartość z v2.2.0), oraz `CrowdScene.softCrowdPhysics` w `CrowdSceneSupport.swift` z c₀ = 3,85e-3, co zmienia materiał wszystkich testów tłoku miękkiego. Wiersz 2 opisywał tylko parametr `dampingRatio` w tym pliku. | pending | 2026-11-19 |
| 9 | 1 | 9 | gap | R2 oznacza `Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalRestDampingTests.swift` jako zmieniany w wycinku 1 (oczekiwania tłumienia dla ζ_c), ale plik został bez zmian: jego sceny mają kontakty twarde, więc tłumienie `contactDamping` działa jak w v2.2.0 i testy przechodzą. | pending | 2026-11-19 |
| 10 | 1 | przegląd | change | Poprawka z przeglądu końcowego w pliku spoza R2: `Sources/BubblePhysicsRuntime/MotionControllers.swift` — przejście parametru materiału (`ParameterTransition` na `.physicsMaterial`) przebudowywało `PhysicsMaterial` bez `contactDampingRatio` (ζ_c wracało do 1) i bez `contactCompliance` (materiał miękki stawał się twardy; błąd sprzed wycinka). Teraz przekazuje oba pola; test regresji dodany (85188bc). | pending | 2026-11-19 |
| 11 | 1 | 7 | gap | Polecenie sprawdzające zadania 7 `swift test --filter PairLambdaCeilingProbeTests.testChain` nie dopasowuje w swiftpm żadnego testu (0 tests), więc jego wersja z `!` nic nie mierzy. Dowód zebrany filtrem całej klasy; działa forma `PairLambdaCeilingProbeTests/testChain`. Wskazówka dla planu kolejnych wycinków: filtry pojedynczych testów pisać z `/`. | pending | 2026-11-19 |
