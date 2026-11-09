# Migracja z BubblePhysics 1.x do 2.0.0

Wersja 2.0.0 zmienia publiczne API. Ten dokument podaje zamiennik każdego symbolu, który `v1.0.0` miał, a 2.0.0 usuwa albo zmienia. Lista symboli pochodzi z `swift-api-digester -diagnose-sdk` i leży w [`migration/v1-api-diff.txt`](migration/v1-api-diff.txt); test `MigrationGuideTests` pilnuje, żeby każdy wiersz tego diffu miał wpis w tabelach niżej. Nowe możliwości 2.0.0 (bryły, więzy, zapytania, naklejki, warstwy) opisuje [przewodnik integracji](integration-guide.md).

Zmiana, która dotyka każdej gry: **świat renderuje materiały, a nie style**. Reszta to w większości zmiany nazw i usunięcia kanałów, które czytały tylko usunięte shadery.

## Materiały zamiast stylów

`RenderStyle` z własnym shaderem zastąpił `RenderMaterial`: tekstura (`TextureID` z rejestru `BubblePhysicsAssets`), kolor `RGBA`, tryb mieszania (`.opaque`, `.alpha`, `.additive`), obrys, odwzorowanie tekstury na bańce (`.attached` albo `.masked`) oraz `uvOffset` i `uvScale` dla brył. Zasoby graficzne rejestruje się w `AssetRegistry` (`world.assets`), nie w stylu.

| Symbol z v1 | Zamiennik w 2.0.0 |
|-------------|-------------------|
| `RenderStyle` | `RenderMaterial(texture:color:blend:outline:bubbleMapping:uvOffset:uvScale:)`. Kolor stały to `color`, tekstura to `TextureID` z `world.assets!.register(_:)`. |
| `RenderStyleID` | `RenderMaterialID` (ta sama rola: liczba, którą gra wybiera sama). |
| `RenderShader` | Brak. Własne shadery usunięto razem z `customPipelines`; do własnego rysowania służy `RenderHooks` (`afterBackground`, `afterLayer`, `overlay`) w tym samym passie. |
| `WorldTransaction.updateRenderStyle`, `WorldOperation.updateRenderStyle` | `WorldTransaction.updateRenderMaterial(_:material:)` i `WorldOperation.updateRenderMaterial`. |
| `BubbleDescriptor.renderStyleID`, `BubbleResult.renderStyleID` | `renderMaterialID`. Deskryptor i wynik scalenia dostają też `layer: Int32` (domyślnie 0) i `decal: Decal?` (domyślnie `nil`). |
| `BubbleDescriptor.init`, `BubbleResult.init` | Te same parametry z `renderMaterialID:` zamiast `renderStyleID:`, bez `presentation:`, z `layer:` i `decal:` na końcu. |
| `TransactionRejectionReason.renderStyleNotFound`, `TransactionRejectionReason.renderMaterialNotFound` | `renderMaterialNotFound` zastępuje `renderStyleNotFound`: materiał renderu nie jest zarejestrowany. |
| `TransactionRejectionReason.textureNotFound`, `TransactionRejectionReason.layerNotSupported`, `TransactionRejectionReason.fontNotFound`, `TransactionRejectionReason.glyphAtlasNotFound`, `TransactionRejectionReason.characterNotInGlyphSet`, `TransactionRejectionReason.decalNotSupported` | Nowe powody odrzucenia: tekstura, czcionka albo atlas glifów spoza rejestru, znak spoza zestawu naklejki, warstwa albo naklejka na obiekcie, który ich nie ma (czujnik, pole sił). `switch` po `TransactionRejectionReason` wymaga nowych przypadków. |
| `TransactionRejectionReason.jointNotFound`, `TransactionRejectionReason.duplicateJointID`, `TransactionRejectionReason.unsupportedJointBody` | Nowe powody odrzucenia operacji na więzach (nieznany więz, powtórzony `JointID`, ciało, którego więz nie obsługuje). |

## Bryły: `RigidBodyDescriptor` zamiast wielokątów

Wielokąt jest teraz jednym z kształtów sztywnej bryły. `RigidShape` ma trzy rodzaje: `.polygon(PolygonGeometry)`, `.circle(radius:)` i `.capsule(halfLength:radius:)`. Bryły mogą być statyczne, dynamiczne albo kinematyczne.

