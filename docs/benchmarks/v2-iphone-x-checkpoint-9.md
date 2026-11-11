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
