# BubblePhysics 2.0 — pomiar kalibracyjny iPhone X

- Data: 2026-11-10; iPhone X, iOS 16.7.16; Xcode 26.6, konfiguracja Release.
- Mierzony commit: `4adf6122cd83e37b9f506ea167eca64c993d39a6` (`feature/engine-foundations`).
- Poprzednią aplikację odinstalowano przed instalacją nowego buildu. Surowy raport skopiowany z aplikacji przez właściciela:

```text
path=public BubbleWorld + BubblePhysicsMetalRender, same command buffer
device=Apple A11 GPU
scene=acceptance; solver_iteration_limit=4
render_px=1125x2436
warmup=30; measured=300
p95_ms=24.6018; max_ms=25.6256
gpu_p95_ms=15.0523; host_non_gpu_p95_ms=9.7247
host_preparation_p95_ms=1.6347; host_publication_p95_ms=5.0364
host_encoding_p95_ms=1.9975; host_waiting_p95_ms=16.1812
gpu_physics_p95_ms=8.6330; gpu_render_estimate_ms=6.4193
guard_corrections=0; non_finite_frames=0
fallback_frames=0; failed_frames=0
contour_cpu_readbacks=0
contact_candidate_overflow=0; max_candidates_per_object=32; candidate_limit=128
safety=pass
native_quality_envelope=not_evaluated_by_this_harness
p95_gate_ms=16.6700; p95_gate=fail
```

P95 pełnej klatki przekracza próg o 7,9318 ms. Nie odnotowano błędnych klatek, wartości non-finite, fallbacków, odczytów konturów na CPU ani przepełnień kandydatów; maksimum 32 kandydatów mieści się w połowie limitu 128. Harness nie ocenił `native_quality_envelope`.
