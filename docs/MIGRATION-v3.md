# Migracja z BubblePhysics 2.x do 3.0.0

Wersja 3.0.0 zmienia model podatności kontaktu i usuwa dwa parametry z publicznego API. Dokument zbiera zmiany wycinek po wycinku: ta wersja opisuje pierwszy z nich, podatność c₀ · r / r_ref. Kolejne punkty (tłumienie ruchu, gumka jako jedyny napęd, krawędzie ścian, kontur tylko rysowany) dopisują następne wycinki.

## Podatność kontaktu: c = c₀ · r / r_ref

W 2.x podatność bańki to c = c₀ · (r / r_ref)^s · ρ^k, gdzie s to `radiusExponent`, k to `compressionExponent`, a ρ to stosunek promienia konturu do r w kierunku kontaktu. W 3.0.0 zostaje c = c₀ · r / r_ref, gdzie r to bieżący promień fizyczny bańki. Wynika z tego:

- Ta sama siła F ugina każdą bańkę o ten sam ułamek promienia: ugięcie / r = c₀ · F / r_ref, niezależnie od r.
- W parze wgniecenie dzieli się w proporcji podatności, czyli promieni, a nakładanie kół to (c_a + c_b) · F.
- Podatność nie zależy od ściśnięcia konturu, więc bańka nie sztywnieje wraz z nakładaniem (jak dla k = 0 w 2.x).

### Co zmienić w kodzie

| Symbol z 2.x | Zamiennik w 3.0.0 |
|--------------|-------------------|
| `BubbleContactCompliance(base:referenceRadius:radiusExponent:compressionExponent:)` | `BubbleContactCompliance(base:referenceRadius:)`. Wywołanie z wykładnikami przestaje się kompilować. |
| `BubbleContactCompliance.radiusExponent` | Brak. Odpowiada stałemu s = 1. |
| `BubbleContactCompliance.compressionExponent` | Brak. Odpowiada stałemu k = 0. |
| `ModelValidationError.valueOutOfRange("contactCompliance.radiusExponent")` i `("contactCompliance.compressionExponent")` | Brak: pola nie istnieją. Zostają `contactCompliance.base` i `contactCompliance.referenceRadius`. |

### Przestrojenie c₀

Gra, która miała s = 1 i k = 0, zachowuje c₀ i r_ref bez zmian: wzór daje ten sam wynik. Inne konfiguracje trzeba przeliczyć tak, by ugięcie przy docelowej sile i docelowym promieniu zostało takie samo.

- **s ≠ 1.** Dawna podatność bańki o promieniu r to c₀ · (r / r_ref)^s, nowa to c₀' · r / r_ref. Wybierz promień r_cel, przy którym ugięcie ma się zgadzać, i ustaw c₀' = c₀ · (r_cel / r_ref)^(s − 1). Dla innych promieni ugięcie względne będzie teraz takie samo, a nie zależne od r^(s − 1).
- **k ≠ 0.** Dawny kontakt sztywniał wraz ze ściśnięciem (k > 0) albo mięknął (k < 0). Nowy jest liniową sprężyną. Wybierz typowe ściśnięcie ρ_typ i ustaw c₀' = c₀ · ρ_typ^k. Przy większym ściśnięciu niż typowe bańka ugnie się teraz o więcej (k > 0) albo o mniej (k < 0) niż dawniej, a ugięcie rośnie liniowo z siłą.
- **Zwiększenie r_ref przy stałym c₀** zmniejsza podatność każdej bańki w tej samej proporcji, więc r_ref i c₀ da się przestrajać razem: liczy się tylko iloraz c₀ / r_ref.

Wartości `base`, przy których α pary przepełnia `Float` przy największym promieniu bańki, nadal odrzuca transakcja z `invalidValue(.valueOutOfRange("contactCompliance"))`; granica to teraz c₀ · r_max / r_ref.