| Symbol z v1 | Zamiennik w 2.0.0 |
|-------------|-------------------|
| `PolygonDescriptor` | `RigidBodyDescriptor(id:vertices:…)` (skrót dla wielokąta) albo `RigidBodyDescriptor(id:shape:…)`. Rola ruchu to `motionRole` (domyślnie `.static`). |
| `WorldObject.polygon` | `WorldObject.rigidBody`. |
| `WorldTransaction.replacePolygons`, `WorldOperation.replacePolygons` | `WorldTransaction.replaceRigidBodies(_:with:)` i `WorldOperation.replaceRigidBodies`. |
| `PhysicsMaterialKind.polygon`, `PhysicsMaterialKind.rigid` | `.rigid` zastępuje `.polygon` (dla wielokąta, koła i kapsuły). |
| `WorldConfiguration.validate` | Przyjmuje `RigidBodyDescriptor` zamiast `PolygonDescriptor`. |
| `MotionRole.kinematic` | Nowa rola bez wartości powiązanej. `switch` po `MotionRole` wymaga nowego przypadku; ruch zadaje `WorldTransaction.setKinematicDrive(_:drive:)` z `KinematicDrive` (`.velocity`, `.path`, `.target`). |
| `WorldObject.rigidBody` | Nowy przypadek obiektu (zamiast `.polygon`). `switch` po `WorldObject` wymaga go obsłużyć. |
| `WorldOperation.addJoint`, `WorldOperation.removeJoint`, `WorldOperation.replaceRigidBodies`, `WorldOperation.setBackground`, `WorldOperation.setDecal`, `WorldOperation.setKinematicDrive`, `WorldOperation.setLayer`, `WorldOperation.updateRenderMaterial` | Nowe przypadki operacji. `switch` po `WorldOperation` wymaga ich obsługi (zwykle `default`). Wywołujesz je metodami `WorldTransaction`: `addJoint`, `removeJoint`, `setBackground`, `setDecal`, `setLayer`, `setKinematicDrive`. |

## Usunięte kanały prezentacji

Kanały parametrów renderu czytały tylko własne shadery, więc po ich usunięciu nie mają odbiorcy. Materiał renderu zmienia się transakcją `updateRenderMaterial`; przejścia (`ParameterTransition`) dotyczą wyłącznie parametrów fizyki.

| Symbol z v1 | Zamiennik w 2.0.0 |
|-------------|-------------------|
| `PresentationParameters` | Brak. Wartość zmienną w czasie przechowaj w grze i przekaż jako nowy `RenderMaterial`. |
| `ParameterID` | Brak (kanały usunięto). |
| `BubbleDescriptor.presentation`, `BubbleResult.presentation`, `SensorDescriptor.presentation`, `ForceFieldDescriptor.presentation` | Brak. Usuń argument `presentation:`. |
| `TransitionTarget.renderStyle`, `TransitionTarget.objectPresentation` | Brak. Przejścia zostają dla parametrów fizyki (`PhysicsParameter`). |

## Czujniki i pola sił bez stylu

Czujniki i pola sił są niewidocznymi obszarami logiki: nie są rysowane i nie mają materiału. W `v1` rysowały się jak kształty. Jeśli gra chce je pokazać, rysuje je sama przez `RenderHooks`.

| Symbol z v1 | Zamiennik w 2.0.0 |
|-------------|-------------------|
| `SensorDescriptor.renderStyleID`, `SensorDescriptor.presentation`, `SensorDescriptor.init` | Deskryptor czujnika nie ma stylu: `SensorDescriptor(id:position:rotation:geometry:filter:regionExitPolicy:eventInterest:)`. |
| `ForceFieldDescriptor.renderStyleID`, `ForceFieldDescriptor.presentation`, `ForceFieldDescriptor.init` | Deskryptor pola sił nie ma stylu: usuń `renderStyleID:` i `presentation:` z wywołania. |

## Nowe skutki błędów

`v1` ponawiał krok po każdym błędzie. W 2.0.0 skutek zależy od rodzaju błędu:

- Błąd wykonania bufora na GPU albo wartości nieskończone (NaN, ±∞) kończą świat: `diagnostics.failureReason`, `lastAdvanceIssue == .worldFailed`. Kolejka transakcji jest porzucana, `advance` i `submit` nic nie robią. Gra tworzy nowy `BubbleWorld`.
- Błąd rzucony przez domknięcie `encodeRender` gry albo kodowanie renderu odrzuca tylko klatkę: `lastAdvanceIssue == .frameRejected`, kolejka czeka na kolejne `advance`.
- Pozostałe błędy solvera odrzucają krok (`.stepFailed`, powód w `diagnostics.lastRejectionReason`), jak w `v1`.

| Symbol z v1 | Zamiennik w 2.0.0 |
|-------------|-------------------|
| `WorldAdvanceIssue.worldFailed` | Nowy przypadek: świat w stanie końcowym. Obsłuż go tworząc nowy świat. |
| `WorldAdvanceIssue.frameRejected` | Nowy przypadek: odrzucona klatka; popraw kod rysowania i wywołaj `advance` ponownie. |

Ponadto `WorldConfiguration` dostał `maximumBacklog` (domyślnie 0,25 s) i `automaticPause` (domyślnie włączona: świat pauzuje w tle i po powrocie odrzuca pierwszy przyrost czasu); `didRenderLastAdvance` w diagnostyce mówi, czy drawable wolno zaprezentować.

## Zdarzenia, konfiguracja i konstruktory

