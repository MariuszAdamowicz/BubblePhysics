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
            decal: try decal(for: value))
        let token = world.submit(WorldTransaction().mergeBubbles([first, second], result: result))
        pendingMerges[token] = PendingMerge(sources: [first, second], result: id, value: value)
    } catch {
        print("Showcase: nie udało się zbudować scalenia: \(error)")
    }
}
```

`BubbleResult` ma też `drivePolicy:` i `mass:` na końcu parametrów. `drivePolicy:` (domyślnie `.standard`) to polityka jazdy wyniku scalenia albo części podziału, z której korzysta `beginPlayerDrive` na nowej bańce, np. `BubbleDrivePolicy(maximumSpeed: 3)` dla wolniej prowadzonej bańki. `mass:` (domyślnie `nil`, czyli suma mas źródeł) nadpisuje masę wyniku scalenia. Prędkość wyniku zawsze wynosi pęd źródeł podzielony przez sumę ich mas, więc nadpisana masa wpływa tylko na dalszą fizykę. W `splitBubble` `mass` różne od `nil` w którejkolwiek części odrzuca transakcję z `invalidStructuralOperation`.

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
