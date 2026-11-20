# Przewodnik integracji BubblePhysics 2.0

Ten przewodnik pokazuje, jak podłączyć `BubbleWorld` do aplikacji iOS z `MTKView`. Każdy blok kodu jest identyczny z oznaczonym regionem źródeł przykładowej aplikacji w `Examples/BubblePhysicsShowcase/App`, więc kompiluje się razem z nią (`IntegrationGuideTests` pilnuje zgodności). Przykład ma dwie sceny: bańki z teksturami, naklejkami, scalaniem i chwytem palcem (`BubbleScene`) oraz bryły z więzami i platformą kinematyczną (`RigidScene`). Przejście z wersji 1.x opisuje [MIGRATION-v2.md](MIGRATION-v2.md).

Build przykładu bez podpisu:

```bash
xcodebuild -project Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj \
  -scheme BubblePhysicsShowcase -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Na fizycznym iPhonie skopiuj `Signing.local.xcconfig.example` do `Signing.local.xcconfig` (ignorowany przez git) i wpisz własny `DEVELOPMENT_TEAM`.

## Pętla MTKView z jednym buforem poleceń

Fizyka i render idą w jednym buforze poleceń na klatkę: `advance(by:commandBuffer:encodeRender:)` koduje krok solvera, potem woła domknięcie `encodeRender`, w którym gra koduje render do tego samego bufora, zatwierdza bufor i czeka na jego ukończenie. Jedno wywołanie wykonuje najwyżej jeden krok. Zaległy czas zostaje w `diagnostics.backlogSeconds`, a gdy czasu nie starcza na krok (ekran 120 Hz przy kroku 1/60), `advance` i tak rysuje opublikowany stan z interpolacją między krokami t−1 i t.

`MTKView` podstawia drawable i deskryptor passu tylko na czas wywołania `draw(in:)`, więc oba pobieramy synchronicznie, a dopiero potem zaczynamy asynchroniczny `advance`. Gdy poprzedni `advance` jeszcze trwa, klatka jest pomijana: pobrany drawable po prostu nie zostaje użyty. `BubbleWorld` i renderer są `@MainActor`.

<!-- guide-region: mtkview-loop -->
```swift
/// Jedna klatka `MTKView`: jeden bufor poleceń na fizykę i render. Drawable, deskryptor passu i bufor pobieramy
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

## Tłok baniek, podatność kontaktu i zły punkt

Od 2.2.0 krok z bańkami w poprawnych punktach nie jest odrzucany z powodu baniek, także w tłoku. Sprawdzono to przy ustawionym `maximumLinearSpeed` równym 600 (zob. punkt o limicie prędkości niżej). Strażnik odrzuca krok tylko wtedy, gdy środek bańki przeszedł przez ścianę albo bryłę (`.centerCrossing`), albo bryła obraca się szybciej, niż pozwala budżet próbek obrotu (`.rigidRotationBudget`); przyczynę podaje `diagnostics.lastSolverGuardCause`. Bańka w bańce, czyli para, w której mniejsza leży cała w większej, nie odrzuca kroku, a ich liczbę po ostatnim kroku podaje `diagnostics.containedBubblePairCount`.