Usunięcie obiektu po wyjściu z regionu symulacji nie jest transakcją, więc nie ma potwierdzenia: więzy takiego ciała znikają razem z nim, a gra dowiaduje się o tym ze zdarzenia `didExitSimulationRegion` (`EventInterest.didExitSimulationRegion`), jak dotąd dla baniek.

| Symbol z v1 | Zamiennik w 2.0.0 |
|-------------|-------------------|
| `WorldEvent.contactBegan`, `WorldEvent.contactEnded` | Nowe zdarzenia kontaktu, dostarczane obiektom z `EventInterest.contact`. `switch` po `WorldEvent` wymaga nowych przypadków. Do scalania baniek używa się `mergeContact`, który zostaje. |
| `WorldConfiguration.init` | Te same pierwsze parametry (`simulationRegion:fixedTimeStep:eventBufferCapacity:globalForce:`), plus `maximumBacklog:` i `automaticPause:` z wartościami domyślnymi; istniejące wywołania kompilują się bez zmian. |
| `PhysicsMaterial.init` | Plus `maximumLinearSpeed:` i `maximumAngularSpeed:` (domyślnie `nil`, brak limitu); istniejące wywołania kompilują się bez zmian. |
| `BubbleDrivePolicy.init` | Plus `maximumSpeed:` i `distanceResponse:` (wartości domyślne); istniejące wywołania kompilują się bez zmian. |
| `TransactionReceipt.init`, `WorldFrame.init` | Nie są już publiczne: gra dostaje te wartości od świata. Odbiór `WorldFrame.objects` i `TransactionReceipt.removedJointIDs` jest nowy. |
| `BubbleWorld.init` | `BubbleWorld(configuration:device:assets:lifecycle:)`: `assets` to opcjonalny `AssetRegistry` (`nil` tworzy pusty rejestr świata), `lifecycle` to źródło zdarzeń cyklu życia (domyślnie UIKit). Rejestr innego urządzenia daje `AssetError.deviceMismatch`. |
| `BubbleWorldRenderState`, `BubbleWorldRenderState.items`, `BubbleWorldRenderState.shapes`, `BubbleWorldRenderShape`, `BubbleWorldRenderShape.item`, `BubbleWorldRenderShape.vertices`, `BubbleWorldRenderItem` | Typy stanu renderu nie są już publiczne. Rysuj przez `BubblePhysicsMetalRender.encode(world:viewport:commandBuffer:renderPassDescriptor:hooks:)`; własne rysowanie dokładaj przez `RenderHooks`. |

## Renderer i benchmark

| Symbol z v1 | Zamiennik w 2.0.0 |
|-------------|-------------------|
| `BubblePhysicsMetalRender.init`, `BubblePhysicsMetalRender.customPipelines` | `BubblePhysicsMetalRender(device:assets:)` z rejestrem świata (`world.assets`). Własnych potoków nie ma. |
| `BubblePhysicsMetalRender.makeContourVertexFunction`, `RenderStylePipeline` | Brak (własne shadery usunięto). Własne rysowanie przez `RenderHooks`. |
| `BubblePhysicsMetalRender.encode` | `encode(world:viewport:commandBuffer:renderPassDescriptor:hooks:)`; `hooks` ma wartość domyślną `.none`, więc dotychczasowe wywołania działają. Pass wymaga tylko koloru, bez bufora szablonu. |
| `BubblePhysicsMetalRenderError.bufferAllocationFailed` | Nowy przypadek: nie udało się przydzielić bufora pomocniczego klatki. Błąd odrzuca klatkę (`.frameRejected`). |
| `PublicWorldStressBenchmark.measure` | `measure(device:scene:renderSize:progress:)`: scena (`.stress(bubbleCount:)`, `.mixed`, `.decals`, `.acceptance`) i rozmiar celu w pikselach (`nil`: 375 × wysokość regionu). |
| `PublicWorldStressBenchmark.run` | Nie jest już publiczny; używaj `measure(device:scene:renderSize:progress:)`. |

## Narzędzia diagnostyczne w `BubblePhysicsNativeMetalDiagnostics`

Narzędzia, które budowały wejście solvera przez `ReferenceWorld`, przeniesiono z `BubblePhysicsNativeMetal` do nowego modułu `BubblePhysicsNativeMetalDiagnostics` (w produkcie `BubblePhysicsBenchmarkSupport`): `NativeMetalBenchmarkRunner`, `NativeMetalWorldRunner`, `VisualSimulationDriver`, `NativeMetalVisualReplay` i `NativeMetalQualityEnvelope`, razem z adapterem `ReferenceSolverInputAdapter`. `BubblePhysicsNativeMetal` nie reeksportuje już `BubblePhysicsReference`, więc kod, który korzystał z tych narzędzi, dopisuje `import BubblePhysicsNativeMetalDiagnostics` (i `import BubblePhysicsReference`, gdy używa `ReferenceWorld`). Gry produkcyjne nie zależą od żadnego z tych modułów.
