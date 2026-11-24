# Migracja z BubblePhysics 3.x do 4.0.0

Wersja 4.0.0 zmienia prawo kontaktu baniek i sposób liczenia ruchu. Dokument ma pięć części: tabelę usuniętych symboli z zastępstwami, nowy materiał bańki, opis zmian zachowania prostymi słowami, nowe pola diagnostyki i znane ograniczenia.

## Co się zmienia

W 3.x kontakt był liniową sprężyną bez granicy, a ruch liczył solver pozycyjny XPBD w jednym kroku 1/60 s. Żeby bańka nie przeszła przez ścianę ani przez drugą bańkę, silnik miał kilka łat: wykrywanie przejścia środka (CCD), strażniki z rzutami, krawędź wejścia, rozsuwanie par „bańka w bańce” i odrzucanie kroku.

W 4.0.0 łaty znikają. Kontakt ma granicę na promieniu: siła F = K_c · ε / (1 − ε)² rośnie bez ograniczeń, zanim środek bańki dojdzie do ściany albo do środka drugiej bańki (ε to ugięcie podzielone przez promień). Ruch liczy całkowanie siłowe w podkrokach wewnątrz kroku 1/60 s. Podkrok jest tak krótki, że bańka nie może przeskoczyć przeszkody w jednym podkroku, więc przejście jest wykluczone z konstrukcji, a nie łatane.

## Usunięte i zmienione symbole

Pierwsza komórka to symbol z 3.x, druga to zastępstwo albo powód usunięcia.

| Symbol z 3.x | Zastępstwo w 4.0.0 |
|--------------|--------------------|
| `BubbleContactCompliance` (z polami `base`, `referenceRadius` i wartością `.hard`) | Usunięty. Sztywność kontaktu to `PhysicsMaterial.contactStiffness` (K_c). Przybliżony przelicznik: K_c ≈ r_ref / c₀, bo dawne ugięcie względne ε = c₀ · F / r_ref dla małych ε odpowiada ε ≈ F / K_c. |
| `contactCompliance` (parametr `PhysicsMaterial.init`, pole materiału, pole `BubbleDescriptor` i pole `BubbleResult`) | Usunięte we wszystkich czterech miejscach. Materiał bańki podaje `contactStiffness`. Nadpisanie na pojedynczej bańce albo wyniku scalenia i podziału nie istnieje: dla bańki o innej sztywności zarejestruj osobny materiał. |
| `contactDampingRatio` | Usunięty razem z dashpotem ζ_c. Tłumienie kontaktu wynika z prawa kontaktu i oporu ruchu γ (`damping`), więc dobierz γ w materiale bańki. |
| `deformability` (materiał) | Usunięte. Kształt bańki wynika z ugięcia ε kontaktu, a kontur jest rysowany jako cięciwa r · (1 − ε), więc osobna deformowalność nie jest potrzebna. |
| `PhysicsParameter.deformability` | `PhysicsParameter.contactStiffness`. Przejście `friction` albo `restitution` na materiale `.bubble` jest odrzucane `valueOutOfRange`. |
| `SolverGuardCause.centerCrossing` | Usunięty: strażnika środka nie ma, bo przejście wykluczają podkroki. `SolverGuardCause` ma jeden przypadek, `rigidRotationBudget` (budżet 128 próbek obrotu bryły dynamicznej, bez zmian). |
| `containedBubblePairCount` (`WorldDiagnostics`) | Usunięty razem z rozsuwaniem par „bańka w bańce”: para, w której jedno koło mieści się w drugim, nie powstaje, bo kontakt odpycha przed zrównaniem środków. Naruszenie jest błędem silnika (`worldFailed` z przyczyną `contactViolation`). |
| `NativeMetalConfiguration.solverIterationCount` | Usunięte: nie ma iteracji Jacobiego. Liczbę podkroków wyznacza silnik; przełącznik `substepSplitMultiplier` jest tylko pakietowy, dla testów. |
| `NativeMetalConfiguration.contactCompliance` | Usunięte razem z podatnością XPBD. Sztywność kontaktu jest w materiale (`contactStiffness`). |
| `NativeMetalConfiguration.cacheExpiryFrames` | Usunięte razem z buforem λ i warm startem. |
| `NativeMetalConfiguration.teleportDistanceMultiplier` | Usunięte razem z wykrywaniem teleportu środka i strażnikami. |
| `NativeMetalConfiguration.ccdVelocityMultiplier` | Usunięte razem z CCD. |
| `NativeMetalConfiguration.init(solverIterationCount:cacheExpiryFrames:teleportDistanceMultiplier:ccdVelocityMultiplier:contactCompliance:)` | `NativeMetalConfiguration()`: konfiguracja nie ma pól publicznych. Wywołanie z argumentami przestaje się kompilować. |
| `NativeMetalFrameTelemetry.cacheHitCount` | Usunięte razem z cache'em kontaktów. Zostaje `contactCount`. |
| `NativeMetalFrameTelemetry.cacheResetCount` | Usunięte razem z cache'em kontaktów. |
| `NativeMetalFrameTelemetry.solverIterationCount` | Usunięte razem z iteracjami solvera. Liczbę podkroków podaje `substepCount` (opis niżej). |
| `NativeMetalFrameTelemetry.ccdCandidateCount` | Usunięte razem z CCD. |
| `NativeMetalFrameTelemetry.guardCorrectionCount` | Usunięte razem ze strażnikami środka. |
| `NativeMetalFrameTelemetry.cacheInvalidationCount` | Usunięte razem z cache'em kontaktów. |