- **Limit prędkości w tłoku.** Ustaw `maximumLinearSpeed` w `PhysicsMaterial` baniek, które mogą trafić w tłok albo jadą pod napędem. Domyślnie limitu nie ma (`nil`). Gwarancje bez odrzuceń sprawdzono przy 600 jednostkach na sekundę, czyli 10 jednostkach na krok przy 60 krokach na sekundę, a bez limitu duży skok z prędkości obsługuje tylko rzut środka na przekroczoną krawędź. Limit nie jest wymogiem, bo zmiana nie zmienia wartości domyślnej.
- **Podatność kontaktu.** `PhysicsMaterial.contactCompliance` (`BubbleContactCompliance`) mówi, jak bardzo bańka ugina się pod naciskiem. Domyślne `.hard` daje kontakt twardy jak w 2.1.0. Wartość dodatnia `base` daje kontakt miękki: kontakt miękki pozwala kołom głębiej na siebie nachodzić, a kontur bańki zgniata się w miejscu nakładania w proporcji podatności obu baniek. Podatność bańki to c = `base` · r / `referenceRadius`, gdzie r to jej bieżący promień fizyczny. Jedną bańkę zmienia nadpisanie `contactCompliance` w `BubbleDescriptor`; wynik scalenia i części podziału nadpisuje `BubbleResult.contactCompliance`. Materiał `.rigid` nie przyjmuje podatności dodatniej. Podatność, która przepełnia `Float` w kroku, odrzuca transakcję z `invalidValue(.valueOutOfRange("contactCompliance"))`.
- **Ugięcie i spoczynek.** Kontakt miękki działa jak sprężyna o podatności c: pod stałą siłą F bańka ugina się o c · F (liniowo do F rzędu 2 500 przy c₀ = 3,85e-3 i r = r_ref), a w spoczynku stoi, czyli nie raportuje prędkości w stronę kontaktu. Od 2.3.0 kontakt ugina się o pełne c · F, a nie o około 3,85 · c · F jak w 2.2.0 (przy kroku 1/60; przy 1/120 około 7,6 ·), więc żeby zachować dotychczasowy wygląd, przestrój `base` mniej więcej 3,85 razy w górę (z 1e-3 na 3,85e-3). Od 3.0.0 podatność to samo c₀ · r / r_ref, bez ρ i bez wykładników: ta sama siła ściska każdą bańkę o ten sam ułamek promienia, ε = c₀ · F / r_ref, a w parze wgniecenie dzieli się w proporcji promieni. Kontur pokazuje tylko bieżące kontakty: kontakt, który zniknął, znika z konturu w tej samej klatce.
- **Tłumienie kontaktu miękkiego.** `PhysicsMaterial.contactDampingRatio` (ζ_c, domyślnie 1) to ułamek tłumienia krytycznego sprężyny kontaktu: 1 ustawia bańkę bez przestrzelenia, 0,2 daje kilka drgań, 0 drgania bez tłumienia. W parze obowiązuje średnia ζ_c obu baniek, przy ścianie wartość bańki. Dotyczy tylko kontaktów z podatnością > 0; materiał `.rigid` przyjmuje tylko 1, a ujemna albo nieskończona wartość rzuca `valueOutOfRange`. Tłumik normalny działa poniżej prędkości `restSpeed` = max(40, 2r), więc bańka dociągnięta do ściany szybciej uderza bez tłumienia i może się odbić; kontakty twarde tłumi dotychczasowe `damping` kontaktu.
- **Zły punkt.** `add` i `replace` bańki z punktem poza `simulationRegion` (także przy `regionExitPolicy == .wrap`), we wnętrzu bryły sztywnej albo w prawie wspólnym środku z inną bańką odrzucają całą transakcję zdarzeniem `transactionRejected` z `invalidPlacement(ObjectID, PlacementIssue)`. ID wskazuje bańkę z błędnym punktem, a `PlacementIssue` przyczynę; transakcja zostaje poza kolejką, więc gra podaje nowy punkt kolejną transakcją. `mergeBubbles` i `splitBubble` same poprawiają punkt wyniku i odrzucają transakcję dopiero wtedy, gdy nie ma poprawnego kandydata.

## Chwyt gumką

Chwyt jest jedynym napędem baniek z palca, a jego narzędziem jest gumka siłowa: `BubbleDrivePolicy(bandStiffness: K, maximumForce: F)`. Polityka należy do bańki (`BubbleDescriptor.drivePolicy`, a dla wyniku scalenia albo części podziału `BubbleResult.drivePolicy`). Bańka z `drivePolicy` równym `nil` (domyślnie) i bryła nie dają się chwycić: `beginPlayerDrive` odrzuca je z `incompatibleObjectKind(id)`, ruch zostaje bez zmian. Chwycona bańka dostaje siłę K · (cel − położenie), obciętą do `maximumForce` z zachowaniem kierunku. Do niej dochodzą siła globalna i pola sił jak przy bańce `.dynamic`. Chwyt nie zmienia promienia ani kształtu bańki: nie ma usztywniania ani narzuconej prędkości.

Jedno tłumienie ruchu: `damping` materiału (γ). Host mnoży prędkość przez e^(−γ · dt) przed dodaniem przyrostu z sił, więc `v ← v · e^(−γ · dt) + F / m · dt`. Siła działa w całości, także w spoczynku przy ścianie: bańka dociśnięta gumką w nasyceniu ugina się dokładnie o c · `maximumForce`, tak samo jak przy `MotorDrive` albo sile globalnej o tym samym module, bez względu na γ i masę. Prędkość narzucona torem (`.pathDriven`, bryła kinematyczna) nie jest tłumiona.

