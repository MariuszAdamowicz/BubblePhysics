# BubblePhysics 2.0 — punkt kontrolny etapu 9 na iPhonie X

- Data: 2026-11-11; iPhone X, iOS 16.7.16; Xcode 26.6, konfiguracja Release.
- Mierzony commit: `c02571a82044b2e5fcc61be8b722257670ecfa63` (`feature/engine-foundations`).
- Poprzednią aplikację odinstalowano przed instalacją nowego buildu. Surowy raport skopiowany z aplikacji przez właściciela:

```text
path=public BubbleWorld + BubblePhysicsMetalRender, same command buffer
device=Apple A11 GPU
scene=acceptance; solver_iteration_limit=4
render_px=1125x2436
warmup=30; measured=300
p95_ms=20.5663; max_ms=22.9698
gpu_p95_ms=14.3997; host_non_gpu_p95_ms=6.4720
host_preparation_p95_ms=1.3730; host_publication_p95_ms=2.2969
host_encoding_p95_ms=2.0140; host_waiting_p95_ms=15.5588
gpu_physics_p95_ms=8.0262; gpu_render_estimate_ms=6.3735
gpu_render_clear_estimate_ms=0.9313; gpu_render_decals_estimate_ms=2.3563
guard_corrections=0; non_finite_frames=0
fallback_frames=0; failed_frames=0
contour_cpu_readbacks=0
contact_candidate_overflow=0; max_candidates_per_object=32; candidate_limit=128
safety=pass
native_quality_envelope=not_evaluated_by_this_harness
p95_gate_ms=16.6700; p95_gate=fail
```

P95 pełnej klatki przekracza próg o 3,8963 ms; bramka wydajności nie jest spełniona. Nie odnotowano błędnych klatek, wartości non-finite, fallbacków, odczytów konturów na CPU ani przepełnień kandydatów; maksimum 32 kandydatów mieści się w połowie limitu 128. Harness nie ocenił `native_quality_envelope`.

Fizyka GPU `8,0262 ms` przekracza próg `6,0 ms` wskazany w zadaniu 98: plan przewiduje zatrzymanie i decyzję właściciela. Weryfikacja prognozy na Macu, ocena wykonalności renderu oraz nowa kalibracja pozostają do wykonania zgodnie z zadaniem 98.

## Weryfikacja prognozy i decyzja wykonalności renderu (zadanie 98, agent)

Weryfikacja prognozy na Macu (`swift run -c release BubblePhysicsPerfGuard --scene acceptance --check-prediction <kopia tego raportu spoza drzewa>`), w tymczasowym detached worktree na mierzonym commicie `c02571a` (kod równy `3c51d19`; zmiany po nim dotyczą tylko dokumentacji), z kalibracją z punktu kontrolnego 8 (`cpu` 5,853, `physics` 5,155), czyli sprzed tego pomiaru. Obciążenie (`uptime`) przed przebiegiem: load averages 0,83 2,86 4,83, po: 1,59 2,77 4,69:

```text
PREDICT iphone-x acceptance: p95=18.7811 cpu=6.6275 physics=5.8229 render=6.3307 target=15.00 gate=16.67
PREDICT_CPU iphone-x acceptance: preparation=1.3391 encoding=2.0296 publication=2.1426 waiting=1.1163
PREDICTION_ERROR p95=20.5663 predicted=18.7811 error=-8.7% limit=10.0% PASS
```

Błąd łączny -8,7% mieści się w limicie 10%, ale rozkład po składowych (błąd = (prognoza − pomiar) / pomiar) pokazuje, że tym razem zawodzi fizyka, a nie CPU:

| Składowa | Prognoza z Maca (ms) | Raport iPhone'a (ms) | Błąd |
| --- | --- | --- | --- |
| CPU | 6,6275 | 6,4720 (`host_non_gpu_p95_ms`) | +2,4% |
| fizyka GPU | 5,8229 | 8,0262 (`gpu_physics_p95_ms`) | -27,5% |
| render GPU | 6,3307 (z kalibracji) | 6,3735 (`gpu_render_estimate_ms`) | -0,7% |

Kalibracja CPU z punktu kontrolnego 8 trafia teraz w granicach 2,4%. Składowa fizyki jest zaniżona o 2,20 ms: na Macu fizyka GPU spadła z 1,6434 do 1,1303 ms (-31%), a na iPhonie X tylko z 8,4717 do 8,0262 ms (-5%). Zysk z poprawek etapu 9 na Macu prawie nie przekłada się więc na A11, a rzeczywisty stosunek fizyki iPhone/Mac to około 7,10 zamiast skalibrowanego 5,16. Błąd łączny -1,79 ms (-8,7%) to niemal w całości niedobór fizyki (-2,20 ms); CPU (+0,16 ms) i render (-0,04 ms) go prawie nie zmieniają, a łączny p95 klatki nie jest sumą p95 składowych (różnica 0,3 ms).

Nowa kalibracja z tego raportu (`--calibrate` w tymczasowym detached worktree na `c02571a`, kopia raportu spoza drzewa; `docs/benchmarks/iphone-x-calibration.json`): `ratios.cpu` 5,968, `ratios.physics` 7,101; składowe Maca: przygotowanie 0,1688, kodowanie 0,3521, publikacja 0,3029 ms.

### Decyzja wykonalności renderu

Warunki z P-B-87 dla budżetu renderu 4,0 ms, z liczb tego raportu:

- koszt czyszczenia celu `gpu_render_clear_estimate_ms` = 0,9313 ms < 4,0 ms: spełniony;
- wymagane cięcie `gpu_render_estimate_ms − 4,0` = 2,3735 ms, a połowa części, której dotykają kandydaci renderu, `0,5 × (6,3735 − 0,9313)` = 2,7211 ms; cięcie to 43,6% tej części, limit 50%: spełniony, z zapasem 0,3476 ms. Naklejki to 2,3563 ms z 5,4422 ms tej części (`gpu_render_decals_estimate_ms`).

Decyzja: budżet renderu 4,0 ms jest wykonalny według kryterium P-B-87 (nie jest to stop renderu), ale zapas jest wąski. Nie rozstrzyga to bramki: stop na tym punkcie kontrolnym wynika z fizyki.

### Warunki stopu P-B-87

| Warunek | Wartość | Próg | Wynik |
| --- | --- | --- | --- |
| `gpu_physics_p95_ms` | 8,0262 ms | ≤ 6,0 ms | niespełniony, stop i decyzja właściciela (pula areny nie dała wymaganego zysku na A11) |
| `host_encoding_p95_ms` | 2,0140 ms | < 2,42 ms | spełniony |
| `gpu_render_clear_estimate_ms` | 0,9313 ms | < 4,0 ms | spełniony |
| cięcie renderu ≤ 50% części kandydatów | 43,6% | ≤ 50% | spełniony |

Dla odniesienia: przy fizyce 6,0 ms i renderze 4,0 ms GPU miałoby 10,0 ms, a przy CPU 6,47 ms daje to około 16,5 ms przy bramce 16,67 ms, czyli bez zapasu. Zgodnie z decyzją właściciela agent zapisał dane zadania 98 i na tym zatrzymał etap 9; zadania 99–102 i optymalizacje czekają na jego decyzję.
