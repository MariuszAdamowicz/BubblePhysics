# Przewodnik integracji BubblePhysics 4.0

Ten przewodnik pokazuje, jak podłączyć `BubbleWorld` do aplikacji iOS z `MTKView`. Każdy blok kodu jest identyczny z oznaczonym regionem źródeł przykładowej aplikacji w `Examples/BubblePhysicsShowcase/App`, więc kompiluje się razem z nią (`IntegrationGuideTests` pilnuje zgodności). Przykład ma dwie sceny: bańki z teksturami, naklejkami, scalaniem i chwytem palcem (`BubbleScene`) oraz bryły z więzami i platformą kinematyczną (`RigidScene`). Przejście z wersji 1.x opisuje [MIGRATION-v2.md](MIGRATION-v2.md), z wersji 2.x na 3.0 [MIGRATION-v3.md](MIGRATION-v3.md), a z wersji 3.x na 4.0.0 [MIGRATION-v4.md](MIGRATION-v4.md).

Build przykładu bez podpisu:

```bash
xcodebuild -project Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj \
  -scheme BubblePhysicsShowcase -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Na fizycznym iPhonie skopiuj `Signing.local.xcconfig.example` do `Signing.local.xcconfig` (ignorowany przez git) i wpisz własny `DEVELOPMENT_TEAM`.

## Pętla MTKView: fizyka we własnych buforach, render w buforze gry

Fizykę liczy świat we własnych buforach poleceń (para na klatkę: bufor podkroków i bufor końca kroku), a render gry idzie do bufora, który gra podaje w `advance(by:commandBuffer:encodeRender:)`. Po końcu kroku `advance` woła domknięcie `encodeRender`, w którym gra koduje render do swojego bufora; potem zatwierdza ten bufor i czeka na jego ukończenie, bo publikuje stan dopiero po renderze, a błąd renderu jest błędem świata. CPU czeka więc w klatce dwa razy: na bufor końca kroku (odczyt liczby podkroków) i na bufor renderu. Jedno wywołanie wykonuje najwyżej jeden krok. Zaległy czas zostaje w `diagnostics.backlogSeconds`, a gdy czasu nie starcza na krok (ekran 120 Hz przy kroku 1/60), `advance` i tak rysuje opublikowany stan z interpolacją między krokami t−1 i t.

`MTKView` podstawia drawable i deskryptor passu tylko na czas wywołania `draw(in:)`, więc oba pobieramy synchronicznie, a dopiero potem zaczynamy asynchroniczny `advance`. Gdy poprzedni `advance` jeszcze trwa, klatka jest pomijana: pobrany drawable po prostu nie zostaje użyty. `BubbleWorld` i renderer są `@MainActor`.

<!-- guide-region: mtkview-loop -->
```swift
/// Jedna klatka `MTKView`: fizykę liczy świat we własnych buforach, a render idzie do bufora gry. Drawable, deskryptor passu i bufor pobieramy
/// synchronicznie, bo system podstawia je tylko na czas tego wywołania.
func draw(in view: MTKView) {
    // Poprzedni `advance` jeszcze trwa: pobrany drawable po prostu nie zostaje użyty.
    guard !isAdvancing, let scene, let world, let renderer, let queue,
          let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
          let commandBuffer = queue.makeCommandBuffer(),
          view.bounds.width > 0, view.bounds.height > 0,
          let viewport = try? scene.viewport(aspect: Float(view.bounds.width / view.bounds.height))
    else { return }
    lastViewport = viewport
    let now = CACurrentMediaTime()
    let elapsed = now - (lastTimestamp ?? now)
    lastTimestamp = now
    isAdvancing = true
    Task { @MainActor in
        defer { isAdvancing = false }
        if let lastFrame { scene.update(frame: lastFrame, world: world) }
        lastFrame = await advanceAndPresent(world: world, seconds: elapsed, commandBuffer: commandBuffer,
                                            drawable: drawable) {
            try renderer.encode(world: world, viewport: viewport, commandBuffer: commandBuffer,
                                renderPassDescriptor: pass)
        }
    }
}
```

## Prezentacja drawable

Drawable prezentuje się dopiero po `advance` i tylko wtedy, gdy `world.diagnostics.didRenderLastAdvance` jest prawdą. Pauza (ręczna albo w tle), stan „zawiódł” i klatka odrzucona przez błąd gry albo solvera nie zatwierdzają bufora, więc nie ma czego prezentować. Reguła jest ta sama w klatce z krokiem i bez kroku.

Gałąź bez kroku czeka na ukończenie bufora tak samo jak gałąź z krokiem, więc przy 120 Hz CPU i GPU nie pracują równolegle w żadnej klatce; na ekranie 60 Hz nie ma to znaczenia.

<!-- guide-region: present-drawable -->
```swift
/// Drawable prezentujemy tylko wtedy, gdy bufor z renderem został zatwierdzony i ukończony. W pauzie, w stanie
/// „zawiódł” i po odrzuconej klatce `didRenderLastAdvance` jest fałszem, a bufor nie jest zatwierdzany.
private func advanceAndPresent(world: BubbleWorld, seconds: TimeInterval, commandBuffer: MTLCommandBuffer,
                               drawable: CAMetalDrawable, encode: @escaping () throws -> Void) async -> WorldFrame {
    let frame = await world.advance(by: seconds, commandBuffer: commandBuffer, encodeRender: encode)
    if world.diagnostics.didRenderLastAdvance { drawable.present() }
    return frame
}
```

## Cykl życia

Świat sam pauzuje, gdy aplikacja przechodzi w tło (`WorldConfiguration.automaticPause`, domyślnie włączone; na iOS według powiadomień UIKit, własne źródło podaje parametr `lifecycle:` inicjalizatora). W pauzie `advance` zwraca ostatnią klatkę, nie rysuje i nie zatwierdza bufora, a po powrocie pierwszy przyrost czasu jest odrzucany, więc czas spędzony w tle nie jest czasem gry. Pauza ręczna (`pause()` i `resume()`) jest od automatycznej niezależna. Błąd wykonania bufora na GPU albo wartości nieskończone kończą świat stanem „zawiódł” (`diagnostics.failureReason`); dalej prowadzi tylko nowy `BubbleWorld`.

<!-- guide-region: lifecycle -->
```swift
/// Konfiguracja ma `automaticPause` (domyślnie włączone): w tle świat pauzuje sam i po powrocie odrzuca czas
/// spędzony w tle. Pauza ręczna jest od niej niezależna.
private static func makeWorld(for scene: any ShowcaseScene, device: MTLDevice) throws -> BubbleWorld {
    try BubbleWorld(configuration: scene.configuration, device: device)
}

