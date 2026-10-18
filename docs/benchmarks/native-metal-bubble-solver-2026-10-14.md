# Wynik bramki GPU-native na iPhonie

## Warunki

- urządzenie: iPhone z iOS 16.7.16;
- Release, warmup 30, measured 300, seed 2842869;
- backend: `native-metal`;
- sceny: `interactive-24` i `stress-300`;
- limity XPBD/PBD: 4, 8, 12, 16;
- surowy raport bez ręcznego przepisywania: `native-metal-bubble-solver-iphone-2026-10-14.txt`.

## Wynik

| Scena | Limit | Full p95 [ms] | GPU p95 [ms] | Envelope | Fallback / containment / non-finite |
| --- | ---: | ---: | ---: | --- | --- |
| interactive-24 | 4 | 4.7509 | 2.2858 | pass | 0 / 0 / no |
| interactive-24 | 8 | 5.4147 | 2.6482 | pass | 0 / 0 / no |
| interactive-24 | 12 | 5.9332 | 2.9061 | pass | 0 / 0 / no |
| interactive-24 | 16 | 6.5293 | 3.2595 | pass | 0 / 0 / no |
| stress-300 | 4 | 10.4568 | 6.4945 | pass | 0 / 0 / no |
| stress-300 | 8 | 11.3555 | 6.9822 | pass | 0 / 0 / no |
| stress-300 | 12 | 12.2890 | 7.6809 | pass | 0 / 0 / no |
| stress-300 | 16 | 13.6425 | 8.6050 | pass | 0 / 0 / no |

Każdy limit ma 330 klatek native GPU, zero fallbacków, jeden command buffer i dwa encodery na klatkę. Hash powtórzonej sekwencji jest identyczny dla każdego limitu. Kontrolne pomiary envelope potwierdzają brak narastających oscylacji, powrót konturu po zwolnieniu i brak ruchu w spoczynku.

## Ocena

Limit 4 jest jedynym rekomendowanym ustawieniem produkcyjnym. Daje najlepszy czas w obu scenach, a wszystkie twarde bramki jakości przechodzą. Wyższe limity nie dają podstaw do wyboru: zwiększają czas, a envelope już przechodzi dla limitu 4.

`interactive-24` mieści się z dużym zapasem w roboczym budżecie 10 ms p95. `stress-300` osiąga 10.4568 ms p95, tj. 0.4568 ms (4.6%) ponad ten budżet. CEO 2026-10-14 zaakceptował takie minimalne przekroczenie dla iPhone'a X, pod warunkiem utrzymania zero fallbacków, zero containment i `native_quality_envelope=pass`; wszystkie te warunki są spełnione.

Wniosek: GPU-native backend spełnia bramkę jakości oraz zaakceptowaną bramkę wydajności dla około 300 baniek na iPhonie X. CPU pozostaje wyrocznią scen i fallbackiem, ale nie jest ścieżką pomiaru GPU.
