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

Weryfikacja prognozy na Macu (`--check-prediction`) pozostaje do wykonania zgodnie z zadaniem 89 planu.