func setPaused(_ paused: Bool) {
    if paused { world?.pause() } else { world?.resume() }
}
```

## Limit kontaktów i determinizm

Solver trzyma na jedną bańkę najwyżej 128 kontaktów w kroku (`diagnostics.contactCandidateOverflow` liczy odrzucone). Poniżej limitu wynik kroku jest zasadniczo deterministyczny na tym samym urządzeniu (zastrzeżenie niżej), a po jego przekroczeniu to, które kontakty zostaną zachowane, zależy od kolejności wątków GPU, więc dwa przebiegi tej samej sceny mogą się różnić. Gra, która widzi niezerowy `contactCandidateOverflow`, jest poza zakresem gwarancji determinizmu.

Zastrzeżenie: także poniżej limitu determinizm nie jest dowiedziony. Test determinizmu sceny z 300 bańkami raz dał różne hashe dwóch przebiegów, a przyczyny nie ustalono (znane ryzyko wydania 2.0.0, odstępstwo nr 130 planu zmiany). Gra, która opiera się na bitowo identycznych przebiegach (powtórki, synchronizacja sieciowa), powinna to sprawdzić na własnej scenie i nie zakładać gwarancji.

## Tłok baniek, sztywność kontaktu i zły punkt

Krok z bańkami w poprawnych punktach nie jest odrzucany z powodu baniek, także w tłoku. Od 4.0.0 bańka nie przechodzi przez ścianę ani przez drugą bańkę dlatego, że kontakt ma granicę na promieniu: siła F = K_c · ε / (1 − ε)² rośnie bez ograniczeń, zanim środek bańki dojdzie do przeszkody (ε to ugięcie podzielone przez promień), a ruch liczy całkowanie siłowe w podkrokach wewnątrz kroku 1/60 s. Nie ma strażnika środka, CCD ani rozsuwania par „bańka w bańce”. Krok odrzuca tylko budżet obrotu bryły dynamicznej (`.rigidRotationBudget`; przyczynę podaje `diagnostics.lastSolverGuardCause`). Naruszenie geometrii kontaktu to błąd silnika, a nie stan sceny: świat kończy się wtedy stanem „zawiódł” z przyczyną `.contactViolation`, a klatka, która potrzebowałaby ponad 1024 podkroków, z przyczyną `.substepLimitExceeded`. Szczegóły (obiekty, krawędź, odległość, człon wzoru na długość podkroku) podaje `diagnostics.failureDetail` typu `WorldFailureDetail`.

- **Brak limitu prędkości baniek.** Materiał `.bubble` nie przyjmuje `maximumLinearSpeed` ani `maximumAngularSpeed` (`valueOutOfRange` z nazwą pola): szybka bańka skraca podkrok, zamiast dostać limit. Limity zostają w materiale `.rigid`. Gwarancję braku przejścia sprawdzono do 3 · 10³ j/s; powyżej koszt rośnie z liczbą podkroków (zob. migracja 4.0.0).
- **Sztywność kontaktu.** `PhysicsMaterial.contactStiffness` (K_c, jednostka siły) mówi, jak twardo bańka stawia opór: dla małych ugięć F ≈ K_c · ε, a przy ε → 1 siła rośnie bez granic. Ta sama siła ugina każdą bańkę o ten sam ułamek promienia, a w parze wgniecenie dzieli się według sztywności obu baniek. Wartość musi być skończona i dodatnia, inaczej `valueOutOfRange("contactStiffness")`. Materiał `.rigid` nie przyjmuje K_c. Nadpisania na pojedynczej bańce ani w wyniku scalenia i podziału nie ma: bańka o innej sztywności ma własny materiał. Strojenie w czasie robi przejście `PhysicsParameter.contactStiffness`.
- **Ugięcie i spoczynek.** Pod stałą siłą F bańka ugina się o ε wynikające z F = K_c · ε / (1 − ε)², bez względu na masę i γ, a w spoczynku stoi. Przykład ustawia K_c = 229, czyli ε ≈ 0,65 przy F ≈ 1 200. Przy lekkim kontakcie bańki są miękkie (ε 0,3 przy F ≈ 140). Kontur bańki w kontakcie to cięciwa o promieniu r · (1 − ε), więc kontury sąsiadów nie przenikają się. Kontur pokazuje tylko bieżące kontakty: kontakt, który zniknął, znika z konturu w tej samej klatce.
- **Kontur tylko rysowany.** Kontur bańki (`debugContourSnapshot()`, rysowanie, `ObjectState.bounds`) jest tylko obrazem: nie wpływa na pozycje, prędkości ani promienie fizyczne, a jego zła wartość nie odrzuca kroku. Promień efektywny nieskończony albo spoza [0, promień docelowy] to promień docelowy, nieskończona albo odwrócona obwiednia to obwiednia koła bańki, a deformacja spoza [0, 1] nie wchodzi do statystyk.
- **Tłumienie.** Kontakt nie ma osobnego tłumika: tłumienie wynika z prawa kontaktu i z oporu ruchu γ (`damping` materiału), który działa w każdym podkroku. Dobierz γ w materiale baniek, żeby uderzenie w ścianę osiadało (γ = 0 daje odbicie bez strat energii).
- **Ściany i krawędzie wielokątów.** Krawędź bryły statycznej odpycha bańkę tylko od zewnątrz, a wypukły wierzchołek raz, więc bańka dociśnięta do ściany ugina się o ε wynikające z siły i K_c niezależnie od grubości ściany i od obiegu wierzchołków, który podała gra. Kontakt powstaje w obszarze wnętrza krawędzi (normalna zewnętrzna) albo wypukłego wierzchołka; tylna krawędź cienkiej ściany nie przepycha bańki. Bańka spotyka się tylko z bryłami statycznymi i kinematycznymi: transakcja, po której świat miałby bańkę i bryłę dynamiczną (`.dynamic`, `.motorDriven`, `.playerDriven`, `.pathDriven`), jest odrzucana z `unsupportedBubbleWithDynamicRigidBody`, a przegub z bańką z `unsupportedJointBody`.
- **Zły punkt.** `add` i `replace` bańki z punktem poza `simulationRegion` (także przy `regionExitPolicy == .wrap`), we wnętrzu bryły sztywnej albo w prawie wspólnym środku z inną bańką odrzucają całą transakcję zdarzeniem `transactionRejected` z `invalidPlacement(ObjectID, PlacementIssue)`. ID wskazuje bańkę z błędnym punktem, a `PlacementIssue` przyczynę; transakcja zostaje poza kolejką, więc gra podaje nowy punkt kolejną transakcją. `mergeBubbles` i `splitBubble` same poprawiają punkt wyniku i odrzucają transakcję dopiero wtedy, gdy nie ma poprawnego kandydata. Od 4.0.0 to samo dotyczy bryły: `add`, `replace` i `replaceRigidBodies`, której wnętrze obejmuje środek bańki, odrzucają transakcję z `invalidPlacement(ObjectID, .insideRigidBody)` i ID bańki.

## Chwyt gumką

Chwyt jest jedynym napędem baniek z palca, a jego narzędziem jest gumka siłowa: `BubbleDrivePolicy(bandStiffness: K, maximumForce: F)`. Polityka należy do bańki (`BubbleDescriptor.drivePolicy`, a dla wyniku scalenia albo części podziału `BubbleResult.drivePolicy`). Bańka z `drivePolicy` równym `nil` (domyślnie) i bryła nie dają się chwycić: `beginPlayerDrive` odrzuca je z `incompatibleObjectKind(id)`, ruch zostaje bez zmian. Chwycona bańka dostaje siłę K · (cel − położenie), obciętą do `maximumForce` z zachowaniem kierunku. Do niej dochodzą siła globalna i pola sił jak przy bańce `.dynamic`. Chwyt nie zmienia promienia ani kształtu bańki: nie ma usztywniania ani narzuconej prędkości.

Polityka chwytu w przykładzie (K = 20, siła obcięta do 600):

<!-- guide-region: grip-policy -->
```swift
/// Gumka chwytu: siła K · naciągnięcie, obcięta do 600. Bańka bez `drivePolicy` nie daje się chwycić.
/// Tłumienie ruchu bańki to `damping` jej materiału (γ), bo gumka nie ma własnego tłumienia: bez γ chwycona bańka
/// krąży wokół palca jak sprężyna bez tłumienia.
private static func gripPolicy() throws -> BubbleDrivePolicy {
    try BubbleDrivePolicy(bandStiffness: 20, maximumForce: 600)
}
```

Jedno tłumienie ruchu: `damping` materiału (γ). Opór γ i gumka liczą się na GPU w każdym podkroku, razem z siłą globalną, polami i motorem (całkowanie leapfrog: pół impulsu, ruch, kontakty, pół impulsu), więc `v ← v · e^(−γ · h) + F / m · h` w podkroku o długości h. Siła działa w całości, także w spoczynku przy ścianie: bańka dociśnięta gumką ugina się o ε wynikające z F i K_c, bez względu na γ i masę. Prędkość narzucona torem (`.pathDriven`, bryła kinematyczna) nie jest tłumiona.

- **Prędkość ustalona.** Bez kontaktów, przy stałym naciągnięciu s i sile poniżej `maximumForce`, bańka ustala się w przybliżeniu na v ≈ K · s / (m · γ). Lżejsza jedzie szybciej w odwrotnej proporcji do masy. Przy γ = 0 nie ma tłumienia, a materiał `.bubble` nie ma limitu prędkości (nie przyjmuje `maximumLinearSpeed`), więc bańka przyspiesza bez ograniczenia, a im jest szybsza, tym więcej podkroków kosztuje klatka. Ustaw γ w materiale, jeśli chcesz prędkość ustaloną. Przykład ustawia γ = 1,5 w materiale baniek; przy γ za małym chwycona bańka krąży wokół palca jak sprężyna, a przy dużym spada wolno pod siłą globalną (prędkość spadania F / (m · γ)).
- **Zakres K.** Gumka jest całkowana w podkrokach, a stabilność wymaga ω_band · dt ≤ 0,25, czyli K_band ≤ m / (16 · dt²). Przy kroku 1/60 to K_band ≤ 225 · m (dla m = 1 około 225). Wstawienie, zamiana, scalenie i podział, które dają bańkę z polityką poza zakresem, odrzucają transakcję z `invalidValue(.valueOutOfRange("drive.bandStiffness"))`, a podział zmniejsza masę, więc może wyjść poza zakres. Rozsądne strojenie to K rzędu 0,4–50 przy naciągnięciu rzędu 100–700 jednostek. Sztywniejsza gumka przy małej masie wymusza więcej podkroków i kosztuje klatkę.
- **Pola.** `bandStiffness` i `maximumForce` rzucają `valueOutOfRange("drive.bandStiffness")` i `("drive.maximumForce")` dla wartości niedodatnich albo nieskończonych. Pola `bandDamping` nie ma. Cel w `beginPlayerDrive` i `updatePlayerDrive` o składowej poza limitem `MotorDrive` jest odrzucany.
- **Puszczenie.** `endPlayerDrive` nie zmienia prędkości: w ramce po puszczeniu bańka ma prędkość z ostatniego kroku napędu i leci dalej, hamowana tylko tłumieniem materiału.
- **Zmiana struktury.** `replace`, scalenie i podział chwyconej bańki kończą chwyt: nie ma `DriveFeedback`, a `updatePlayerDrive` i `endPlayerDrive` dają `driveNotActive` albo `objectNotFound`. Ponowny chwyt wyniku jest możliwy tylko wtedy, gdy wynik ma `drivePolicy`.
- **Ramki.** Siła gumki jest liczona w każdym podkroku z bieżącego położenia bańki, więc nie ma jednego naciągnięcia na krok i prędkości między ramkami nie da się odtworzyć wzorem z ramki. `DriveFeedback.target` i `achievedPoint` ramki N podają cel i położenie bańki na końcu kroku N, czyli naciągnięcie `target − achievedPoint` na końcu tego kroku; siła kroku N + 1 startuje od tego naciągnięcia i zmienia się w podkrokach wraz z ruchem bańki.

### Sztywny materiał i limit podkroków

Podkrok jest tym krótszy, im sztywniejszy kontakt i im szybsze uderzenie, więc cena sztywnego materiału rośnie z K_c. Dla materiałów rzędu K_c ≈ 10⁵ i większych tłum 150 baniek może przekroczyć limit 1024 podkroków w klatce i skończyć świat z `.substepLimitExceeded`. Gra z K_c ≈ 229 jest daleko od tej granicy. Nie dodawaj baniek wewnątrz bryły, nie wciskaj bryły kinematycznej w bańkę przy ścianie (bańki nie da się zgnieść do zera) i sprawdzaj `diagnostics.failureDetail` po stanie „zawiódł”. Opis ograniczeń jest w [MIGRATION-v4.md](MIGRATION-v4.md).

## Rejestracja tekstur, czcionek i naklejek

Tekstury, czcionki i atlasy glifów rejestruje się w `AssetRegistry` świata (`world.assets`) synchronicznie, poza klatką. Rejestr zwraca identyfikatory (`TextureID`, `FontID`, `GlyphAtlasID`), a transakcje i materiały wskazują zasoby tylko przez nie. `register(_: CGImage)` dekoduje obraz raz i przemnaża alfę; gotowa `MTLTexture` musi mieć alfę przemnożoną (formaty `rgba8Unorm` i `bgra8Unorm`). Czcionka dostaje zestaw znaków i raz generuje atlas SDF, a znak spoza zestawu odrzuca transakcję (`characterNotInGlyphSet`).

<!-- guide-region: register-assets -->
```swift
/// Zasoby rejestruje się synchronicznie, poza klatką; transakcje wskazują je przez identyfikatory z rejestru.
func prepare(assets: AssetRegistry) throws -> WorldTransaction {
    let textures = try Self.tints.map { try assets.register(Self.gradient(top: $0.top, bottom: $0.bottom)) }
    let font = try assets.register(font: "Helvetica-Bold", characters: "0123456789")
    self.font = font
    var transaction = WorldTransaction()
        .updatePhysicsMaterial(Self.bubblePhysics, material: try PhysicsMaterial(kind: .bubble, contactStiffness: 229, damping: 1.5))
        .updatePhysicsMaterial(Self.wallPhysics, material: try PhysicsMaterial(kind: .rigid))
        .updateRenderMaterial(Self.wallLook, material: try RenderMaterial(color: RGBA(0.25, 0.27, 0.33, 1)))
    for (index, texture) in textures.enumerated() {
        transaction = transaction.updateRenderMaterial(RenderMaterialID(rawValue: UInt64(index + 1)),
            material: try RenderMaterial(texture: texture, outline: RenderOutline(color: .white, width: 1.5)))
    }
    return try addObjects(to: transaction)
}
```

Naklejka (`Decal`) to tekst z glifów albo fragment tekstury gry. Jest przypięta do bańki lub bryły, a na bańce przycinana do jej konturu.

<!-- guide-region: decal -->
```swift
/// Naklejka tekstowa z liczbą; znaki muszą należeć do zestawu zarejestrowanego z czcionką.
private func decal(for value: Int) throws -> Decal? {
    guard let font else { return nil }
    return try Decal.text(String(value), source: .font(font), color: .white, scale: 1)
}
```

## Zapytania

Zapytania synchroniczne (`objects(at:)`, `objects(in:)`, `objects(inCircle:radius:)`, `raycast(from:to:)`) czytają ostatnio opublikowany stan bez czekania na GPU. Bryły są sprawdzane dokładnie, a bańka jako koło o efektywnym promieniu.

<!-- guide-region: sync-query -->
```swift
/// Zapytania synchroniczne czytają ostatnio opublikowany stan bez czekania na GPU. Bryły są sprawdzane dokładnie.
func touchBegan(at point: WorldPoint, world: BubbleWorld) async {
    guard let id = world.objects(at: point).first(where: { dynamicBodies[$0] != nil }),
          let mass = dynamicBodies[id] else { return }
    world.submit(WorldTransaction().applyImpulse(to: id, impulse: [0, mass * Self.touchImpulse]))
}
```

Dokładny `hitTest` liczy GPU na zdeformowanych konturach i dokładnych kształtach brył, na stanie następnego ukończonego kroku, więc odpowiedź przychodzi po kroku. Hit-test działa na konturach kroku t+1, a obraz leży między t−1 i t, więc może się rozjechać z obrazem o najwyżej dwa kroki, czyli przy szybkim obiekcie o kilka jednostek świata. Punkt ekranu zamienia na punkt świata `Viewport.worldPoint(for:in:)`.

<!-- guide-region: hit-test -->
```swift
/// Dokładny hit-test liczy GPU na konturach następnego kroku, więc odpowiedź przychodzi po kroku. Palec mógł się
/// w tym czasie unieść: wtedy chwyt się nie zaczyna.
func touchBegan(at point: WorldPoint, world: BubbleWorld) async {
    isTouching = true
    guard let id = await world.hitTest(point), isTouching, values[id] != nil else { return }
    grabbed = id
    world.submit(WorldTransaction().beginPlayerDrive(id, target: point))
}
```

## Obsługa zdarzeń

Zdarzenia są opt-in: obiekt zgłasza je tylko wtedy, gdy ma odpowiedni `eventInterest`. Klatka zawiera zdarzenia ze wszystkich kroków ukończonych w wywołaniu `advance`. Brak nowego kroku zwraca tę samą klatkę, więc `stepIndex` chroni przed podwójną obsługą. Gra odpowiada na zdarzenia nowymi transakcjami, a wynik transakcji poznaje po potwierdzeniu (`transactionReceipts`) albo po zdarzeniu `transactionRejected` z tym samym tokenem. Obiekt z `eventInterest: .contact` dostaje też zdarzenia `contactBegan` (para obiektów, punkt, normalna i impuls) oraz `contactEnded` (para obiektów), gdy jego kontakt z innym obiektem się zaczyna i kończy.

<!-- guide-region: merge-events -->
```swift
/// Zdarzenia opt-in (`eventInterest`) przychodzą w klatce świata. Scena zamienia `mergeContact` na transakcję
/// scalenia i śledzi jej los po tokenie: potwierdzenie albo `transactionRejected`.
func update(frame: WorldFrame, world: BubbleWorld) {
    // Brak nowego kroku zwraca tę samą klatkę; `stepIndex` chroni przed podwójną obsługą zdarzeń.
    guard frame.stepIndex != handledStep else { return }
    handledStep = frame.stepIndex
    for receipt in frame.transactionReceipts {
        guard let merge = pendingMerges.removeValue(forKey: receipt.token) else { continue }
        for source in merge.sources { values[source] = nil }
        values[merge.result] = merge.value
    }
    let busy = Set(pendingMerges.values.flatMap(\.sources))
    var claimed = busy
    for event in frame.events {
        switch event {
        case .transactionRejected(let token, _):
            pendingMerges[token] = nil
        case .mergeContact(let first, let second, _):
            guard !claimed.contains(first), !claimed.contains(second),
                  let a = values[first], let b = values[second] else { continue }
            claimed.formUnion([first, second])
            merge(first, second, value: a + b, world: world)
        default:
            break
        }
    }
}