## Materiał bańki: K_c i γ

Materiał `.bubble` ma dwa pola fizyczne: `contactStiffness` (K_c, jednostka siły) i `damping` (γ, 1/s). Tarcie, restytucja i limity prędkości należą do materiału `.rigid`.

```swift
// 3.x
let material = try PhysicsMaterial(kind: .bubble, deformability: 0.4, damping: 1.5,
                                   contactCompliance: BubbleContactCompliance(base: 0.0108, referenceRadius: 20))
// 4.0.0
let material = try PhysicsMaterial(kind: .bubble, contactStiffness: 1_850, damping: 1.5)
```

- `contactStiffness` jest wymagane dla `.bubble` i musi być skończone i dodatnie. Nieprawidłowa wartość daje `ModelValidationError.valueOutOfRange("contactStiffness")`.
- `damping` ≥ 0 i skończone, inaczej `valueOutOfRange("damping")`.
- Materiał `.bubble` utworzony z `friction`, `restitution`, `maximumLinearSpeed` albo `maximumAngularSpeed` różnymi od domyślnych jest odrzucany `valueOutOfRange` z nazwą pola.
- Materiał `.rigid` przyjmuje te same pola co w 3.0.2 (tarcie, restytucja, limity prędkości, γ) i nie przyjmuje `contactStiffness`.
- `PhysicsParameter.contactStiffness` zastępuje `.deformability` w przejściach parametru materiału.

Siła potrzebna do ugięcia bańki o ε to F = K_c · ε / (1 − ε)². Dla małych ε to F ≈ K_c · ε, a przy ε → 1 siła rośnie bez granic. Gra nie potrzebuje już walidatora ε < 1 ani granicy ucieczki powiększonej o grubość ściany.

## Co zmienia się w zachowaniu

- **Bańka nie przechodzi przez ścianę ani przez drugą bańkę.** Ściana i druga bańka odpychają coraz mocniej, a podkrok skraca się tak, że w jednym podkroku bańka pokonuje najwyżej jedną czwartą odległości do przeszkody. Nie ma CCD, strażników środka ani rozsuwania par zawartych.
- **Kroki nie są odrzucane z powodu kontaktu.** `WorldRejectionReason.solverGuard` zostaje tylko dla budżetu obrotu bryły dynamicznej (`rigidRotationBudget`).
- **Kontur to cięciwa.** Kontur bańki ugiętej o ε rysuje się z promieniem r · (1 − ε); kontury sąsiadów nie przenikają się.
- **Siły działają w każdym podkroku.** Gumka chwytu, siła globalna, pola i motor wchodzą do całkowania w każdym podkroku, a nie raz na krok. Bańka przy ścianie ugina się więc o ε wynikające z siły i K_c bez względu na masę i γ.
- **Wartość K gumki jest ograniczona.** Gumka w podkrokach wymaga ω_band · dt ≤ 0,25, czyli K ≤ m / (16 · dt²), około 225 · m przy dt = 1/60. Większe K odrzuca transakcja z `valueOutOfRange("drive.bandStiffness")` (po dodaniu, zamianie, scaleniu i podziale bańki).
- **Bańka z bryłą dynamiczną to błąd.** Bańka spotyka się tylko z bryłami statycznymi i kinematycznymi. Transakcja, po której świat zawierałby bańkę i bryłę dynamiczną (`.dynamic`, `.motorDriven`, `.playerDriven` albo `.pathDriven`), jest odrzucana z `TransactionRejectionReason.unsupportedBubbleWithDynamicRigidBody`. Świat z samymi bańkami i świat z samymi bryłami dynamicznymi działają.
- **Bryła nad bańką jest odrzucana.** `add`, `replace` i `replaceRigidBodies` bryły, której wnętrze (z brzegiem) obejmuje środek bańki kolidującej z nią według filtrów, daje `invalidPlacement(id, .insideRigidBody)` z ID bańki.
- **Bryły ruchome zostają poza podkrokami.** Solver brył działa raz na krok, jak w 3.x. Bryła kinematyczna działa na bańki tym samym prawem kontaktu, z pozą interpolowaną w podkroku.

### Dwa nowe stany „zawiódł”