- **Prędkość ustalona.** Bez kontaktów, przy stałym naciągnięciu s i sile poniżej `maximumForce`, bańka ustala się na v = K · s · dt / (m · (1 − e^(−γ · dt))), w przybliżeniu K · s / (m · γ). Lżejsza jedzie szybciej w odwrotnej proporcji do masy. Przy γ = 0 nie ma tłumienia i bańka przyspiesza do `maximumLinearSpeed`, więc ustaw γ w materiale, jeśli chcesz prędkość ustaloną.
- **Zakres K.** Siła jest całkowana jawnie, więc K · dt² / m musi być mniejsze od 1. Przy kroku 1/60 to K < 3600 · m (dla m = 1,36 około 4 900). Wstawienie, zamiana, scalenie i podział, które dają bańkę z polityką poza zakresem, odrzucają transakcję z `invalidValue(.valueOutOfRange("drive.bandStiffness"))`, a podział zmniejsza masę, więc może wyjść poza zakres. Rozsądne strojenie to K rzędu 0,4–50 przy naciągnięciu rzędu 100–700 jednostek, z zapasem około 100 razy do granicy.
- **Pola.** `bandStiffness` i `maximumForce` rzucają `valueOutOfRange("drive.bandStiffness")` i `("drive.maximumForce")` dla wartości niedodatnich albo nieskończonych. Pola `bandDamping` nie ma. Cel w `beginPlayerDrive` i `updatePlayerDrive` o składowej poza limitem `MotorDrive` jest odrzucany.
- **Puszczenie.** `endPlayerDrive` nie zmienia prędkości: w ramce po puszczeniu bańka ma prędkość z ostatniego kroku napędu i leci dalej, hamowana tylko tłumieniem materiału.
- **Zmiana struktury.** `replace`, scalenie i podział chwyconej bańki kończą chwyt: nie ma `DriveFeedback`, a `updatePlayerDrive` i `endPlayerDrive` dają `driveNotActive` albo `objectNotFound`. Ponowny chwyt wyniku jest możliwy tylko wtedy, gdy wynik ma `drivePolicy`.
- **Ramki.** `DriveFeedback.target` i `achievedPoint` ramki N podają naciągnięcie, z którego liczona jest siła w kroku N + 1: przyrost prędkości między ramkami to K · (target − achievedPoint) / m · dt.

### Wystrzał z zawartej pary miękkiej

Para miękka, w której mniejsza bańka leży cała w większej, rozsuwa się bez odrzucenia kroku, ale energia ściśnięcia się uwalnia: mniejsza bańka zostaje wystrzelona z prędkością do `maximumLinearSpeed`. Ta granica ogranicza prędkość po wystrzale, nie skok pozycji w kroku wyjścia z zawierania: przy bardzo małej podatności skok może sięgnąć pełnego nakładania, a kontrola ruchu ciągłego (CCD) sprawdza tylko odcinki ruchu środków, więc nie chroni przed przejściem przez inną bańkę. Gwarancja przesunięcia nie większego niż 0,25 · min r na krok z 2.2.0 obowiązuje tylko pary twarde. Wystrzałów unika się, nie dopuszczając do głębokich zawierań: nie dodawaj baniek wewnątrz innych i ustaw `maximumLinearSpeed` w materiale baniek.

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
        .updatePhysicsMaterial(Self.bubblePhysics, material: try PhysicsMaterial(kind: .bubble, deformability: 0.6))
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

`BubbleResult` ma też `drivePolicy:`, `mass:` i `contactCompliance:` na końcu parametrów. `drivePolicy:` (domyślnie `nil`) to polityka chwytu wyniku scalenia albo części podziału, z której korzysta `beginPlayerDrive` na nowej bańce. Wynik bez polityki nie daje się chwycić, więc scena z chwytem podaje ją w każdym wyniku, tak jak w `BubbleDescriptor` (przykład: `BubbleDrivePolicy(bandStiffness: 20, maximumForce: 600)`). `mass:` (domyślnie `nil`, czyli suma mas źródeł) nadpisuje masę wyniku scalenia. Prędkość liniowa i kątowa wyniku zawsze pochodzą z mas źródeł (pęd i moment pędu źródeł podzielone przez ich sumę mas i wynikającą z niej bezwładność), więc nadpisana masa wpływa tylko na dalszą fizykę. W `splitBubble` `mass` różne od `nil` w którejkolwiek części odrzuca transakcję z `invalidStructuralOperation`. `contactCompliance:` (domyślnie `nil`, czyli podatność z materiału) nadpisuje podstawową podatność kontaktu wyniku scalenia albo części podziału; opisuje ją sekcja „Tłok baniek, podatność kontaktu i zły punkt”.

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
