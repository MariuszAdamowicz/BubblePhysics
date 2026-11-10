# BubblePhysics 2.0 — punkt kontrolny etapu 8 na iPhonie X

- Data: 2026-11-10; iPhone X, iOS 16.7.16; Xcode 26.6, konfiguracja Release.
- Mierzony commit: `2c22f8434ab5cd2c8471dd210b69cf2ab69f8f7a` (`feature/engine-foundations`).
- Poprzednią aplikację odinstalowano przed instalacją nowego buildu. Surowy raport skopiowany z aplikacji przez właściciela:

```text
path=public BubbleWorld + BubblePhysicsMetalRender, same command buffer
device=Apple A11 GPU
scene=acceptance; solver_iteration_limit=4
render_px=1125x2436
warmup=30; measured=300
p95_ms=21.7425; max_ms=22.6132
gpu_p95_ms=14.8024; host_non_gpu_p95_ms=7.0520
host_preparation_p95_ms=1.3465; host_publication_p95_ms=2.1670
host_encoding_p95_ms=2.4216; host_waiting_p95_ms=16.0126
gpu_physics_p95_ms=8.4717; gpu_render_estimate_ms=6.3307
guard_corrections=0; non_finite_frames=0
fallback_frames=0; failed_frames=0
contour_cpu_readbacks=0
contact_candidate_overflow=0; max_candidates_per_object=32; candidate_limit=128
safety=pass
native_quality_envelope=not_evaluated_by_this_harness
p95_gate_ms=16.6700; p95_gate=fail
```

P95 pełnej klatki przekracza próg o 5,0725 ms; bramka wydajności nie jest spełniona. Nie odnotowano błędnych klatek, wartości non-finite, fallbacków, odczytów konturów na CPU ani przepełnień kandydatów; maksimum 32 kandydatów mieści się w połowie limitu 128. Harness nie ocenił `native_quality_envelope`.

Weryfikacja prognozy na Macu (`swift run -c release BubblePhysicsPerfGuard --scene acceptance --check-prediction docs/benchmarks/v2-iphone-x-checkpoint-8.md`, ten sam kod co mierzony commit; zmiany po nim dotyczą tylko dokumentacji). Pierwszy przebieg, zapisany w commicie 7502742; jego średnie obciążenie (`uptime`) nie zostało zapisane (maszynę opisano jako bezczynną, bez liczby):

```text
PREDICT iphone-x acceptance: p95=19.8663 cpu=4.8947 physics=8.5523 render=6.4193 target=15.00 gate=16.67
PREDICTION_ERROR p95=21.7425 predicted=19.8663 error=-8.6% limit=10.0% PASS
```

Powtórzenia na tym samym kodzie, z zapisanym obciążeniem; oryginalnych liczb nie zastępują:

```text
# uptime przed przebiegiem: load averages: 1,85 2,25 2,43 (po: 1,80 2,22 2,41)
PREDICT iphone-x acceptance: p95=19.7994 cpu=4.7236 physics=8.6565 render=6.4193 target=15.00 gate=16.67
PREDICTION_ERROR p95=21.7425 predicted=19.7994 error=-8.9% limit=10.0% PASS
```

Przebieg weryfikacyjny zadania 89 zaraz po commicie (bez zapisanego obciążenia) dał `predicted=20.1069 cpu=4.9664 error=-7.5% PASS`. Wszystkie trzy przebiegi mieszczą się w limicie 10% (od -7,5% do -8,9%); obciążenie 1-minutowe powtórzenia było poniżej 2, ale średnie 5- i 15-minutowe nieco powyżej (2,25 i 2,43).

Błąd prognozy łącznego p95 -8,6% mieści się w limicie 10%, ale porównanie składowych (pierwszy przebieg, błąd = (prognoza − pomiar) / pomiar, jak w `PREDICTION_ERROR`) pokazuje, że niemal cały błąd leży w CPU:

| Składowa | Prognoza z Maca (ms) | Raport iPhone'a (ms) | Błąd |
| --- | --- | --- | --- |
| CPU | 4,8947 | 7,0520 (`host_non_gpu_p95_ms`) | -30,6% |
| fizyka GPU | 8,5523 | 8,4717 (`gpu_physics_p95_ms`) | +1,0% |
| render GPU | 6,4193 | 6,3307 (`gpu_render_estimate_ms`) | +1,4% |

Składowe GPU zgadzają się z urządzeniem w granicach 1,5% (prognoza o 0,17 ms wyższa łącznie). Składowa CPU nie: prognoza zaniża ją o 2,16 ms (30,6%), a to właśnie ten niedobór tworzy niemal cały łączny błąd -8,6% (-1,88 ms względem p95 klatki 21,74 ms; suma p95 składowych z urządzenia to 21,85 ms).

Kalibracja przyjęła stosunek CPU iPhone/Mac 3,93 (`ratios.cpu` w `docs/benchmarks/iphone-x-calibration.json`). Wartość CPU Maca w pierwszym przebiegu to 4,8947 / 3,9272 ≈ 1,246 ms, więc rzeczywisty stosunek CPU iPhone/Mac wynosi teraz około 5,66 (7,052 / 1,246), a nie 3,93. Cel CPU ≤ 5,0 ms jest więc spełniony tylko w prognozie (4,89 ms); na urządzeniu CPU to 7,05 ms. Przy CPU 7,05 ms luka do bramki 16,67 ms to 5,07 ms (p95 21,74 ms), a sam GPU musiałby ją domknąć: z 14,80 ms obecnych do około 9,6 ms (16,67 − 7,05).

Błąd łączny mieści się w limicie, więc zgodnie z zadaniem 89 nie jest odchyleniem. Czy etap 9 ma ponownie skalibrować stosunek CPU (na podstawie tego raportu), decyduje właściciel.