Silnik kończy świat błędem tylko wtedy, gdy sam się pomylił, a nie gdy scena jest trudna. `WorldFailureReason` ma dwie nowe przyczyny (`contactViolation` i `substepLimitExceeded`), a szczegóły są w `WorldDiagnostics.failureDetail` typu `WorldFailureDetail` (obiekty, krawędź, odległość, człon wzoru na h).

| Przyczyna | Kiedy |
|-----------|-------|
| `contactViolation` | Na końcu kroku (po regionie `.wrap`) para kolidująca według filtrów ma d ≤ 0, środek bańki leży w kolidującej bryle albo bańka zmieniła stronę krawędzi jednostronnej. To błąd silnika. Po każdym podkroku silnik sprawdza to tylko z pakietowym przełącznikiem diagnostycznym `assertEverySubstep` (testy). |
| `substepLimitExceeded` | Klatka potrzebowała ponad 1024 podkroków. `failureDetail.objects` wskazuje obiekt, który wyznaczał h, a `limitingTerm` człon (`remainingTime`, `stiffness`, `distance`, `margin`). |

## Nowa diagnostyka

`NativeMetalFrameTelemetry` ma nowe pola:

- `substepCount`: liczba podkroków ostatniej klatki.
- `gridRebuildCount`: liczba przebudów siatki broadphase wymuszonych zapasem obwiedni w ostatniej klatce. Zapas listy kandydatów kurczy się z prędkością, więc szybka bańka wymusza przebudowę w tej samej klatce. Pary buforów, które skończyły się tylko wyczerpaniem podkroków, nie są przebudowami.
- `substepBufferCount`: liczba par buforów podkroków w ostatniej klatce (jedna para to bufor podkroków i bufor końca kroku).
- `executionPath`: ścieżka wykonania kroku, `singleDispatch` albo `multipleDispatches`.
- `singleGroupWidth`: szerokość grupy wątków jądra pętli podkroków; 0 w ścieżce wielu dyspozycji.
- `physicsGPUMilliseconds`: czas GPU fizyki (podkroki).
- `contourGPUMilliseconds`: czas GPU konturu i końca kroku.

## Znane ograniczenia

- **Przegub z bańką jest odrzucany.** `TransactionStager` odrzuca każdy przegub, którego koniec jest bańką, błędem `unsupportedJointBody`. W 3.x stager go przyjmował, a GPU po cichu pomijał, więc przegub nic nie robił. W 4.0.0 przeguby łączą tylko bryły.
- **Sztywny `contactStiffness`.** Dla bardzo sztywnych materiałów (K_c rzędu 10⁵ i więcej) szybkie uderzenie wnosi do całkowania energię: dojazd kandydata bez członu 1/ω w długości podkroku pozwala leapfrogowi oddać więcej energii, niż wziął (odbicie ok. 4× szybsze niż w prawie), a tłum 150 baniek przy B = 2,5 i K_c ≈ 5 · 10⁵ kończy się `substepLimitExceeded`. Zakres gry (K_c ≈ 229) jest daleko od tej granicy; przy twardszych materiałach sprawdź swoją scenę w laboratorium i trzymaj K_c w okolicach setek.
- **Bryła dynamiczna z bańką** nie jest obsługiwana w 4.0.0 (opisane wyżej). Bryły dynamiczne zostają poza podkrokami, więc bańka ich nie czuje.
- **Bryła kinematyczna wciskająca bańkę w ścianę.** Ruch zadany ignoruje siły, a bańki nie da się zgnieść do zera, więc taki stan jest błędem sceny, a nie fizyki. Skutkiem jest `substepLimitExceeded`: podkroki skracają się bez końca i klatka przekracza limit 1024. Nie dodajemy obcinania ruchu bryły.
- **Granica prędkości z rozdzielczości `Float`.** Przy bardzo szybkim uderzeniu minimalna odległość d spada do rzędu ulp współrzędnej (przyjmujemy d_min = 4 ulp). Z bilansu energii d_min ≈ 2 · K_c · r² / (m · v²), więc v_max ≈ √(K_c · r² / (2 · m · ulp)), około 4,6 · 10⁴ j/s przy współrzędnych rzędu 360 dla bańki „2”. Testy sięgają 3 · 10³ j/s. Powyżej granicy możliwe jest `contactViolation`. Współrzędne względne i `Double` na GPU nie wchodzą w 4.0.0.
- **Przepełnienie listy kandydatów.** Para albo krawędź pominięta przez `candidateLimitPerObject` (128 na obiekt) nie ma siły ani warunku d / 4. Sygnałem jest `contactCandidateOverflow` w diagnostyce: traktuj każdą wartość różną od zera jako błąd konfiguracji sceny. Świat nie kończy się z tego powodu.
- **Budżet obrotu bryły** (`SolverGuardCause.rigidRotationBudget`) działa jak w 3.x: bryła dynamiczna obracająca się szybciej niż 128 próbek na krok odrzuca krok.