private func merge(_ first: ObjectID, _ second: ObjectID, value: Int, world: BubbleWorld) {
    let id = ObjectID(rawValue: nextID)
    nextID += 1
    let isFinal = value >= Self.maximumValue
    do {
        let result = BubbleResult(
            id: id, physicsMaterialID: Self.bubblePhysics,
            renderMaterialID: RenderMaterialID(rawValue: UInt64(Self.tier(of: value) + 1)),
            mergeGroups: isFinal ? [] : Self.mergeGroup, eventInterest: isFinal ? [] : .mergeContact,
            decal: try decal(for: value), drivePolicy: try Self.gripPolicy())
        let token = world.submit(WorldTransaction().mergeBubbles([first, second], result: result))
        pendingMerges[token] = PendingMerge(sources: [first, second], result: id, value: value)
    } catch {
        print("Showcase: nie udało się zbudować scalenia: \(error)")
    }
}
```

`BubbleResult` ma też `drivePolicy:` i `mass:` na końcu parametrów. `drivePolicy:` (domyślnie `nil`) to polityka chwytu wyniku scalenia albo części podziału, z której korzysta `beginPlayerDrive` na nowej bańce. Wynik bez polityki nie daje się chwycić, więc scena z chwytem podaje ją w każdym wyniku, tak jak w `BubbleDescriptor` (przykład: `BubbleDrivePolicy(bandStiffness: 20, maximumForce: 600)`). `mass:` (domyślnie `nil`, czyli suma mas źródeł) nadpisuje masę wyniku scalenia. Prędkość liniowa i kątowa wyniku zawsze pochodzą z mas źródeł (pęd i moment pędu źródeł podzielone przez ich sumę mas i wynikającą z niej bezwładność), więc nadpisana masa wpływa tylko na dalszą fizykę. W `splitBubble` `mass` różne od `nil` w którejkolwiek części odrzuca transakcję z `invalidStructuralOperation`. Wyniku nie da się nadpisać sztywności kontaktu: bańka z wyniku ma materiał z `physicsMaterialID`, a sztywność jest w nim (sekcja „Tłok baniek, sztywność kontaktu i zły punkt”).

## Formaty passu renderu

Pass gry ma wyłącznie załącznik koloru: renderer bierze format koloru z deskryptora passu (`bgra8Unorm` w przykładzie; potok powstaje dla formatu koloru z deskryptora), a bufor głębi i bufor szablonu nie są potrzebne. Naklejki są przycinane maską w shaderze fragmentu, nie buforem szablonu. Własne rysowanie gry w tym samym passie podpina się przez `RenderHooks` (po tle, po wybranej warstwie, na końcu).

<!-- guide-region: pass-format -->
```swift
/// Pass gry ma tylko kolor: bez bufora głębi i szablonu. Renderer bierze format koloru z deskryptora passu.
static func configure(_ view: MTKView, clearColor: MTLClearColor) {
    view.colorPixelFormat = .bgra8Unorm
    view.depthStencilPixelFormat = .invalid
    view.framebufferOnly = true
    view.clearColor = clearColor
    view.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
}
```
